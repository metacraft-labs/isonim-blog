## Backend-independent site data, configuration mapping and URL rules.
## TOML decoding is a native input adapter; layouts see ordinary typed values.
import std/[json, strutils, tables, algorithm, times, uri]
import isonim/content/frontmatter
import isonim/static/scripts
from isonim/static/images import defaultAvifQuality, defaultWebpQuality
from isonim/static/urls import parseWebOrigin
export json, tables, frontmatter, scripts

type
  BlogError* = object of ValueError
  CollectionConfig* = object
    output*: bool
    permalink*: string
    extra*: JsonNode  ## the collection's table without `output`/`permalink`
  SiteConfig* = object
    ## Typed settings. The raw tables (`author` ... `output`) keep every key
    ## they were given, so a nested key this version does not know survives
    ## for layouts; unknown top-level keys are collected in `extra`.
    title*, description*, url*, basePath*, language*, theme*, permalink*, timezone*: string
    author*, feeds*, taxonomies*, archives*, markdown*, images*, output*, analytics*, extra*: JsonNode
    collections*: OrderedTable[string, CollectionConfig]
    scriptPolicy*: ScriptPolicy
    paginate*: int
    indexPermalink*, yearPermalink*, monthPermalink*: string
      ## Generated listing pages (`[archives]`); "" turns one off.
    indexYields*: bool
      ## `[archives] index` was not set, so the index takes the default,
      ## the home page, and `loadSite` moves it to `yieldedIndexPermalink`
      ## when a content page (in practice `pages/index.md`) is the home page.
    tagPermalink*, categoryPermalink*: string
      ## One page per term (`[taxonomies]`); "" turns one off.
    rssPath*, atomPath*: string  ## Feed files (`[feeds]`); "" turns one off.
    perTagFeeds*, fullContentFeeds*: bool
    imageWidths*: seq[int]     ## `[images] widths`: variant widths in pixels.
    imageFormats*: seq[string] ## `[images] formats`: "avif" and/or "webp".
    maxImageBytes*: int        ## `[images] max_source_bytes`: larger is an error.
    imageQuality*: tuple[avif, webp: int]
      ## `[images] quality`: encoder quality 1-100 per variant format.
    remoteImageOrigins*: seq[string]
      ## `[images] remote_origins`: the origins (`https://cdn.example.net`)
      ## pages may show images from; they are added to the CSP `img-src`.
    skipExternal*: seq[string]
      ## `[check] skip_external`: the links `check --external` does not
      ## request, normalised by `parseSkipExternal`: URL prefixes
      ## (`https://example.com/members/`) and host names (`example.com`,
      ## which also covers its subdomains).
  PageKind* = enum
    ## What produced a page: a content file, or one of the generated listings.
    pkContent, pkIndex, pkTag, pkCategory, pkYear, pkMonth
  PageLink* = object
    ## A reference to another page, for navigation.
    title*, url*, date*: string
  Page* = object
    source*, title*, description*, date*, updated*, slug*, url*, layout*, collection*: string
    body*, content*, excerpt*, image*, imageAlt*, ogImage*, canonical*, series*: string
    tags*, categories*, redirectFrom*: seq[string]
    seriesOrder*, bodyLine*: int
    draft*, noindex*, toc*, output*: bool
    future*: bool  ## dated after the build date; present only with --future
    extra*: FrontMatter
    kind*: PageKind
    previous*, next*: PageLink
      ## Posts only: the older and the newer neighbouring post; empty url
      ## at either end.
    seriesPosts*: seq[PageLink]
      ## Posts in a series: the whole series in reading order (series_order,
      ## then date, then slug), this post included.
    term*: string
      ## Generated pages: the tag or category, the year (`2020`) or the
      ## month (`2020-02`); empty for the index.
    listing*: seq[Page]
      ## Generated pages: the posts this page lists, newest first, then slug.
    pageNumber*, pageCount*: int  ## Index pages: 1-based position and total.
    previousPageUrl*, nextPageUrl*: string  ## Index pages: neighbours, or "".
  ThemeInfo* = object
    ## The site's theme, as layouts see it; `name` is empty without one.
    name*, version*: string
    tokens*: JsonNode
      ## Resolved design tokens: `{key: {"value": v, "dark": d}}`, `dark`
      ## only for a token that differs in the dark scheme (theme_format).
    stylesheets*: seq[string]
      ## URLs every page links, in order: the generated token stylesheet,
      ## then the theme's declared stylesheets (a site's file of the same
      ## path replaces the theme's).
  Site* = object
    config*: SiteConfig
    theme*: ThemeInfo
    posts*, pages*: seq[Page]
    collections*: OrderedTable[string, seq[Page]]
    tags*, categories*: OrderedTable[string, seq[Page]]
      ## Every term in byte order, each with its posts newest first, then slug.
    data*, extra*: JsonNode
    assets*: OrderedTable[string, string]
    now*: int64
      ## The build clock, in seconds since the Unix epoch: a post dated after
      ## its civil date in `timezone` is future. `BuildOptions.now`, or the
      ## wall clock.
    sourceDateEpoch*: int64
      ## The time written into the output (build.json, an empty feed's date):
      ## `SOURCE_DATE_EPOCH` when it is set, otherwise `now`.
    buildDate*: string  ## the civil date (YYYY-MM-DD) of `sourceDateEpoch` in site.timezone
    warnings*: seq[string]
  BuildOptions* = object
    drafts*, future*: bool
    outDir*, url*, theme*: string
    now*: string
      ## The build clock (`--now`): `@<seconds since the Unix epoch>` or an RFC
      ## 3339 date-time with an offset (a bare number is refused); empty
      ## selects the wall clock. See `inputs.parseBuildClock`.
    imageCache*: string  ## Optional directory where image variants are reused.
    incremental*: bool
      ## Update the output in place, writing only files whose bytes changed
      ## and removing files the build no longer produces (`serve`), instead
      ## of replacing the whole directory.
  Island* = object
    ## A layout declares a module in includes/ exporting
    ## `mount*(element: Element)`, with `Element` from isonim/web/dom_api.
    ## All declared modules compile into one bundle only in islands mode.
    module*, selector*: string
  LayoutProc* = proc(page: Page; site: Site; content: string): string
  OgTemplate* = proc(page: Page; site: Site): string
    ## Returns the SVG of a page's 1200x630 OpenGraph card (`og.svg.nim`).
  LayoutEntry* = object
    name*, parent*: string
    render*: LayoutProc
    islands*: seq[Island]

