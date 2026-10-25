## Native input boundary. Only named input directories are traversed. Symlinks
## are refused instead of following paths outside a site's declared inputs.
import std/[os, osproc, streams, strutils, algorithm, json, times, tables, strtabs]
import ./[model, archives]
import isonim/static/buildinfo

const tomlDecoder = """
import datetime, json, math, sys, tomllib
def encode(value):
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        return {"$toml": type(value).__name__, "value": value.isoformat()}
    if isinstance(value, int) and not isinstance(value, bool) and abs(value) > 9007199254740991:
        return {"$toml": "integer", "value": str(value)}
    if isinstance(value, float) and not math.isfinite(value):
        return {"$toml": "float", "value": repr(value)}
    if isinstance(value, dict):
        items = {key: encode(value[key]) for key in sorted(value)}
        return {"$toml": "table", "value": items} if "$toml" in value else items
    if isinstance(value, list):
        return [encode(item) for item in value]
    return value
try:
    with open(sys.argv[1], "rb") as source:
        value = tomllib.load(source)
    print(json.dumps(encode(value), sort_keys=True, ensure_ascii=False, allow_nan=False))
except Exception as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
"""

proc runTool*(executable: string; args: openArray[string]; cwd = "";
              env: StringTableRef = nil): string =
  ## No shell interpretation. Preserve subprocess failure and its diagnostics.
  ## `env`, when given, replaces the inherited environment entirely.
  let process = startProcess(executable, workingDir = cwd, args = args,
    env = env, options = {poStdErrToStdOut})
  try:
    result = process.outputStream.readAll()
    let status = process.waitForExit()
    if status != 0: fail(executable & " exited " & $status & ":\n" & result)
  finally: process.close()

proc pythonPath*(): string =
  result = getEnv("ISONIM_BLOG_PYTHON")
  if result.len == 0: result = findExe("python3")
  if result.len == 0 or not fileExists(result): fail("Python 3.11+ is required for TOML; enter nix develop")

proc runPython*(args: openArray[string]): string =
  ## Python runs with a fixed, minimal environment: no user site directory,
  ## no unsafe sys.path entry, no inherited PYTHON* settings, and a fixed hash
  ## seed so CPython draws no startup entropy (its output never depended on
  ## it: the decoder sorts every table). The pinned time zone database path is
  ## the one setting passed through.
  let env = newStringTable(modeCaseSensitive)
  env["PYTHONHASHSEED"] = "0"
  if existsEnv("PYTHONTZPATH"): env["PYTHONTZPATH"] = getEnv("PYTHONTZPATH")
  runTool(pythonPath(), @["-s", "-P"] & @args, env = env)

proc readToml*(path: string): JsonNode =
  ## Full TOML parsing is owned by the pinned standard-library tomllib.
  try: result = parseJson(runPython(["-c", tomlDecoder, path]))
  except CatchableError as cause: fail(path & ": " & cause.msg)

proc inputFiles*(dir: string): seq[string] =
  ## Sorted regular files only; callers choose each allowlisted root. A
  ## directory that exists but cannot be listed is an error: skipping it
  ## would silently drop content from the site.
  if symlinkExists(dir): fail("input symlinks are not supported: " & dir)
  if not dirExists(dir): return
  # A nested proc cannot capture result safely with ARC on every compiler.
  var pending = @[dir]
  while pending.len > 0:
    let path = pending.pop()
    var children: seq[tuple[kind: PathComponent, path: string]]
    try:
      for kind, child in walkDir(path, checkDir = true): children.add (kind, child)
    except OSError as cause: fail("cannot read input directory " & path & ": " & cause.msg)
    for (kind, child) in children:
      case kind
      of pcFile: result.add child
      of pcDir: pending.add child
      else: fail("input symlinks are not supported: " & child)
  result.sort()

proc readSiteConfig*(root: string): SiteConfig =
  let path = root / "site.toml"
  if symlinkExists(path): fail("input symlinks are not supported: " & path)
  if not fileExists(path): fail("missing site.toml in " & root)
  var decoded = readToml(path)
  # A root table with a literal "$toml" key arrives tagged; unwrap it so the
  # configuration keeps every key, including that one, as an ordinary key.
  if decoded.kind == JObject and decoded.getOrDefault("$toml") == %"table" and
      decoded.len == 2 and decoded.hasKey("value"):
    decoded = decoded["value"]
  parseConfig(decoded)

proc siteInputFiles*(root: string; config: SiteConfig; options: BuildOptions): seq[string] =
  ## Every file a build may read from the site: site.toml and the declared
  ## directories. Nothing else in the repository can influence the output.
  result.add root / "site.toml"
  var dirs = @["posts", "pages", "data", "assets", "static", "layouts", "includes"]
  if options.drafts: dirs.add "drafts"
  for name in config.collections.keys: dirs.add "collections" / name
  for dir in dirs: result.add inputFiles(root / dir)
  result.sort()

