## Backend-independent site data, configuration mapping and URL rules.
## TOML decoding is a native input adapter; layouts see ordinary typed values.
import std/[json, strutils, tables, algorithm, times, uri]
import isonim/content/frontmatter
import isonim/static/scripts
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
    tagPermalink*, categoryPermalink*: string
      ## One page per term (`[taxonomies]`); "" turns one off.
    rssPath*, atomPath*: string  ## Feed files (`[feeds]`); "" turns one off.
    perTagFeeds*, fullContentFeeds*: bool
    imageWidths*: seq[int]     ## `[images] widths`: variant widths in pixels.
    imageFormats*: seq[string] ## `[images] formats`: "avif" and/or "webp".
    maxImageBytes*: int        ## `[images] max_source_bytes`: larger is an error.
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
  Site* = object
    config*: SiteConfig
    posts*, pages*: seq[Page]
    collections*: OrderedTable[string, seq[Page]]
    tags*, categories*: OrderedTable[string, seq[Page]]
      ## Every term in byte order, each with its posts newest first, then slug.
    data*, extra*: JsonNode
    assets*: OrderedTable[string, string]
    sourceDateEpoch*: int64
    buildDate*: string  ## the build's civil date (YYYY-MM-DD) in site.timezone
    warnings*: seq[string]
  BuildOptions* = object
    drafts*, future*: bool
    outDir*, url*, theme*: string
    imageCache*: string  ## Optional directory where image variants are reused.
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

proc fail*(message: string) {.noreturn.} = raise newException(BlogError, message)

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
  ## largest source accepted. The defaults are the values in the
  ## documented example (480, 960 and 1600 pixels; AVIF and WebP; 2 MB).
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
  result.indexPermalink = archivePattern(result.archives, "index", "/posts/", [])
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
        "archives", "markdown", "images", "output", "paginate"]:
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
  if result.image.len > 0 and result.imageAlt.len == 0: fail(source & ": image_alt is required")
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