const
  maxDescriptionRunes* = 160
    ## The description length the build warns above, in characters (Unicode
    ## code points). Search engines cut a snippet by pixel width, not by
    ## characters, so this is a heuristic and only a warning. A description
    ## taken from the excerpt is cut to this length.
  defaultIndexPermalink* = "/"
    ## The post index when `[archives] index` is not set: the home page, as
    ## blog-first generators (Jekyll, Hexo, Pelican) place it.
  yieldedIndexPermalink* = "/posts/"
    ## Where that default index moves when a content page is the home page.

proc fail*(message: string) {.noreturn.} = raise newException(BlogError, message)

proc isPlaceholderOrigin*(url: string): bool =
  ## Whether `url` names a domain reserved for documentation (RFC 2606
  ## sections 2 and 3, https://www.rfc-editor.org/rfc/rfc2606): the
  ## `.example` top-level domain, or example.com, example.net or
  ## example.org and their subdomains. A site there cannot be deployed, so
  ## its canonical links, feeds and sitemap would point nowhere; `new site`
  ## writes such a placeholder.
  if url.len == 0: return false
  let host = parseUri(url).hostname.toLowerAscii.strip(leading = false, chars = {'.'})
  if host == "example" or host.endsWith(".example"): return true
  for domain in ["example.com", "example.net", "example.org"]:
    if host == domain or host.endsWith("." & domain): return true
  false

proc stringValue*(node: JsonNode; key: string; default = ""): string =
  if not node.hasKey(key): return default
  if node[key].kind != JString: fail(key & " must be a string")
  node[key].getStr

proc boolValue*(node: JsonNode; key: string; default = false): bool =
  if not node.hasKey(key): return default
  if node[key].kind != JBool: fail(key & " must be a boolean")
  node[key].getBool

proc objectValue(node: JsonNode; key: string): JsonNode =
  result = if node.hasKey(key): node[key] else: newJObject()
  if result.kind != JObject: fail(key & " must be a table")

