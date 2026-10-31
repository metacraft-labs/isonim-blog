## Content-only execution of a compiled site's layout registry.
import std/[os, strutils, json, tables, sets, algorithm, uri, tempfiles]
from std/unicode import Rune, `$`, runeLen, runeOffset
from std/htmlparser import entityToUtf8
import ./[model, inputs, version, html_checks, archives, listing, syndication, og]
import isonim/content/[markdown, prose, directives]
import isonim/content/ext/[math, diagrams]
import isonim/static/[exporter, buildinfo, assets, head, csp, sitemap, robots, ogimage, feeds]
from isonim/static/urls import webOrigin
import isonim/dsl/ui
import isonim/ssr/escape
export model, listing, directives

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

const siteCardPath = "assets/og/_site.png"
  ## The one card listing pages share, fingerprinted like the page cards.
  ## Only a page at `/_site/` has a card of the same stem; the hash keeps
  ## the two apart, and identical bytes would fail as an output collision.

proc ogImagePath(site: Site; url, png: string): string =
  ## `assets/og/<page path>.<hash>.png`: fingerprinted like other assets,
  ## named after the page so the tree stays readable.
  var key = url[site.config.basePath.len .. ^1].strip(chars = {'/'})
  if key.endsWith(".html"): key.setLen(key.len - 5)
  if key.len == 0: key = "index"
  hashedAssetName("assets/og/" & key & ".png", png)

const contentTools = [("KaTeX", "ISONIM_BLOG_KATEX"), ("D2", "ISONIM_BLOG_D2"), ("Graphviz", "ISONIM_BLOG_DOT")]
  ## The build-time renderers of maths and diagrams, by the name the content
  ## extensions report and the variable that injects each by path.

proc contentHooks*(config: SiteConfig; diagramCache: string): seq[ParseHooks] =
  ## The content extensions `[markdown]` turns on: maths through KaTeX, and
  ## the listed diagram languages through D2 and Graphviz. Each executable is
  ## injected by absolute path (`ISONIM_BLOG_KATEX`, `ISONIM_BLOG_D2`,
  ## `ISONIM_BLOG_DOT`); none is looked up on PATH. An unset one fails only
  ## when a page uses it (`withToolHint` names the variable). A fence of a
  ## diagram language the site did not list is an error too: with diagrams
  ## on, the parser hands both languages to the renderer, and rendering one
  ## the author did not enable would contradict `site.toml`.
  if config.math: result.add mathHooks(getEnv("ISONIM_BLOG_KATEX"))
  if config.diagrams.len > 0:
    let enabled = config.diagrams
    let diagramConfig = DiagramConfig(d2Path: getEnv("ISONIM_BLOG_D2"),
      dotPath: getEnv("ISONIM_BLOG_DOT"), cacheDir: diagramCache)
    var hooks = ParseHooks(name: "diagrams")
    hooks.renderers.diagram = proc(language, source: string; location: SourceLocation): ContentFragment =
      if language notin enabled:
        raise contentError(location, "a " & language & " diagram, but [markdown] diagrams in " &
          "site.toml lists only " & enabled.join(", ") & "; add " & language & " to it")
      renderDiagram(language, source, diagramConfig, location)
    result.add hooks

proc withToolHint*(message: string): string =
  ## A content extension's "<tool> not configured" error, with the variable
  ## that injects the tool and where it is set.
  for (tool, variable) in contentTools:
    if message.endsWith(": " & tool & " not configured"):
      return message & " (" & variable & " is not set: enter nix develop or use the packaged CLI)"
  message

