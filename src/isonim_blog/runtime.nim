## Content-only execution of a compiled site's layout registry.
import std/[os, strutils, json, tables, sets, algorithm, uri]
import ./[model, inputs, version, html_checks, archives, listing, syndication, og]
import isonim/content/[markdown, prose]
import isonim/static/[exporter, buildinfo, assets, head, csp, sitemap, robots, ogimage, feeds]
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

proc ogImageConfig(): OgImageConfig =
  ## resvg and the bundled fonts, injected by path: the dev shell, the
  ## packaged CLI and the Nix builder set these; nothing is looked up.
  result.resvgPath = getEnv("ISONIM_BLOG_RESVG")
  if result.resvgPath.len == 0:
    fail("OpenGraph images need resvg: ISONIM_BLOG_RESVG is not set (enter nix develop or use the packaged CLI)")
  let fonts = getEnv("ISONIM_BLOG_OG_FONTS")
  if fonts.len == 0 or not dirExists(fonts):
    fail("OpenGraph images need the bundled fonts: ISONIM_BLOG_OG_FONTS is not a directory (enter nix develop or use the packaged CLI)")
  for kind, file in walkDir(fonts):
    if kind in {pcFile, pcLinkToFile} and file.splitFile.ext.toLowerAscii in [".ttf", ".otf"]:
      result.fontFiles.add file
  result.fontFiles.sort()
  if result.fontFiles.len == 0: fail("no .ttf or .otf font in ISONIM_BLOG_OG_FONTS: " & fonts)
  result.defaultFontFamily = "DejaVu Sans"

proc ogImagePath(site: Site; url, png: string): string =
  ## `assets/og/<page path>.<hash>.png`: fingerprinted like other assets,
  ## named after the page so the tree stays readable.
  var key = url[site.config.basePath.len .. ^1].strip(chars = {'/'})
  if key.endsWith(".html"): key.setLen(key.len - 5)
  if key.len == 0: key = "index"
  hashedAssetName("assets/og/" & key & ".png", png)

proc rootRelativeHtml*(html, pageUrl: string): string =
  ## `html` written for the page at `pageUrl`, with every page-relative
  ## `href`, `src`, `poster` and `srcset` reference made root-relative, so it
  ## means the same on any page. References with a scheme or host, and
  ## root-relative ones, are unchanged. Resolution is `absoluteHtmlUrls`'s
  ## (RFC 3986 §5.2) against a reserved `.invalid` origin (RFC 2606), which is
  ## then removed.
  const origin = "http://isonim-blog.invalid"
  absoluteHtmlUrls(html, origin & pageUrl).replace(origin, "")

proc referencePath(pageUrl, reference: string): string =
  ## The site path a page-relative or root-relative reference names, without
  ## its query or fragment and percent-decoded; "" for a URL with a scheme
  ## or another host (`https:`, `data:`, `//host/`).
  let value = reference.strip()
  if value.len == 0 or value.startsWith("//"): return ""
  for c in value:
    if c == ':': return ""
    if c in {'/', '?', '#'}: break
  const origin = "http://site.invalid"
  var path = resolveUrl(origin & pageUrl, value)[origin.len .. ^1]
  for mark in ['?', '#']:
    let at = path.find(mark)
    if at >= 0: path.setLen(at)
  decodeUrl(path, decodePlus = false)

const
  maxHeaderRules* = 100
    ## Cloudflare Pages applies at most 100 `_headers` rules
    ## (https://developers.cloudflare.com/pages/configuration/headers/).
  maxRedirectRules* = 2100
    ## Cloudflare Pages applies at most 2,000 static and 100 dynamic
    ## `_redirects` rules
    ## (https://developers.cloudflare.com/pages/configuration/redirects/).

proc ruleCount*(text: string): int =
  ## Rules in a `_headers` or `_redirects` file: non-blank, non-comment lines
  ## that do not start with whitespace (header lines are indented).
  for line in text.splitLines():
    if line.len > 0 and line[0] notin {' ', '\t', '#'}: inc result