proc validateName*(name: string) =
  if name.len == 0 or name[0] notin {'a'..'z', 'A'..'Z', '_'}:
    fail("invalid module or collection name: " & name)
  for c in name:
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_', '-'}:
      fail("invalid module or collection name: " & name)

proc cleanRoute*(route: string): string =
  ## Canonical route form, shared by collision checks on both backends.
  if route.len == 0 or route[0] != '/' or route.startsWith("//"):
    fail("permalink must start with one slash: " & route)
  if route.contains({'\\', '?', '#', '\0'..' ', ':'}):
    fail("invalid character in permalink: " & route)
  let decoded = decodeUrl(route, decodePlus = false)
  if decoded.contains({'\\', '?', '#', '\0'..' '}): fail("unsafe encoded permalink: " & route)
  let stripped = decoded.strip(chars = {'/'})
  if stripped.len > 0:
    for part in stripped.split('/'):
      if part in ["", ".", ".."]: fail("unsafe permalink segment: " & route)
  if decoded != route: fail("permalinks use literal URL path characters, not percent escapes: " & route)
  if route == "/" or route.endsWith("/") or route.endsWith(".html"): route
  else: route & "/"

proc redirectSource*(basePath, value: string): string =
  ## A `redirect_from` entry as a `_redirects` source: a literal site path
  ## (the old URL, kept exactly, with or without a trailing slash) under the
  ## base path. Placeholders, splats, queries, fragments, whitespace and
  ## percent escapes are refused, so every entry is one static rule.
  if value.len == 0 or value[0] != '/' or value.startsWith("//"):
    fail("redirect_from must be a site path starting with one slash: " & value)
  if value.contains({'\\', '?', '#', '*', ':', '%', '!', '\0'..' ', '\x7f'}):
    fail("invalid character in redirect_from: " & value)
  let parts = value[1..^1].split('/')
  for i, part in parts:
    if part in [".", ".."] or (part.len == 0 and i < parts.high):
      fail("unsafe redirect_from segment: " & value)
  basePath & value

proc outputRoute*(basePath, url: string): string =
  ## The route of a site URL path relative to the output root. The output
  ## directory is the base path's root, as with Hugo's `baseURL`, Jekyll's
  ## `baseurl` and Eleventy's `pathPrefix`: `base_path` appears in the URLs a
  ## build writes, never in where it writes them (`/blog/posts/x/` is
  ## written as `posts/x/index.html`). A URL outside the base path is a
  ## `BlogError`.
  if basePath.len == 0: return url
  if url == basePath or url == basePath & "/": return "/"
  if not url.startsWith(basePath & "/"):
    fail(url & " is not under base_path " & basePath)
  url[basePath.len .. ^1]

proc outputPath*(route: string): string =
  let value = cleanRoute(route)
  if value == "/": "index.html"
  elif value.endsWith(".html"): value[1..^1]
  else: value[1..^1] & "index.html"

proc placeholders*(pattern: string): seq[string] =
  ## The `:name` placeholders of a permalink pattern, in order.
  var i = 0
  while i < pattern.len:
    if pattern[i] == ':':
      var j = i + 1
      while j < pattern.len and pattern[j] in {'a'..'z', '_'}: inc j
      result.add pattern[i + 1 ..< j]
      i = j
    else: inc i

proc expandPattern*(pattern: string; values: openArray[(string, string)]): string =
  ## Substitute the placeholders a generated page supports; any other is an
  ## error, so a misspelt placeholder cannot silently become literal text.
  var i = 0
  while i < pattern.len:
    if pattern[i] != ':':
      result.add pattern[i]
      inc i
      continue
    var j = i + 1
    while j < pattern.len and pattern[j] in {'a'..'z', '_'}: inc j
    let key = pattern[i + 1 ..< j]
    var found = false
    for (name, value) in values:
      if name == key:
        result.add value
        found = true
        break
    if not found: fail("unsupported placeholder :" & key & " in " & pattern)
    i = j
  result = cleanRoute(result)

proc feedPath*(path: string): string =
  ## A feed file path: absolute, a file (no trailing slash), no dot segments
  ## or unsafe characters. "" turns the feed off.
  if path.len == 0: return ""
  if path[0] != '/' or path.endsWith("/") or path.startsWith("//"):
    fail("a feed path must be a file path starting with one slash: " & path)
  if path.contains({'\\', '?', '#', '%', ':', '\0'..' '}): fail("invalid character in feed path: " & path)
  for part in path[1..^1].split('/'):
    if part in ["", ".", ".."]: fail("unsafe feed path segment: " & path)
  path

