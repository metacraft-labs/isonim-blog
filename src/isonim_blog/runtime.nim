## Content-only execution of a compiled site's layout registry.
import std/[os, strutils, json, tables, sets, algorithm]
import ./[model, inputs, version, html_checks, archives, listing, syndication]
import isonim/content/[markdown, prose]
import isonim/static/[exporter, buildinfo, assets, head, csp, sitemap, robots]
import isonim/dsl/ui
import isonim/ssr/escape
export model, listing

proc defaultLayout*(page: Page; site: Site; content: string): string =
  ## A structural fallback for sites that have not provided a layout yet.
  ui:
    main:
      h1: text page.title
      if page.draft:
        aside(class = "draft-banner", role = "status"): text "Draft preview"
      article:
        # Content comes from the shared Markdown renderer or another layout.
        raw content

proc applyLayouts*(page: Page; site: Site; layouts: openArray[LayoutEntry]): string =
  var name = page.layout
  result = page.content
  var visited = initHashSet[string]()
  while name.len > 0:
    if name in visited: fail(page.source & ": layout parent cycle at " & name)
    visited.incl name
    var found = false
    for entry in layouts:
      if entry.name == name:
        result = entry.render(page, site, result)
        name = entry.parent
        found = true
        break
    if not found:
      # Built-in structural fallbacks apply only to the page's own layout,
      # never to a missing parent.
      if visited.len == 1 and page.kind == pkContent and name in ["page", "post"]:
        return defaultLayout(page, site, result)
      if visited.len == 1 and page.kind != pkContent:
        return defaultListLayout(page, site, result)
      fail(page.source & ": missing layout " & name)

proc declaredIslands*(layouts: openArray[LayoutEntry]): seq[Island] =
  var seen = initHashSet[string]()
  for layout in layouts:
    for island in layout.islands:
      let key = island.module & "\0" & island.selector
      if key notin seen:
        if not island.module.startsWith("includes/") or
            island.module.contains({'\\', '\0'}) or ".." in island.module.split('/'):
          fail("an island module must be inside includes/: " & island.module)
        if island.selector.len == 0: fail("an island requires a selector")
        seen.incl key
        result.add island

proc validateOutput(root, output: string) =
  let target = normalizedPath(absolutePath(output))
  let source = normalizedPath(absolutePath(root))
  if target == source or source.startsWith(target & DirSep): fail("output would overwrite site inputs")
  for dir in ["posts", "drafts", "pages", "collections", "data", "assets", "static", "layouts", "includes"]:
    let input = source / dir
    if target == input or target.startsWith(input & DirSep): fail("output overlaps input directory " & dir)