proc headersFor*(pagePolicies: openArray[tuple[url, policy: string]]): string =
  ## The Content-Security-Policy rules for `_headers`. When every page has
  ## the same policy (the script policy is site-wide, so this is the normal
  ## case) one `/*` rule carries it, which keeps a large site far below the
  ## host's rule limit; otherwise each page gets its own rule.
  if pagePolicies.len == 0: return ""
  var uniform = true
  for entry in pagePolicies:
    if entry.policy != pagePolicies[0].policy: uniform = false
  if uniform: return "/*\n  Content-Security-Policy: " & pagePolicies[0].policy & "\n"
  for entry in pagePolicies:
    result.add entry.url & "\n  Content-Security-Policy: " & entry.policy & "\n"

proc redirectsFor*(site: Site): string =
  ## One permanent `_redirects` rule per `redirect_from` entry of an output
  ## page, sorted by source. A source claimed twice, or equal to a page's
  ## own URL, is an error naming the pages involved.
  var owners = initTable[string, string]()
  var targets = initTable[string, string]()
  var pageUrls = initTable[string, string]()
  for page in site.pages & generatedPages(site):
    if page.output: pageUrls[page.url.strip(leading = false, chars = {'/'})] = page.source
  for page in site.pages:
    if not page.output: continue
    for value in page.redirectFrom:
      let source =
        try: redirectSource(site.config.basePath, value)
        except BlogError as cause: fail(page.source & ": " & cause.msg)
      if owners.hasKey(source):
        fail("redirect_from " & value & " is claimed by " & owners[source] & " and " & page.source)
      let bare = source.strip(leading = false, chars = {'/'})
      if pageUrls.hasKey(bare):
        fail(page.source & ": redirect_from " & value & " is the URL of " & pageUrls[bare])
      owners[source] = page.source
      targets[source] = page.url
  var sources: seq[string]
  for source in owners.keys: sources.add source
  sources.sort()
  for source in sources: result.add source & " " & targets[source] & " 301\n"

proc appendGenerated(files: var seq[SiteFile]; origins: var Table[string, string];
    path, generated, source: string) =
  ## Append generated rules to the site's own file of that name, or write
  ## them as the file when the site has none (and there is something to say).
  if origins.hasKey(path):
    for file in files.mitems:
      if file.path == path:
        if generated.len > 0:
          if file.content.len > 0 and not file.content.endsWith("\n"): file.content.add "\n"
          file.content.add "\n# Generated by isonim-blog\n" & generated
        return
  elif generated.len > 0:
    origins[path] = source
    files.add SiteFile(path: path, content: generated)

proc isRealDir(path: string): bool = dirExists(path) and not symlinkExists(path)

proc syncTree*(source, target: string): seq[string] =
  ## Make `target` byte-identical to `source`, writing only files whose bytes
  ## differ and removing what `source` lacks; files that did not change keep
  ## their timestamps. Returns the changed relative paths, sorted. Symbolic
  ## links in `target` are removed, never followed.
  if symlinkExists(target) or fileExists(target):
    fail("output must be a directory, not a symlink or file: " & target)
  var wanted = initTable[string, PathComponent]()
  for path in walkDirRec(source, yieldFilter = {pcFile, pcDir}, relative = true):
    wanted[path] = (if dirExists(source / path): pcDir else: pcFile)
  # Remove what is gone or changed kind, deepest first.
  var existing: seq[string]
  for path in walkDirRec(target, yieldFilter = {pcFile, pcDir, pcLinkToFile, pcLinkToDir},
      relative = true, followFilter = {pcDir}):
    existing.add path
  existing.sort(proc(a, b: string): int = cmp(b.len, a.len))
  for path in existing:
    let full = target / path
    let kind = wanted.getOrDefault(path, pcLinkToFile)
    let keep = (kind == pcFile and fileExists(full) and not symlinkExists(full)) or
      (kind == pcDir and isRealDir(full))
    if keep: continue
    if isRealDir(full):
      if kind != pcDir:
        removeDir(full)
        result.add path.replace('\\', '/') & "/"
    else:
      removeFile(full)
      if kind != pcFile: result.add path.replace('\\', '/')
  var paths: seq[string]
  for path in wanted.keys: paths.add path
  paths.sort()
  for path in paths:
    let full = target / path
    if wanted[path] == pcDir:
      createDir(full)
      continue
    let content = readFile(source / path)
    if fileExists(full) and readFile(full) == content: continue
    createDir(parentDir(full))
    writeFile(full, content)
    result.add path.replace('\\', '/')
  result.sort()