proc termPermalink(taxonomies: JsonNode; name, default: string): string =
  ## `[taxonomies] tags = { permalink = "/tags/:name/" }`; "" turns it off.
  let table = taxonomies.objectValue(name)
  result = table.stringValue("permalink", default)
  if result.len == 0: return
  let used = placeholders(result)
  if used.len != 1 or used[0] notin ["name", "slug"]:
    fail("taxonomies." & name & ".permalink needs exactly one :name placeholder: " & result)
  discard expandPattern(result, [("name", "x"), ("slug", "x")])

proc archivePattern(archives: JsonNode; key, default: string; required: openArray[string]): string =
  ## `[archives] index | year | month`; "" turns a listing off. Each
  ## pattern must use exactly the placeholders that tell its pages apart.
  result = archives.stringValue(key, default)
  if result.len == 0: return
  var used = placeholders(result)
  used.sort()
  var wanted = @required
  wanted.sort()
  if used != wanted:
    fail("archives." & key & " must use " &
      (if wanted.len == 0: "no placeholders" else: ":" & wanted.join(" and :")) & ": " & result)
  var values: seq[(string, string)]
  for name in required: values.add (name, "00")
  discard expandPattern(result, values)

proc intList(node: JsonNode; key: string; default: openArray[int]): seq[int] =
  if not node.hasKey(key): return @default
  if node[key].kind != JArray: fail(key & " must be a list of integers")
  for item in node[key]:
    if item.kind != JInt or item.getInt <= 0: fail(key & " must be a list of positive integers")
    result.add item.getInt

proc parseImages(config: var SiteConfig) =
  ## `[images]`: the widths and formats of responsive variants and the
  ## largest source accepted, the encoder quality and the origins remote
  ## images may come from. The defaults are the values in the documented
  ## example (480, 960 and 1600 pixels; AVIF and WebP; 2 MB; quality AVIF 50
  ## and WebP 75; no remote origin).
  let images = config.images
  config.imageWidths = images.intList("widths", [480, 960, 1600])
  config.imageFormats = @[]
  if images.hasKey("formats"):
    if images["formats"].kind != JArray: fail("images.formats must be a list")
    for item in images["formats"]:
      if item.kind != JString or item.getStr notin ["avif", "webp"]:
        fail("images.formats may name only \"avif\" and \"webp\"")
      if item.getStr notin config.imageFormats: config.imageFormats.add item.getStr
  else: config.imageFormats = @["avif", "webp"]
  config.maxImageBytes = 2_000_000
  if images.hasKey("max_source_bytes"):
    if images["max_source_bytes"].kind != JInt or images["max_source_bytes"].getInt <= 0:
      fail("images.max_source_bytes must be a positive integer")
    config.maxImageBytes = images["max_source_bytes"].getInt
  # Encoder quality, per format. The defaults are those of AVIF Q50 and WebP
  # Q75 that every variant was made with before the setting existed.
  config.imageQuality = (avif: defaultAvifQuality, webp: defaultWebpQuality)
  if images.hasKey("quality"):
    let quality = images["quality"]
    if quality.kind != JObject:
      fail("images.quality must be a table, as in quality = { avif = 50, webp = 75 }")
    for key, value in quality:
      if key notin ["avif", "webp"]: fail("images.quality may name only avif and webp, not " & key)
      if value.kind != JInt or value.getInt notin 1 .. 100:
        fail("images.quality." & key & " must be an integer from 1 to 100")
      if key == "avif": config.imageQuality.avif = value.getInt
      else: config.imageQuality.webp = value.getInt
  # Remote images: only from the origins listed, which also go into the
  # Content-Security-Policy, so what the build accepts the browser loads.
  config.remoteImageOrigins = @[]
  if images.hasKey("remote_origins"):
    if images["remote_origins"].kind != JArray: fail("images.remote_origins must be a list of origins")
    for item in images["remote_origins"]:
      if item.kind != JString: fail("images.remote_origins must be a list of origins")
      let origin =
        try: parseWebOrigin(item.getStr)
        except ValueError as cause: fail("images.remote_origins: " & cause.msg)
      if origin notin config.remoteImageOrigins: config.remoteImageOrigins.add origin