proc checkImageAlt*(doc: MarkdownDoc; source: string) =
  ## Markdown cannot tell an image without alt text from a decorative one:
  ## both are `![](src)`. An empty alt text is therefore an error unless the
  ## image is marked `{decorative}`, which renders `alt=""`; a decorative
  ## image with alt text is contradictory and an error too. Errors name the
  ## source file and the image's line. (Layouts write HTML, where a missing
  ## `alt` and `alt=""` differ; `rewritePageImages` checks those.)
  for image in proseImages(doc.blocks):
    let where = source & ":" & $image.line & ": the image " & image.href
    if image.decorative and image.text.strip.len > 0:
      fail(where & " is marked {decorative} but has alt text; keep one: ![" & image.text &
        "](...) describes it, ![](...){decorative} hides it from assistive technology")
    if not image.decorative and image.text.strip.len == 0:
      fail(where & " has no alt text: describe it (![what it shows](...)), or mark it " &
        "decorative if it adds no information (![](...){decorative})")

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

proc blogContentSecurityPolicy*(scripts: openArray[PageScript];
    imageOrigins: openArray[string]; styleBodies: openArray[string] = []): string =
  ## The Content-Security-Policy of a page that keeps `scripts` (after the
  ## script policy) and may show images from `imageOrigins` (normalised
  ## origins, the site's own excluded). It starts from `default-src 'none'`
  ## and allows only what a built page loads, as OWASP's baseline does
  ## (https://cheatsheetseries.owasp.org/cheatsheets/Content_Security_Policy_Cheat_Sheet.html):
  ##
  ## * `script-src`: `'none'` without scripts; otherwise `'self'` for a
  ##   script on the site (the islands bundle, a self-hosted beacon), the
  ##   absolute URL of a script elsewhere, and the SHA-256 of each inline
  ##   script (`isonim/static/csp`). A source expression needs a host
  ##   (https://www.w3.org/TR/CSP3/#grammardef-host-source), so a path such
  ##   as `/assets/islands.<hash>.js` would be ignored and the script
  ##   blocked; `'self'` also holds on preview hosts and `serve`.
  ## * `style-src 'self'` and the SHA-256 of each `<style>` element's text
  ##   in `styleBodies`, as Astro's CSP support hashes the inline styles it
  ##   emits (https://www.w3.org/TR/CSP3/#grammardef-hash-source). A `style`
  ##   attribute would need `'unsafe-hashes'`, so the build refuses it
  ##   (`inlineStyles`), and no `'unsafe-inline'` is needed.
  ## * `img-src 'self' data:` and the remote image origins; `font-src`,
  ##   `media-src` and `manifest-src 'self'`; `connect-src 'self'` only
  ##   when a script can make requests.
  ## * `base-uri 'self'`, `form-action 'self'` and `frame-ancestors 'none'`
  ##   (no framing, against clickjacking), which do not fall back to
  ##   `default-src` (https://www.w3.org/TR/CSP3/#directive-default-src).
  ##   `frame-ancestors` works only in a header, not in a meta element, so
  ##   the policy is delivered through `_headers`.
  var scriptSources: seq[string]
  for script in scripts:
    if script.src.len == 0: continue  # inline: allowed by its hash
    let source = if script.src.startsWith("/") and not script.src.startsWith("//"): "'self'"
      else: script.src
    if source notin scriptSources: scriptSources.add source
  if scripts.len == 0: scriptSources = @["'none'"]
  var styleSources = @["'self'"]
  for body in styleBodies:
    let source = cspHashSource(body)
    if source notin styleSources: styleSources.add source
  var directives = @[
    CspDirective(name: "default-src", sources: @["'none'"]),
    CspDirective(name: "script-src", sources: scriptSources),
    CspDirective(name: "style-src", sources: styleSources),
    CspDirective(name: "img-src", sources: @["'self'", "data:"] & @imageOrigins),
    CspDirective(name: "font-src", sources: @["'self'"]),
    CspDirective(name: "media-src", sources: @["'self'"]),
    CspDirective(name: "manifest-src", sources: @["'self'"])]
  if scripts.len > 0: directives.add CspDirective(name: "connect-src", sources: @["'self'"])
  directives.add [
    CspDirective(name: "base-uri", sources: @["'self'"]),
    CspDirective(name: "form-action", sources: @["'self'"]),
    CspDirective(name: "frame-ancestors", sources: @["'none'"])]
  cspHeaderValue(CspConfig(enabled: true, directives: directives), inlineScriptBodies(scripts))