proc exportBlog*(root, output: string; layouts: openArray[LayoutEntry];
    options = BuildOptions(); bundle = ""): ExportReport =
  ## Prepare all output using shared primitives and publish one complete tree.
  validateOutput(root, output)
  var site = loadSite(root, options)
  if site.config.url.len == 0:
    fail("url is required (in site.toml or with --url): canonical links, feeds and the sitemap need an absolute origin")
  var files: seq[SiteFile]
  var origins = initTable[string, string]()
  var assetManifest: seq[tuple[original, hashed: string]]
  var rewrites: seq[tuple[original, hashed: string]]
  proc addFile(path, content, source: string) =
    let key = path.toLowerAscii
    if origins.hasKey(key): fail("output collision: " & origins[key] & " and " & source & " -> " & path)
    origins[key] = source
    files.add SiteFile(path: path, content: content)
  proc addAsset(path, content, source: string) =
    let hashed = (if path.startsWith("assets/"): "" else: "assets/") & hashedAssetName(path, content)
    addFile(hashed, content, source)
    assetManifest.add (path, hashed)
    rewrites.add ("/" & path, site.config.basePath & "/" & hashed)
    site.assets[path] = site.config.basePath & "/" & hashed
  # A theme's assets sit under the site's: the site's file of the same path wins.
  var assetSources = initOrderedTable[string, string]()
  for base in [options.theme, root]:
    if base.len == 0: continue
    for file in inputFiles(base / "assets"):
      assetSources["assets/" & relativePath(file, base / "assets").replace('\\', '/')] = file
  var assetPaths: seq[string]
  for path in assetSources.keys: assetPaths.add path
  assetPaths.sort()
  for path in assetPaths:
    let file = assetSources[path]
    let origin = if file.startsWith(root & DirSep): relativePath(file, root) else: "theme " & path
    addAsset(path, readFile(file), origin)
  # Bundle resources belong only to included posts, never excluded drafts.
  for page in site.pages:
    if page.source.endsWith("/index.md") and page.collection == "posts":
      let directory = parentDir(page.source)
      for file in inputFiles(root / directory):
        if file.endsWith(".md"): continue
        addAsset(relativePath(file, root), readFile(file), relativePath(file, root))
  for file in inputFiles(root / "static"):
    addFile(relativePath(file, root / "static"), readFile(file), relativePath(file, root))
  addFile("asset-manifest.json", renderAssetManifest(assetManifest), "generated asset manifest")
  var scripts: seq[PageScript]
  if site.config.scriptPolicy == spDeclared and declaredIslands(layouts).len > 0:
    if bundle.len == 0 or not fileExists(bundle): fail("declared islands require a compiled bundle")
    let content = readFile(bundle)
    let path = "assets/" & hashedAssetName("islands.js", content)
    addFile(path, content, "compiled islands")
    scripts.add externalScript(site.config.basePath & "/" & path)
  let analytics = site.config.analytics
  case analytics.stringValue("provider", "none")
  of "none": discard
  of "custom":
    let snippet = analytics.stringValue("snippet")
    if snippet.len == 0: fail("custom analytics requires snippet (JavaScript body)")
    scripts.add inlineScript(snippet, role = srAnalytics, slot = ssHeadEnd)
  of "beacon":
    let src = analytics.stringValue("src")
    if src.len == 0: fail("beacon analytics requires src")
    scripts.add externalScript(src, role = srAnalytics)
  else: fail("unknown analytics provider")
  let keptScripts = applyScriptPolicy(site.config.scriptPolicy, scripts)
  var routes = initTable[string, string]()
  for page in site.pages: routes[page.source] = page.url
  for page in site.pages.mitems:
    let source = page.source
    let doc = parseMarkdownDoc(page.body, page.source,
      resolveContentPath = proc(path: string): string =
        if not routes.hasKey(path): fail(source & ": missing content target " & path)
        routes[path], firstLine = page.bodyLine)
    page.content = renderProseHtml(doc)
    if page.toc: page.content = renderTocHtml(doc.headingTree) & page.content
    if page.excerpt.len == 0: page.excerpt = renderProseHtml(doc.excerpt)
    # Excerpts are shown on listing pages and in feeds, so their links to
    # bundle resources are rewritten exactly like the full content's.
    for rewrite in rewrites:
      page.content = page.content.replace("\"" & rewrite.original & "\"", "\"" & rewrite.hashed & "\"")
      page.excerpt = page.excerpt.replace("\"" & rewrite.original & "\"", "\"" & rewrite.hashed & "\"")
  # Layouts receive the same rendered records through all navigation views.
  site.posts.setLen(0)
  site.collections.clear()
  for name in site.config.collections.keys: site.collections[name] = @[]
  for page in site.pages:
    if page.collection == "posts": site.posts.add page
    elif page.collection.len > 0: site.collections.mgetOrPut(page.collection, @[]).add page
  # Navigation and listings are built from the rendered records, so listing
  # layouts and feeds see each post's content and excerpt; linkNavigation
  # also copies the links onto the matching records of site.pages.
  linkNavigation(site)
  var pages: seq[SitePage]
  var headers = ""
  for page in site.pages & generatedPages(site):
    if not page.output: continue
    let rel = outputPath(page.url)
    if origins.hasKey(rel.toLowerAscii):
      fail("output collision: " & origins[rel.toLowerAscii] & " and " & page.source)
    origins[rel.toLowerAscii] = page.source
    let isPost = page.kind == pkContent and page.collection == "posts"
    var documentHead = DocumentHead(title: formatPageTitle(page.title, site.config.title),
      description: page.description, siteName: site.config.title,
      canonicalUrl: if page.canonical.len > 0: page.canonical else: site.config.url & page.url,
      ogType: if isPost: "article" else: "website",
      ogImage: page.ogImage)
    documentHead.jsonLd = jsonLdFor(site, page, documentHead.canonicalUrl)
    let bodyHtml = applyLayouts(page, site, layouts)
    let headHtml = renderPageHeadHtml(documentHead, keptScripts, policy = site.config.scriptPolicy)
    let ending = renderBodyEndScriptsHtml(keptScripts, policy = site.config.scriptPolicy)
    let headExtra = feedLinksHtml(site, page) &
      (if page.noindex: "<meta name=\"robots\" content=\"noindex\">" else: "")
    let markup = ui:
      html(lang = site.config.language):
        raw headHtml.replace("</head>", headExtra & "</head>")
        body:
          raw bodyHtml
          raw ending
    let document = "<!doctype html>\n" & markup
    var actualScripts = 0
    for script in scriptElements(document):
      if script.attr("type").toLowerAscii != "application/ld+json": inc actualScripts
    if actualScripts != keptScripts.len:
      fail(page.source & ": a layout emitted an undeclared script or data block")
    if eventHandlerAttributes(document).len > 0: fail(page.source & ": inline event handlers are not declared islands")
    var policy = strictCspConfig()
    for directive in policy.directives.mitems:
      if directive.name == "script-src":
        directive.sources = @[]
        for script in keptScripts:
          if script.src.len > 0: directive.sources.add script.src
        if directive.sources.len == 0 and keptScripts.len == 0: directive.sources = @["'none'"]
    headers.add page.url & "\n  Content-Security-Policy: " &
      cspHeaderValue(policy, inlineScriptBodies(keptScripts)) & "\n"
    # The sitemap lists neither drafts and noindex pages nor posts dated
    # after the build date (present only with --future).
    pages.add SitePage(route: page.url, html: document, lastmod: page.updated,
      noindex: page.noindex or page.future)
  for (path, content) in siteFeeds(site): addFile(path[1..^1], content, "generated feed " & path)
  let sitemapPath = site.config.basePath & "/sitemap.xml"
  addFile(sitemapPath[1..^1], renderSitemap(sitemapEntriesFor(pages, site.config.url)), "generated sitemap")
  # A site's own static/robots.txt replaces the generated one.
  if not origins.hasKey("robots.txt"):
    addFile("robots.txt", renderRobots(site.config.url & sitemapPath), "generated robots.txt")
  if origins.hasKey("_headers"):
    for file in files.mitems:
      if file.path == "_headers": file.content.add "\n" & headers
  else: addFile("_headers", headers, "generated script policy")
  if origins.hasKey("build.json"): fail("output collision: " & origins["build.json"] & " and generated build.json")
  for path, source in origins:
    var parent = path
    while '/' in parent:
      parent = parent[0..<parent.rfind('/')]
      if origins.hasKey(parent): fail("output collision: " & origins[parent] & " and " & source)
  let stage = beginStaging(output)
  try:
    result = writeSiteTree(stage.path, pages, files)
    # Builders that know a commit (the Nix wrapper) pass it; otherwise the
    # revision is the content hash of every file this build was allowed to read.
    let sourceRevision = getEnv("ISONIM_BLOG_SOURCE_REVISION", treeHashOf(block:
      var inputs: seq[tuple[path, content: string]]
      for file in siteInputFiles(root, site.config, options):
        inputs.add (relativePath(file, root).replace('\\', '/'), readFile(file))
      inputs))
    let themeRevision =
      if options.theme.len == 0: getEnv("ISONIM_BLOG_THEME_REVISION", "none")
      else: getEnv("ISONIM_BLOG_THEME_REVISION", themeTreeHash(options.theme))
    discard writeBuildInfo(stage.path, SiteBuildInfo(generator: "isonim-blog " & isonimBlogVersion,
      sourceRevision: sourceRevision, sourceDateEpoch: site.sourceDateEpoch,
      components: @[
        BuildComponent(name: "isonim-blog", revision: getEnv("ISONIM_BLOG_REVISION", isonimBlogVersion)),
        BuildComponent(name: "theme", revision: themeRevision)]))
    commitStaging(stage, output)
    result.outDir = output
  except CatchableError:
    discardStaging(stage)
    raise
  for warning in site.warnings: stderr.writeLine("warning: " & warning)