proc lowerSchemeAndAuthority(url: string): string =
  ## `url` with everything before the path (scheme and authority) in lower
  ## case: those parts compare without case (RFC 3986 section 6.2.2.1), the
  ## rest as written.
  let marker = url.find("://")
  if marker < 0: return url
  let pathStart = url.find('/', marker + 3)
  if pathStart < 0: url.toLowerAscii
  else: url[0 ..< pathStart].toLowerAscii & url[pathStart .. ^1]

proc parseSkipExternal*(value: string): string =
  ## One `[check] skip_external` entry, normalised. It is either an `http(s)`
  ## URL prefix, with its scheme and host lower-cased
  ## (`https://Example.com/a` becomes `https://example.com/a`), as Zola's
  ## `[link_checker] skip_prefixes`
  ## (https://www.getzola.org/documentation/getting-started/configuration/),
  ## or a bare host name, lower-cased, which also covers its subdomains
  ## (`example.com` covers `www.example.com`). Anything else is a
  ## `BlogError`: an empty entry, another scheme, user information, a
  ## fragment, whitespace, or a host with a port or path but no scheme. A
  ## typo then fails the build instead of silently requesting the site.
  let entry = value.strip()
  if entry.len == 0: fail("check.skip_external: an entry is empty")
  if "://" in entry:
    let parsed = parseUri(entry)
    if parsed.scheme.toLowerAscii notin ["http", "https"] or parsed.hostname.len == 0 or
        parsed.username.len > 0 or parsed.password.len > 0 or
        entry.contains({'\0'..' ', '#', '\x7f'}):
      fail("check.skip_external: " & value & " is not an http(s) URL prefix, as in " &
        "\"https://example.com/members/\"")
    return lowerSchemeAndAuthority(entry)
  let host = entry.toLowerAscii
  for label in host.split('.'):
    if label.len == 0 or label.len > 63 or label[0] == '-' or label[^1] == '-' or
        not label.allCharsInSet({'a'..'z', '0'..'9', '-'}):
      fail("check.skip_external: " & value & " is neither a host name (\"example.com\", " &
        "no scheme, port or path) nor an http(s) URL prefix (\"https://example.com/members/\")")
  host

proc skipsExternal*(skip: openArray[string]; url: string): bool =
  ## Whether `check --external` leaves `url` unrequested: it starts with a
  ## URL prefix of `skip` (scheme and host compared without case), or its
  ## host is a host name of `skip` or a subdomain of one. `skip` holds
  ## entries normalised by `parseSkipExternal`.
  if skip.len == 0: return false
  let host = parseUri(url).hostname.toLowerAscii.strip(leading = false, chars = {'.'})
  let normalised = lowerSchemeAndAuthority(url)
  for entry in skip:
    if "://" in entry:
      if normalised.startsWith(entry): return true
    elif host.len > 0 and (host == entry or host.endsWith("." & entry)):
      return true
  false

proc parseCheck(config: var SiteConfig; check: JsonNode) =
  ## `[check]`: settings of `isonim-blog check`. Its only key is
  ## `skip_external`; another key is an error, because a misspelt key would
  ## otherwise be ignored and every skipped site requested again.
  config.skipExternal = @[]
  for key, value in check:
    if key != "skip_external": fail("check: unknown key " & key & " (the known key is skip_external)")
    if value.kind != JArray: fail("check.skip_external must be a list of host names and URL prefixes")
    for item in value:
      if item.kind != JString: fail("check.skip_external must be a list of host names and URL prefixes")
      let entry = parseSkipExternal(item.getStr)
      if entry notin config.skipExternal: config.skipExternal.add entry