proc excerptText*(html: string): string =
  ## The text of rendered excerpt HTML, for a meta description: tags
  ## dropped (a block element's end separates words), character references
  ## decoded, whitespace collapsed to single spaces.
  const blockTags = ["p", "div", "li", "ul", "ol", "dl", "dt", "dd", "br", "h1", "h2", "h3",
    "h4", "h5", "h6", "blockquote", "pre", "figure", "figcaption", "table", "tr", "td", "th",
    "section", "aside", "hr"]
  var text = ""
  var i = 0
  while i < html.len:
    case html[i]
    of '<':
      let stop = html.find('>', i)
      if stop < 0: break
      var name = html[i + 1 ..< stop].strip(chars = {'/', ' '}).toLowerAscii
      let space = name.find({' ', '\t', '\n', '/'})
      if space >= 0: name.setLen(space)
      if name in blockTags: text.add ' '
      i = stop + 1
    of '&':
      let stop = html.find(';', i)
      let entity = if stop > i and stop - i <= 32: html[i + 1 ..< stop] else: ""
      var decoded = ""
      if entity.len > 1 and entity[0] == '#':
        try:
          let code = if entity[1] in {'x', 'X'}: parseHexInt(entity[2 .. ^1]) else: parseInt(entity[1 .. ^1])
          if code > 0 and code <= 0x10FFFF and code notin 0xD800 .. 0xDFFF: decoded = $Rune(code)
        except ValueError: discard
      elif entity.len > 0:
        decoded = entityToUtf8(entity)
      if decoded.len > 0:
        text.add decoded
        i = stop + 1
      else:
        text.add '&'
        inc i
    else:
      text.add html[i]
      inc i
  text.splitWhitespace().join(" ")

proc shortDescription*(text: string): string =
  ## `text` cut to at most `maxDescriptionRunes` characters at a word
  ## boundary, with an ellipsis when it was cut (a word longer than the
  ## limit is cut inside the word).
  if text.runeLen <= maxDescriptionRunes: return text
  let limit = text.runeOffset(maxDescriptionRunes - 1)
  var cut = text[0 ..< limit]
  let space = cut.rfind(' ')
  if space > 0: cut.setLen(space)
  cut.strip(leading = false, chars = Whitespace + {',', ';', ':', '-'}) & "…"

proc headersFor*(pagePolicies: openArray[tuple[url, policy: string]]): string =
  ## The Content-Security-Policy rules for `_headers`. When every page has
  ## the same policy (the script policy is site-wide, so this is the normal
  ## case unless layouts emit different `<style>` elements on different
  ## pages) one `/*` rule carries it, which keeps a large site far below the
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
  ## page, sorted by source. The source is the old URL's path from the
  ## output root (without `base_path`) and the target the page's URL (with
  ## it). A source claimed twice, or equal to a page's own URL, is an error
  ## naming the pages involved.
  var owners = initTable[string, string]()
  var targets = initTable[string, string]()
  var pageUrls = initTable[string, string]()
  for page in site.pages & generatedPages(site):
    if page.output: pageUrls[page.url.strip(leading = false, chars = {'/'})] = page.source
  for page in site.pages:
    if not page.output: continue
    for value in page.redirectFrom:
      let url =
        try: redirectSource(site.config.basePath, value)
        except BlogError as cause: fail(page.source & ": " & cause.msg)
      # The host matches a rule's source against the path it serves from the
      # output root, which is the base path's root, so the source carries no
      # base path; the target is the URL the visitor's browser follows, so
      # it does.
      let source = outputRoute(site.config.basePath, url)
      if owners.hasKey(source):
        fail("redirect_from " & value & " is claimed by " & owners[source] & " and " & page.source)
      let bare = url.strip(leading = false, chars = {'/'})
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