proc siteMain*(layouts: openArray[LayoutEntry]) =
  ## Generated exporter protocol: output directory, then site root and options.
  try:
    let args = commandLineParams()
    if args.len > 1 and args[1] == "--prepare-only": return
    if args == @["--islands"]:
      var values = newJArray()
      for island in declaredIslands(layouts): values.add %*{"module": island.module, "selector": island.selector}
      echo $values
      return
    if args.len == 0: fail("site exporter requires an output directory")
    var options: BuildOptions
    var root = getEnv("ISONIM_BLOG_SITE_ROOT", getCurrentDir())
    var bundle = getEnv("ISONIM_BLOG_ISLAND_BUNDLE")
    var i = 1
    while i < args.len:
      case args[i]
      of "--drafts": options.drafts = true
      of "--future": options.future = true
      of "--root", "--url", "--bundle", "--theme":
        let flag = args[i]
        inc i
        if i >= args.len: fail("missing value for " & flag)
        case flag
        of "--root": root = args[i]
        of "--url": options.url = args[i]
        of "--theme": options.theme = absolutePath(args[i])
        else: bundle = args[i]
      else: fail("unknown exporter argument " & args[i])
      inc i
    let report = exportBlog(root, args[0], layouts, options, bundle)
    echo "Built " & $report.pages.len & " pages and " & $report.files.len & " files in " & args[0]
  except CatchableError as cause:
    stderr.writeLine(cause.msg)
    quit(1)