proc exportBlog*(root, output: string; layouts: openArray[LayoutEntry];
    options: BuildOptions; bundle: string; ogTemplate: OgTemplate;
    changed: var seq[string]): ExportReport =
  ## Prepare all output using shared primitives and publish one complete tree.
  ## With `options.incremental` and an existing output, `changed` receives
  ## the output paths that were written or removed; otherwise it is empty.
  changed.setLen(0)
  validateOutput(root, output)
  var site = loadSite(root, options)
  if site.config.url.len == 0:
    fail("url is required (in site.toml or with --url): canonical links, feeds and the sitemap need an absolute origin")
  var files: seq[SiteFile]
  var origins = initTable[string, string]()
  var assetManifest: seq[tuple[original, hashed: string]]
  var rewrites: seq[tuple[original, hashed: string]]
  # Every file a page may show as an image, by the URL pages use for it.
  var siteFiles = initTable[string, tuple[name, content: string]]()
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
    siteFiles[site.config.basePath & "/" & hashed] = (path, content)
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
    let path = relativePath(file, root / "static").replace('\\', '/')
    let content = readFile(file)
    addFile(path, content, relativePath(file, root))
    siteFiles[site.config.basePath & "/" & path] = (path, content)
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
    # A page-relative reference (`../other/`, `#heading`) in an excerpt would
    # point elsewhere on a listing page, so excerpts carry root-relative ones.
    page.excerpt = rootRelativeHtml(page.excerpt, page.url)
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
  # Responsive images: every page's <img> elements, Markdown and layouts
  # alike, get dimensions; rasters get AVIF/WebP variants (libvips, injected).
  var imageFormats: seq[ImageFormat]
  for name in site.config.imageFormats: imageFormats.add parseImageFormat(name)
  let basePath = site.config.basePath
  let images = newResponsiveImages(ImageVariantConfig(vipsPath: getEnv("ISONIM_BLOG_VIPS"),
    widths: site.config.imageWidths, formats: imageFormats,
    maxSourceBytes: site.config.maxImageBytes, cacheDir: options.imageCache),
    proc(path: string): string = basePath & "/" & path)
  var ogConfig: OgImageConfig
  var ogConfigured = false
  proc ogImageUrl(page: Page): string =
    ## The absolute URL of the page's OpenGraph image: its `og_image` (a URL,
    ## or a file of the site named relative to the page's source or to the
    ## site root), else a card rendered from the template.
    let value = page.ogImage.strip()
    if value.len > 0:
      let lower = value.toLowerAscii
      if lower.startsWith("https://") or lower.startsWith("http://"): return value
      let path = referencePath("/" & page.source, value)
      for rewrite in rewrites:
        if rewrite.original == path: return site.config.url & rewrite.hashed
      if siteFiles.hasKey(basePath & path): return site.config.url & basePath & path
      fail(page.source & ": og_image " & value & " is not a file of the site")
    if not ogConfigured:
      ogConfig = ogImageConfig()
      ogConfigured = true
    let png =
      try: renderOgImage(ogTemplate(page, site), ogConfig)
      except OgImageError as cause: fail(page.source & ": OpenGraph image: " & cause.msg)
    let path = ogImagePath(site, page.url, png)
    addFile(path, png, "OpenGraph image of " & page.source)
    site.config.url & basePath & "/" & path
  var pages: seq[SitePage]
  var pagePolicies: seq[tuple[url, policy: string]]
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
      ogImage: ogImageUrl(page), twitterCard: "summary_large_image")
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
    let pageUrl = page.url
    let document =
      try:
        images.rewritePageImages("<!doctype html>\n" & markup, page.source,
          proc(src: string): ImageReference =
            let path = referencePath(pageUrl, src)
            if path.len == 0: ImageReference(kind: irExternal)
            elif siteFiles.hasKey(path):
              ImageReference(kind: irFile, name: siteFiles[path].name, content: siteFiles[path].content)
            else: ImageReference(kind: irMissing))
      except ImageError as cause:
        fail(cause.msg & (if "not configured" in cause.msg:
          " (ISONIM_BLOG_VIPS is not set: enter nix develop or use the packaged CLI)" else: ""))
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
    pagePolicies.add (page.url, cspHeaderValue(policy, inlineScriptBodies(keptScripts)))
    # The sitemap lists neither drafts and noindex pages nor posts dated
    # after the build date (present only with --future), nor a listing page
    # that lists only such posts.
    pages.add SitePage(route: page.url, html: document, lastmod: page.updated,
      noindex: page.noindex or page.future or page.listsOnlyPreviews)
  for file in images.files: addFile(file.path, file.content, "image variant")
  site.warnings.add images.warnings
  for (path, content) in siteFeeds(site): addFile(path[1..^1], content, "generated feed " & path)
  let sitemapPath = site.config.basePath & "/sitemap.xml"
  addFile(sitemapPath[1..^1], renderSitemap(sitemapEntriesFor(pages, site.config.url)), "generated sitemap")
  # A site's own static/robots.txt replaces the generated one.
  if not origins.hasKey("robots.txt"):
    addFile("robots.txt", renderRobots(site.config.url & sitemapPath), "generated robots.txt")
  # A site's own static/_headers and static/_redirects (the deploy recipe
  # generates both) are extended, never replaced.
  appendGenerated(files, origins, "_headers", headersFor(pagePolicies), "generated script policy")
  appendGenerated(files, origins, "_redirects", redirectsFor(site), "generated redirects")
  for file in files:
    if file.path == "_headers" and ruleCount(file.content) > maxHeaderRules:
      site.warnings.add "_headers has " & $ruleCount(file.content) & " rules; Cloudflare Pages applies at most " & $maxHeaderRules
    if file.path == "_redirects" and ruleCount(file.content) > maxRedirectRules:
      site.warnings.add "_redirects has " & $ruleCount(file.content) & " rules; Cloudflare Pages applies at most " & $maxRedirectRules
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
    if options.incremental and dirExists(output):
      changed = syncTree(stage.path, output)
      discardStaging(stage)
    else:
      commitStaging(stage, output)
    result.outDir = output
  except CatchableError:
    discardStaging(stage)
    raise
  for warning in site.warnings: stderr.writeLine("warning: " & warning)