proc checkDirectives*(declared: openArray[string]; registered: openArray[DirectiveRegistration];
    themeName: string) =
  ## Every directive a theme declares in theme.toml must be registered by
  ## the compiled `includes/directives.nim` (the theme's, or a site's copy
  ## that replaces it). A site may register more.
  var names: seq[string]
  for registration in registered: names.add registration.name
  for name in declared:
    if name notin names:
      fail("theme " & themeName & " declares directive " & name &
        " in theme.toml, but includes/directives.nim does not register it")

proc exportBlog*(root, output: string; layouts: openArray[LayoutEntry];
    options: BuildOptions; bundle: string; ogTemplate: OgTemplate;
    changed: var seq[string]; directives: seq[DirectiveRegistration] = @[]): ExportReport =
  ## Prepare all output using shared primitives and publish one complete tree.
  ## With `options.incremental` and an existing output, `changed` receives
  ## the output paths that were written or removed; otherwise it is empty.
  changed.setLen(0)
  validateOutput(root, output)
  var site = loadSite(root, options)
  let themeDir = resolveTheme(root, options.theme)
  var manifest: ThemeManifest
  if themeDir.len > 0:
    manifest = readThemeManifest(themeDir)
    checkDirectives(manifest.directives, directives, manifest.name)
  var hooks = if directives.len > 0: @[ParseHooks(name: "directives", directives: directives)]
    else: newSeq[ParseHooks]()
  # Diagrams are cached by content hash (`--diagram-cache`, which the CLI
  # keeps under build/isonim-blog/); a build without one (the Nix sandbox)
  # caches in a directory of its own for the length of the build.
  var diagramCache = options.diagramCache
  var temporaryCache = ""
  if site.config.diagrams.len > 0 and diagramCache.len == 0:
    temporaryCache = createTempDir("isonim-blog-diagrams-", "")
    diagramCache = temporaryCache
  defer:
    if temporaryCache.len > 0: removeDir(temporaryCache)
  hooks.add contentHooks(site.config, diagramCache)
  if site.config.url.len == 0:
    fail("url is required (in site.toml or with --url): canonical links, feeds and the sitemap need an absolute origin")
  if isPlaceholderOrigin(site.config.url):
    site.warnings.add "url " & site.config.url & " is a placeholder (a domain reserved for examples): " &
      "canonical links, feeds, the sitemap and OpenGraph URLs point there; set url in site.toml " &
      "(or pass --url) to the origin the site is deployed at"
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
  for base in [themeDir, root]:
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
  # The theme's stylesheets: the one generated from its tokens (unless the
  # site supplies its own file at that path), then those theme.toml lists.
  if themeDir.len > 0:
    if manifest.tokenFiles.len > 0 and not assetSources.hasKey(tokenStylesheetPath):
      addAsset(tokenStylesheetPath, tokenStylesheet(site.theme.tokens), "theme " & manifest.name & " tokens")
    if site.assets.hasKey(tokenStylesheetPath) and manifest.tokenFiles.len > 0:
      site.theme.stylesheets.add site.assets[tokenStylesheetPath]
    for path in manifest.stylesheets: site.theme.stylesheets.add site.assets[path]
  var stylesheetLinks = ""
  for url in site.theme.stylesheets:
    stylesheetLinks.add "<link rel=\"stylesheet\" href=\"" & escapeAttr(url) & "\">"
  var colorMetas: seq[ThemeColor]
  if themeDir.len > 0:
    for (color, media) in themeColors(site.theme.tokens, manifest.themeColor):
      colorMetas.add ThemeColor(color: color, media: media)
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
  # Each page's content is a page of its own, so it gets a fresh scope for
  # its table-region names and caption IDs. Listing pages join excerpts of
  # many posts, in many combinations, so every excerpt is rendered through
  # one scope for the whole site: any listing then holds unique names and
  # IDs. A layout may also show a post's excerpt beside its content, so the
  # excerpt avoids the content's names too, and its IDs are prefixed.
  let excerpts = newProsePageScope(idPrefix = "excerpt_")
  for page in site.pages.mitems:
    let source = page.source
    let doc =
      try:
        # Table captions use Pandoc's `Table: …` / `: …` paragraph syntax.
        parseMarkdownDocWithHooks(hooks, page.body, page.source,
          resolveContentPath = proc(path: string): string =
            if not routes.hasKey(path): fail(source & ": missing content target " & path)
            routes[path], firstLine = page.bodyLine, tableCaptions = true)
      except BlogError: raise
      except ValueError as cause: fail(withToolHint(cause.msg))
    checkImageAlt(doc, source)
    let content = newProsePageScope()
    page.content = renderProseHtml(doc, content)
    if page.toc: page.content = renderTocHtml(doc.headingTree) & page.content
    # A listing shows the excerpt under the post's title, so a table before
    # the excerpt's own first heading is named after the title.
    if page.excerpt.len == 0:
      page.excerpt = renderProseHtml(doc.excerpt, excerpts, content, heading = page.title)
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
  # The site's own origin (that of `url`) is not a remote host: the CSP's
  # 'self' already allows it, so an absolute URL on it is accepted without
  # being listed, and it is never added to `img-src`.
  let ownOrigin = webOrigin(site.config.url)
  var imageOrigins = site.config.remoteImageOrigins
  if ownOrigin.len > 0 and ownOrigin notin imageOrigins: imageOrigins.add ownOrigin
  let images = newResponsiveImages(ImageVariantConfig(vipsPath: getEnv("ISONIM_BLOG_VIPS"),
    widths: site.config.imageWidths, formats: imageFormats,
    maxSourceBytes: site.config.maxImageBytes, cacheDir: options.imageCache,
    avifQuality: site.config.imageQuality.avif, webpQuality: site.config.imageQuality.webp,
    remoteOrigins: imageOrigins),
    proc(path: string): string = basePath & "/" & path)
  var ogConfig: OgImageConfig
  var ogConfigured = false
  var siteCardUrl = ""
  proc renderCard(page: Page; source: string): string =
    ## The template's card for `page` as PNG bytes.
    if not ogConfigured:
      ogConfig = ogImageConfig()
      ogConfigured = true
    try: renderOgImage(ogTemplate(page, site), ogConfig)
    except OgImageError as cause: fail(source & ": OpenGraph image: " & cause.msg)
  proc ogImageUrl(page: Page): string =
    ## The absolute URL of the page's OpenGraph image: its `og_image` (a URL,
    ## or a file of the site named relative to the page's source or to the
    ## site root), else, for a content page, a card rendered from the
    ## template. Listing pages (the index, tag, category and archive pages and
    ## their pagination) are rarely shared and say nothing of their own, so
    ## they share one site card instead of a card each, as Hugo's and
    ## Docusaurus's site-wide images do.
    let value = page.ogImage.strip()
    if value.len > 0:
      let lower = value.toLowerAscii
      if lower.startsWith("https://") or lower.startsWith("http://"): return value
      let path = referencePath("/" & page.source, value)
      for rewrite in rewrites:
        if rewrite.original == path: return site.config.url & rewrite.hashed
      if siteFiles.hasKey(basePath & path): return site.config.url & basePath & path
      fail(page.source & ": og_image " & value & " is not a file of the site")
    if page.kind != pkContent:
      if siteCardUrl.len == 0:
        # The template sees the site as a listing page whose title is the
        # site's description (its title when it has none), with no date.
        let card = Page(kind: pkIndex, title: (if site.config.description.len > 0:
          site.config.description else: site.config.title),
          description: site.config.description, url: basePath & "/", layout: "index",
          source: "site.toml", output: true, pageNumber: 1, pageCount: 1)
        let png = renderCard(card, "site card")
        let path = hashedAssetName(siteCardPath, png)
        addFile(path, png, "OpenGraph site card")
        siteCardUrl = site.config.url & basePath & "/" & path
      return siteCardUrl
    let png = renderCard(page, page.source)
    let path = ogImagePath(site, page.url, png)
    addFile(path, png, "OpenGraph image of " & page.source)
    site.config.url & basePath & "/" & path
  var pages: seq[SitePage]
  var pagePolicies: seq[tuple[url, policy: string]]
  for page in site.pages & generatedPages(site):
    if not page.output: continue
    # The output root is the base path's root: the URL keeps base_path, the
    # file path does not.
    let route = outputRoute(basePath, page.url)
    let rel = outputPath(route)
    if origins.hasKey(rel.toLowerAscii):
      fail("output collision: " & origins[rel.toLowerAscii] & " and " & page.source)
    origins[rel.toLowerAscii] = page.source
    let isPost = page.kind == pkContent and page.collection == "posts"
    # The meta description falls back to the excerpt, then to the site's
    # description, as jekyll-seo-tag and Hugo do; a content page without its
    # own is a warning naming the fallback. Layouts still see the page's
    # own (possibly empty) description.
    var description = page.description
    if description.len == 0:
      let excerpt = shortDescription(excerptText(page.excerpt))
      description = if excerpt.len > 0: excerpt else: site.config.description
      if page.kind == pkContent:
        let fallback =
          if excerpt.len > 0: "uses the excerpt"
          elif description.len > 0: "uses the site's description"
          else: "is empty (no excerpt, and site.toml has no description)"
        site.warnings.add page.source & ": description is missing; the meta description " & fallback
    var headPage = page
    headPage.description = description
    var documentHead = DocumentHead(title: formatPageTitle(page.title, site.config.title),
      description: description, siteName: site.config.title,
      canonicalUrl: if page.canonical.len > 0: page.canonical else: site.config.url & page.url,
      ogType: if isPost: "article" else: "website",
      ogImage: ogImageUrl(page), twitterCard: "summary_large_image", themeColors: colorMetas)
    documentHead.jsonLd = jsonLdFor(site, headPage, documentHead.canonicalUrl)
    let bodyHtml = applyLayouts(page, site, layouts)
    let headHtml = renderPageHeadHtml(documentHead, keptScripts, policy = site.config.scriptPolicy)
    let ending = renderBodyEndScriptsHtml(keptScripts, policy = site.config.scriptPolicy)
    let headExtra = stylesheetLinks & feedLinksHtml(site, page) &
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
          " (ISONIM_BLOG_VIPS is not set: enter nix develop or use the packaged CLI)"
          elif "not an allowed remote image origin" in cause.msg:
          " (list it in [images] remote_origins in site.toml)" else: ""))
    var actualScripts = 0
    for script in scriptElements(document):
      if script.attr("type").toLowerAscii != "application/ld+json": inc actualScripts
    if actualScripts != keptScripts.len:
      fail(page.source & ": a layout emitted an undeclared script or data block")
    if eventHandlerAttributes(document).len > 0: fail(page.source & ": inline event handlers are not declared islands")
    # A <style> element is allowed by the hash of its text. The HTML parser
    # turns CR LF and CR into LF before the browser hashes the text; inside
    # SVG or MathML it also decodes references and CDATA, so text whose
    # hash cannot be computed from its bytes is refused, as is a NUL (which
    # the parser replaces).
    let (styles, unstyled) = styleElements(document)
    var styleBodies: seq[string]
    for element in styles:
      let body = element.body.replace("\r\n", "\n").replace('\r', '\n')
      if '\0' in body or (element.foreign and body.contains({'&', '<'})):
        fail(page.source & ": a layout emitted a <style> element whose text the " &
          "Content-Security-Policy cannot allow by its hash ('&', '<' inside inline SVG or MathML, " &
          "or a NUL); move it into a stylesheet under assets/")
      if body notin styleBodies: styleBodies.add body
    # A style attribute could be allowed only with 'unsafe-hashes', so it
    # fails the build instead of shipping a page the browser breaks.
    let inline = inlineStyles(unstyled)
    if inline.len > 0:
      fail(page.source & ": a layout emitted inline CSS (" & inline[0] & "), which the " &
        "Content-Security-Policy blocks; move it into a stylesheet under assets/ or a <style> element")
    var imageOrigins: seq[string]
    for origin in site.config.remoteImageOrigins:
      if origin != ownOrigin: imageOrigins.add origin
    # `_headers` rules are matched by the host against paths from the
    # output root, so they name the route, not the URL.
    pagePolicies.add (route, blogContentSecurityPolicy(keptScripts, imageOrigins, styleBodies))
    # The sitemap lists neither drafts and noindex pages nor posts dated
    # after the build date (present only with --future), nor a listing page
    # that lists only such posts.
    pages.add SitePage(route: route, html: document, lastmod: page.updated,
      noindex: page.noindex or page.future or page.listsOnlyPreviews)
  for file in images.files: addFile(file.path, file.content, "image variant")
  site.warnings.add images.warnings
  for (path, content) in siteFeeds(site):
    addFile(outputRoute(basePath, path)[1..^1], content, "generated feed " & path)
  # Pages are exported by route, so the sitemap's base URL carries the base
  # path that the routes leave out.
  addFile("sitemap.xml", renderSitemap(sitemapEntriesFor(pages, site.config.url & basePath)),
    "generated sitemap")
  # Crawlers read robots.txt only at the root of a host (RFC 9309 §2.3), so
  # a site under a base path, whose output root is not the host's root,
  # gets none. A site's own static/robots.txt replaces the generated one.
  if basePath.len == 0 and not origins.hasKey("robots.txt"):
    addFile("robots.txt", renderRobots(site.config.url & "/sitemap.xml"), "generated robots.txt")
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
      if themeDir.len == 0: getEnv("ISONIM_BLOG_THEME_REVISION", "none")
      else: getEnv("ISONIM_BLOG_THEME_REVISION", themeTreeHash(themeDir))
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
    options = BuildOptions(); bundle = ""; ogTemplate: OgTemplate = defaultOgImage;
    directives: seq[DirectiveRegistration] = @[]): ExportReport =
  ## `exportBlog` without the list of changed files.
  var changed: seq[string]
  exportBlog(root, output, layouts, options, bundle, ogTemplate, changed, directives)