proc parseConfig*(node: JsonNode): SiteConfig =
  ## Map decoded TOML without throwing away unknown top-level values.
  if node.kind != JObject: fail("site.toml must be a table")
  result.title = node.stringValue("title")
  if result.title.len == 0: fail("site.toml: title is required")
  result.description = node.stringValue("description")
  result.url = node.stringValue("url")
  if result.url.len > 0:
    let origin = parseUri(result.url)
    if origin.scheme notin ["https", "http"] or origin.hostname.len == 0 or
        origin.query.len > 0 or origin.anchor.len > 0 or origin.path notin ["", "/"]:
      fail("url must be an http(s) origin")
    result.url = result.url.strip(leading = false, chars = {'/'})
  result.basePath = node.stringValue("base_path").strip(leading = false, chars = {'/'})
  if result.basePath.len > 0: discard cleanRoute(result.basePath)
  result.language = node.stringValue("language", "en")
  result.theme = node.stringValue("theme")
  result.timezone = node.stringValue("timezone", "UTC")
  result.permalink = node.stringValue("permalink", "/posts/:slug/")
  result.author = node.objectValue("author")
  result.feeds = node.objectValue("feeds")
  result.taxonomies = node.objectValue("taxonomies")
  result.markdown = node.objectValue("markdown")
  result.images = node.objectValue("images")
  parseImages(result)
  parseCheck(result, node.objectValue("check"))
  let output = node.objectValue("output")
  result.output = output
  result.analytics = output.objectValue("analytics")
  case output.stringValue("scripts", "none")
  of "none": result.scriptPolicy = spNone
  of "islands": result.scriptPolicy = spDeclared
  else: fail("output.scripts must be none or islands")
  # Feeds, taxonomies and archives: typed settings with unknown keys kept.
  let feeds = result.feeds
  result.rssPath = feedPath(feeds.stringValue("rss", "/feed.xml"))
  result.atomPath = feedPath(feeds.stringValue("atom", "/atom.xml"))
  result.perTagFeeds = feeds.boolValue("per_tag", true)
  result.fullContentFeeds = feeds.boolValue("full_content", true)
  result.tagPermalink = termPermalink(result.taxonomies, "tags", "/tags/:name/")
  result.categoryPermalink = termPermalink(result.taxonomies, "categories", "/categories/:name/")
  result.archives = node.objectValue("archives")
  result.indexYields = not result.archives.hasKey("index")
  result.indexPermalink = archivePattern(result.archives, "index", defaultIndexPermalink, [])
  result.yearPermalink = archivePattern(result.archives, "year", "/:year/", ["year"])
  result.monthPermalink = archivePattern(result.archives, "month", "", ["year", "month"])
  result.paginate = 10
  if node.hasKey("paginate"):
    if node["paginate"].kind != JInt or node["paginate"].getInt <= 0:
      fail("paginate must be a positive integer")
    result.paginate = node["paginate"].getInt
  result.collections = initOrderedTable[string, CollectionConfig]()
  let collections = node.objectValue("collections")
  var names: seq[string]
  for key in collections.keys: names.add key
  names.sort()
  for name in names:
    validateName(name)
    if name == "posts": fail("posts is a built-in collection")
    let value = collections.objectValue(name)
    var extra = newJObject()
    for key, item in value:
      if key notin ["output", "permalink"]: extra[key] = item.copy
    result.collections[name] = CollectionConfig(output: value.boolValue("output"),
      permalink: value.stringValue("permalink", "/" & name & "/:slug/"), extra: extra)
  result.extra = newJObject()
  for key, value in node:
    if key notin ["title", "description", "url", "base_path", "language", "theme",
        "permalink", "timezone", "author", "feeds", "taxonomies", "collections",
        "archives", "markdown", "images", "output", "paginate", "check"]:
      result.extra[key] = value.copy

proc validDate*(value: string): string =
  ## ISO civil date. Calendar validation is exact, including leap years.
  if value.len != 10 or value[4] != '-' or value[7] != '-':
    fail("date must be YYYY-MM-DD: " & value)
  for i, c in value:
    if i notin [4, 7] and c notin {'0'..'9'}: fail("invalid date: " & value)
  try:
    let date = parse(value, "yyyy-MM-dd", utc())
    if date.format("yyyy-MM-dd") != value or date.year == 0: fail("invalid date: " & value)
  except TimeParseError: fail("invalid date: " & value)
  value

proc slugify*(value: string): string =
  ## Stable ASCII URL slug. Explicit slugs retain their authored case.
  for c in value.toLowerAscii:
    if c in {'a'..'z', '0'..'9'}: result.add c
    elif result.len > 0 and result[^1] != '-': result.add '-'
  result = result.strip(chars = {'-'})
  if result.len == 0: fail("title has no URL slug; provide slug explicitly")

