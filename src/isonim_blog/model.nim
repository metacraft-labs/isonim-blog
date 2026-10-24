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
    author*, feeds*, taxonomies*, markdown*, images*, output*, analytics*, extra*: JsonNode
    collections*: OrderedTable[string, CollectionConfig]
    scriptPolicy*: ScriptPolicy
    paginate*: int
  Page* = object
    source*, title*, description*, date*, updated*, slug*, url*, layout*, collection*: string
    body*, content*, excerpt*, image*, imageAlt*, ogImage*, canonical*, series*: string
    tags*, categories*, redirectFrom*: seq[string]
    seriesOrder*, bodyLine*: int
    draft*, noindex*, toc*, output*: bool
    extra*: FrontMatter
  Site* = object
    config*: SiteConfig
    posts*, pages*: seq[Page]
    collections*: OrderedTable[string, seq[Page]]
    data*, extra*: JsonNode
    assets*: OrderedTable[string, string]
    sourceDateEpoch*: int64
    warnings*: seq[string]
  BuildOptions* = object
    drafts*, future*: bool
    outDir*, url*, theme*: string
  Island* = object
    ## A layout declares a module in includes/ exporting
    ## `mount*(element: Element)`, with `Element` from isonim/web/dom_api.
    ## All declared modules compile into one bundle only in islands mode.
    module*, selector*: string
  LayoutProc* = proc(page: Page; site: Site; content: string): string
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
  let output = node.objectValue("output")
  result.output = output
  result.analytics = output.objectValue("analytics")
  case output.stringValue("scripts", "none")
  of "none": result.scriptPolicy = spNone
  of "islands": result.scriptPolicy = spDeclared
  else: fail("output.scripts must be none or islands")
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
        "markdown", "images", "output", "paginate"]:
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