proc themeTreeHash*(theme: string): string =
  ## Identity of a path-named theme: its layouts, includes and assets.
  var files: seq[tuple[path, content: string]]
  for dir in ["layouts", "includes", "assets"]:
    for file in inputFiles(theme / dir):
      files.add (relativePath(file, theme).replace('\\', '/'), readFile(file))
  treeHashOf(files)

proc buildEpoch*(root: string; sources: openArray[string]): int64 =
  ## SOURCE_DATE_EPOCH wins in sandboxes. Local previews use the latest input
  ## mtime, never the invocation clock, so repeating a build changes no bytes.
  result = sourceDateEpochFromEnv()
  if result >= 0: return
  result = getLastModificationTime(root / "site.toml").toUnix
  for source in sources: result = max(result, getLastModificationTime(source).toUnix)

proc civilDate*(epoch: int64; zone: string): string =
  ## IANA timezone rules come from Python's pinned tzdata closure.
  let code = "import datetime,sys,zoneinfo; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), zoneinfo.ZoneInfo(sys.argv[2])).date().isoformat())"
  runPython(["-c", code, $epoch, zone]).strip()

proc loadSite*(root: string; options = BuildOptions()): Site =
  result.config = readSiteConfig(root)
  if options.url.len > 0:
    var overrideConfig = %*{"title": result.config.title, "url": options.url}
    result.config.url = parseConfig(overrideConfig).url
  result.extra = result.config.extra
  result.data = newJObject()
  result.assets = initOrderedTable[string, string]()
  result.collections = initOrderedTable[string, seq[Page]]()
  # Every declared collection is present, in name order, even when empty.
  for name in result.config.collections.keys: result.collections[name] = @[]
  var sources: seq[string]
  for dir in ["posts", "pages", "data", "assets", "static"]:
    sources.add inputFiles(root / dir)
  if options.drafts: sources.add inputFiles(root / "drafts")
  for name in result.config.collections.keys:
    sources.add inputFiles(root / "collections" / name)
  result.sourceDateEpoch = buildEpoch(root, sources)
  let today = civilDate(result.sourceDateEpoch, result.config.timezone)
  result.buildDate = today
  var pages: seq[Page]
  for path in sources:
    let rel = relativePath(path, root).replace('\\', '/')
    if rel.startsWith("data/"):
      if path.splitFile.ext notin [".toml", ".json"]: continue
      let key = rel[5..^1].changeFileExt("")
      if result.data.hasKey(key): fail("duplicate data name: " & key)
      result.data[key] = if path.endsWith(".toml"): readToml(path) else: parseJson(readFile(path))
      continue
    if not path.endsWith(".md"): continue
    var collection, pattern: string
    let directory = rel.split('/')[0]
    var draft = false
    var output = true
    case directory
    of "posts", "drafts":
      let parts = rel.split('/')
      if parts.len > 2 and (parts.len != 3 or parts[^1] != "index.md"):
        fail(rel & ": posts must be dated files or bundles with index.md")
      collection = "posts"
      pattern = result.config.permalink
      draft = directory == "drafts"
    of "pages":
      pattern = "/" & rel[6..^1].changeFileExt("") & "/"
      if pattern.endsWith("/index/"): pattern = pattern[0..^7]
    of "collections":
      collection = rel.split('/')[1]
      pattern = result.config.collections[collection].permalink
      output = result.config.collections[collection].output
    else: continue
    try:
      var page = pageFromSource(rel, readFile(path), collection, pattern, draft)
      page.output = output
      if page.draft and not options.drafts: continue
      if page.date.len > 0 and page.date > today:
        if not options.future: continue
        page.future = true
      page.url = cleanRoute(result.config.basePath & page.url)
      if page.description.len == 0 or page.description.len > 160:
        result.warnings.add rel & ": description is missing or exceeds 160 characters"
      pages.add page
    except CatchableError as cause: fail(rel & ": " & cause.msg)
  pages.sortPages()
  for page in pages:
    if result.data.hasKey("tags"):
      for tag in page.tags:
        if not result.data["tags"].hasKey(tag): fail(page.source & ": undeclared tag " & tag)
    if page.collection == "posts": result.posts.add page
    elif page.collection.len > 0: result.collections.mgetOrPut(page.collection, @[]).add page
    result.pages.add page
  linkNavigation(result)
  # Generated listing pages share the URL space: a collision with a content
  # page or between two terms is an error naming both sources.
  checkCollisions(pages & generatedPages(result))