proc permalinkFor*(pattern: string; page: Page): string =
  var i = 0
  while i < pattern.len:
    if pattern[i] != ':':
      result.add pattern[i]
      inc i
      continue
    inc i
    let start = i
    while i < pattern.len and pattern[i] in {'a'..'z', '_'}: inc i
    let key = pattern[start..<i]
    case key
    of "slug", "name": result.add page.slug
    of "title": result.add slugify(page.title)
    of "collection": result.add page.collection
    of "categories":
      var categories: seq[string]
      for category in page.categories: categories.add slugify(category)
      result.add categories.join("/")
    of "year", "month", "day":
      if page.date.len == 0: fail(page.source & ": permalink requires a date")
      result.add (case key
        of "year": page.date[0..3]
        of "month": page.date[5..6]
        else: page.date[8..9])
    else: fail("unknown permalink placeholder: :" & key)
  result = cleanRoute(result)

proc pageFromSource*(source, raw, collection, defaultPattern: string;
    isDraft = false): Page =
  ## Decode the shared YAML subset and retain unknown fields unchanged.
  let parsed = readFrontMatter(raw)
  let fm = parsed.front
  result = Page(source: source, body: parsed.body, bodyLine: parsed.bodyLine,
    collection: collection, output: true)
  let parts = source.split('/')
  var name = parts[^1]
  if name == "index.md" and parts.len > 1: name = parts[^2]
  elif name.endsWith(".md"): name.setLen(name.len - 3)
  if name.len > 10 and name[4] == '-' and name[7] == '-' and name[10] == '-':
    result.date = name[0..9]
    name = name[11..^1]
  result.date = fm.getStr("date", result.date)
  if result.date.len > 0: result.date = validDate(result.date)
  result.updated = fm.getStr("updated", result.date)
  if result.updated.len > 0: result.updated = validDate(result.updated)
  result.draft = isDraft or fm.getBool("draft")
  if collection == "posts" and not result.draft and result.date.len == 0:
    fail(source & ": a post requires a date")
  result.slug = fm.getStr("slug", name)
  if result.slug.len == 0 or result.slug.contains({'/', '\\', ':', '?', '#', '\0'..' '}):
    fail(source & ": invalid slug")
  result.title = fm.getStr("title", name.replace('-', ' '))
  result.description = fm.getStr("description")
  result.layout = fm.getStr("layout", if collection == "posts": "post" else: "page")
  validateName(result.layout)
  result.tags = fm.getList("tags")
  result.categories = fm.getList("categories")
  result.series = fm.getStr("series")
  result.seriesOrder = fm.getInt("series_order")
  result.image = fm.getStr("image")
  result.imageAlt = fm.getStr("image_alt")
  # An empty image_alt is an explicit decorative image, as alt="" is; only
  # a missing one is an error.
  if result.image.len > 0 and "image_alt" notin fm:
    fail(source & ": image_alt is required with image (image_alt: \"\" marks a decorative image)")
  result.ogImage = fm.getStr("og_image")
  result.excerpt = fm.getStr("excerpt")
  result.noindex = result.draft or fm.getBool("noindex")
  result.toc = fm.getBool("toc")
  result.canonical = fm.getStr("canonical")
  result.redirectFrom = fm.getList("redirect_from")
  result.url = permalinkFor(fm.getStr("permalink", defaultPattern), result)
  result.extra = fm.without(["title", "description", "date", "updated", "slug",
    "permalink", "layout", "tags", "categories", "draft", "series", "series_order",
    "image", "image_alt", "og_image", "excerpt", "toc", "noindex", "canonical", "redirect_from"])

proc sortPages*(pages: var seq[Page]) =
  pages.sort(proc(a, b: Page): int =
    result = cmp(b.date, a.date)
    if result == 0: result = cmp(a.slug, b.slug)
    if result == 0: result = cmp(a.source, b.source))

proc checkCollisions*(pages: openArray[Page]) =
  var owners = initTable[string, string]()
  for page in pages:
    if not page.output: continue
    let path = outputPath(page.url).toLowerAscii
    if owners.hasKey(path): fail("output collision: " & owners[path] & " and " & page.source & " -> " & path)
    owners[path] = page.source
  for path, source in owners:
    var parent = path
    while '/' in parent:
      parent = parent[0..<parent.rfind('/')]
      if owners.hasKey(parent): fail("output collision: " & owners[parent] & " and " & source)