proc exportBlog*(root, output: string; layouts: openArray[LayoutEntry];
    options = BuildOptions(); bundle = ""; ogTemplate: OgTemplate = defaultOgImage): ExportReport =
  ## `exportBlog` without the list of changed files.
  var changed: seq[string]
  exportBlog(root, output, layouts, options, bundle, ogTemplate, changed)

proc siteMain*(layouts: openArray[LayoutEntry]; ogTemplate: OgTemplate = defaultOgImage) =
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
      of "--incremental": options.incremental = true
      of "--root", "--url", "--bundle", "--theme", "--image-cache":
        let flag = args[i]
        inc i
        if i >= args.len: fail("missing value for " & flag)
        case flag
        of "--root": root = args[i]
        of "--url": options.url = args[i]
        of "--theme": options.theme = absolutePath(args[i])
        of "--image-cache": options.imageCache = absolutePath(args[i])
        else: bundle = args[i]
      else: fail("unknown exporter argument " & args[i])
      inc i
    var changed: seq[string]
    let report = exportBlog(root, args[0], layouts, options, bundle, ogTemplate, changed)
    echo "Built " & $report.pages.len & " pages and " & $report.files.len & " files in " & args[0]
    if options.incremental:
      echo "Updated " & $changed.len & " changed files"
      for path in changed: echo "  " & path
  except CatchableError as cause:
    stderr.writeLine(cause.msg)
    quit(1)