proc siteMain*(layouts: openArray[LayoutEntry]; ogTemplate: OgTemplate = defaultOgImage;
    directives: seq[DirectiveRegistration] = @[]) =
  ## Generated exporter protocol: output directory, then site root and options.
  try:
    let args = commandLineParams()
    if args.len > 1 and args[1] == "--prepare-only": return
    if args == @["--islands"]:
      var values = newJArray()
      for island in declaredIslands(layouts): values.add %*{"module": island.module, "selector": island.selector}
      echo $values
      return
    if args == @["--directives"]:
      # The registered directive names, for the theme conformance kit.
      var names = newJArray()
      for registration in directives: names.add %registration.name
      echo $names
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
      of "--root", "--url", "--now", "--bundle", "--theme", "--image-cache", "--diagram-cache":
        let flag = args[i]
        inc i
        if i >= args.len: fail("missing value for " & flag)
        case flag
        of "--root": root = args[i]
        of "--url": options.url = args[i]
        of "--now": options.now = args[i]
        of "--theme": options.theme = absolutePath(args[i])
        of "--image-cache": options.imageCache = absolutePath(args[i])
        of "--diagram-cache": options.diagramCache = absolutePath(args[i])
        else: bundle = args[i]
      else: fail("unknown exporter argument " & args[i])
      inc i
    # The wall clock is read once, here, so the summary names the clock the
    # build used.
    let explicitClock = options.now.len > 0
    let now = if explicitClock: parseBuildClock(options.now) else: wallClock()
    options.now = "@" & $now
    var changed: seq[string]
    let report = exportBlog(root, args[0], layouts, options, bundle, ogTemplate, changed, directives)
    echo "Built " & $report.pages.len & " pages and " & $report.files.len & " files in " & args[0]
    echo "Future-dated posts are judged against " & formatBuildClock(now) &
      (if explicitClock: " (--now)" else: " (the wall clock; --now sets another)")
    if options.incremental:
      echo "Updated " & $changed.len & " changed files"
      for path in changed: echo "  " & path
  except CatchableError as cause:
    stderr.writeLine(cause.msg)
    quit(1)
