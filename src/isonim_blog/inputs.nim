## Native input boundary. Only named input directories are traversed. Symlinks
## are refused instead of following paths outside a site's declared inputs.
import std/[os, osproc, streams, strutils, algorithm, json, times, tables, strtabs]
import ./[model, archives, theme_format]
export theme_format
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

proc readSiteToml*(root: string): JsonNode =
  ## The decoded `site.toml` of the site at `root`, before theme defaults.
  let path = root / "site.toml"
  if symlinkExists(path): fail("input symlinks are not supported: " & path)
  if not fileExists(path): fail("missing site.toml in " & root)
  result = readToml(path)
  # A root table with a literal "$toml" key arrives tagged; unwrap it so the
  # configuration keeps every key, including that one, as an ordinary key.
  if result.kind == JObject and result.getOrDefault("$toml") == %"table" and
      result.len == 2 and result.hasKey("value"):
    result = result["value"]
  if result.kind != JObject: fail("site.toml must be a table")

# -- Themes -------------------------------------------------------------------
#
# A theme is named in site.toml by path (`themes/plain`, relative to the
# site, or absolute) or by package name (`isonim-blog-theme-minimal`). A
# package is looked up in the directories of ISONIM_BLOG_THEME_PATH (a
# site's flake or a Nimble install provides them), then among the themes
# this framework ships (`themes/` of ISONIM_BLOG_SRC, which the dev shell,
# the packaged CLI and the Nix builder set).

const shippedThemePrefix* = "isonim-blog-theme-"

proc isThemePath*(value: string): bool =
  ## Whether a `theme` value names a directory rather than a package.
  value.contains('/') or value.contains('\\') or value.startsWith(".") or value.isAbsolute

proc themeSearchDirs*(): seq[string] =
  ## Where package-named themes are looked up, in order.
  for dir in getEnv("ISONIM_BLOG_THEME_PATH").split(PathSep):
    if dir.len > 0: result.add dir
  let framework = getEnv("ISONIM_BLOG_SRC")
  if framework.len > 0: result.add framework / "themes"

proc readThemeManifest*(theme: string): ThemeManifest =
  ## The validated `theme.toml` of the theme at `theme`, with the files it
  ## names checked: token documents and stylesheets must be regular files
  ## of the theme, and the generated token stylesheet's path is reserved.
  let path = theme / themeManifestName
  if symlinkExists(path): fail("input symlinks are not supported: " & path)
  if not fileExists(path): fail("a theme needs a " & themeManifestName & ": " & path & " does not exist")
  try: result = parseThemeManifest(readToml(path))
  except BlogError as cause: fail(path & ": " & cause.msg.replace("theme.toml: ", ""))
  for rel in result.tokenFiles & result.stylesheets:
    if symlinkExists(theme / rel): fail("input symlinks are not supported: " & theme / rel)
    if not fileExists(theme / rel): fail(path & ": names " & rel & ", which the theme does not have")
  if fileExists(theme / tokenStylesheetPath) or symlinkExists(theme / tokenStylesheetPath):
    fail(theme / tokenStylesheetPath & ": this path is generated from the theme's tokens; a theme cannot ship it")

proc findThemePackage*(name: string): string =
  ## The directory of the theme package `name`: a search directory that is
  ## itself the theme, or holds it as `<name>/` or (for this framework's
  ## naming) `<name without isonim-blog-theme->/`. The first match wins; a
  ## candidate whose theme.toml names another package is an error.
  if not validThemeName(name): fail("invalid theme package name: " & name)
  var candidates: seq[tuple[path: string, named: bool]]
  for dir in themeSearchDirs():
    candidates.add (dir, false)
    candidates.add (dir / name, true)
    if name.startsWith(shippedThemePrefix) and name.len > shippedThemePrefix.len:
      candidates.add (dir / name[shippedThemePrefix.len .. ^1], true)
  for (candidate, named) in candidates:
    if not fileExists(candidate / themeManifestName): continue
    let found = readThemeManifest(candidate).name
    if found == name: return absolutePath(candidate)
    # A directory named after the package that is another package is a
    # mistake worth naming; a search directory that is some other theme
    # is simply not this one.
    if named: fail(candidate & ": its theme.toml names " & found & ", not " & name)
  fail("theme package " & name & " not found in " &
    (if candidates.len == 0: "(no search directories)" else: themeSearchDirs().join(", ")) &
    ". Name a theme directory by path in site.toml, or add the package's directory " &
    "to ISONIM_BLOG_THEME_PATH (a site flake input, or `nimble path <package>`)")

proc resolveTheme*(root: string; explicit = ""): string =
  ## The absolute directory of the site's theme, or "" without one.
  ## `explicit` (the Nix builder's `theme` argument) replaces the lookup of
  ## site.toml's value; a package-named site then still checks that the
  ## given theme is that package.
  let configured = readSiteToml(root).stringValue("theme")
  if explicit.len > 0:
    result = absolutePath(explicit)
    if not dirExists(result): fail("theme path does not exist: " & explicit)
    if configured.len > 0 and not isThemePath(configured):
      let found = readThemeManifest(result).name
      if found != configured:
        fail("site.toml names theme " & configured & ", but the theme given is " & found)
    return
  if configured.len == 0: return ""
  if isThemePath(configured):
    result = if configured.isAbsolute: configured else: root / configured
    if not dirExists(result): fail("theme path does not exist: " & configured)
    result = absolutePath(result)
  else:
    result = findThemePackage(configured)

proc readSiteConfig*(root: string; theme = ""): SiteConfig =
  ## The site's configuration: `site.toml` over its theme's defaults, with
  ## the keys the theme requires checked. `theme` is a resolved theme
  ## directory, or "" to resolve the one site.toml names.
  let raw = readSiteToml(root)
  let directory = if theme.len > 0: theme else: resolveTheme(root)
  if directory.len == 0: return parseConfig(raw)
  let manifest = readThemeManifest(directory)
  let merged = mergeDefaults(raw, manifest.config)
  requireKeys(merged, manifest)
  parseConfig(merged)

proc themeTokenDocuments*(theme: string; manifest: ThemeManifest): seq[string] =
  for rel in manifest.tokenFiles: result.add readFile(theme / rel)

proc loadThemeInfo*(theme: string): (ThemeManifest, ThemeInfo) =
  ## The manifest and the layout-facing record of the theme at `theme`.
  let manifest = readThemeManifest(theme)
  var info = ThemeInfo(name: manifest.name, version: manifest.version)
  try: info.tokens = themeTokens(themeTokenDocuments(theme, manifest))
  except BlogError as cause: fail(theme / themeManifestName & ": " & cause.msg)
  (manifest, info)

proc themeFiles*(theme: string): seq[string] =
  ## Every file of a theme a build may read, sorted: theme.toml, the token
  ## documents it names, og.svg.nim, and layouts/, includes/ and assets/.
  let manifest = readThemeManifest(theme)
  result.add theme / themeManifestName
  for rel in manifest.tokenFiles: result.add theme / rel
  if symlinkExists(theme / "og.svg.nim"): fail("input symlinks are not supported: " & theme / "og.svg.nim")
  if fileExists(theme / "og.svg.nim"): result.add theme / "og.svg.nim"
  for dir in themeFileDirs:
    for file in inputFiles(theme / dir):
      if file notin result: result.add file
  result.sort()

proc themeTreeHash*(theme: string): string =
  ## Identity of a theme directory: the content of every file it can
  ## contribute to a build (`themeFiles`), by relative path.
  var files: seq[tuple[path, content: string]]
  for file in themeFiles(theme):
    files.add (relativePath(file, theme).replace('\\', '/'), readFile(file))
  treeHashOf(files)

proc ejectThemeFile*(root, file: string): string =
  ## Copy one file of the site's theme into the site at the same path, where
  ## it now wins over the theme's (§7). Returns the site-relative path. Only
  ## files that resolve against the site's can be ejected (layouts/,
  ## includes/, assets/ and og.svg.nim); an existing site file is never
  ## overwritten. Deleting the copy restores the theme's file.
  let theme = resolveTheme(root)
  if theme.len == 0: fail("site.toml names no theme to eject from")
  var rel = file.replace('\\', '/')
  while rel.startsWith("./"): rel = rel[2..^1]
  let parts = rel.split('/')
  if rel.len == 0 or rel.isAbsolute or ".." in parts or "" in parts or "." in parts:
    fail("eject takes a path inside the theme, such as layouts/post.nim: " & file)
  if rel != "og.svg.nim" and (parts.len < 2 or parts[0] notin themeFileDirs):
    fail("only layouts/, includes/, assets/ and og.svg.nim resolve against the site; cannot eject " & rel)
  let source = theme / rel
  if symlinkExists(source): fail("input symlinks are not supported: " & source)
  if not fileExists(source):
    fail("the theme has no " & rel & (if dirExists(source): " file (it is a directory)" else: ""))
  let target = root / rel
  if fileExists(target) or symlinkExists(target) or dirExists(target):
    fail(rel & " already exists in the site, where it already overrides the theme's")
  createDir(parentDir(target))
  copyFile(source, target)
  rel

proc siteInputFiles*(root: string; config: SiteConfig; options: BuildOptions): seq[string] =
  ## Every file a build may read from the site: site.toml, the OpenGraph
  ## template og.svg.nim and the declared directories. Nothing else in the
  ## repository can influence the output.
  result.add root / "site.toml"
  if symlinkExists(root / "og.svg.nim"): fail("input symlinks are not supported: " & root / "og.svg.nim")
  if fileExists(root / "og.svg.nim"): result.add root / "og.svg.nim"
  var dirs = @["posts", "pages", "data", "assets", "static", "layouts", "includes"]
  if options.drafts: dirs.add "drafts"
  for name in config.collections.keys: dirs.add "collections" / name
  for dir in dirs: result.add inputFiles(root / dir)
  result.sort()

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
  ## The site's content and configuration (over its theme's defaults), with
  ## the theme's resolved tokens; asset and stylesheet URLs are filled in by
  ## the export, which fingerprints the files.
  let theme = resolveTheme(root, options.theme)
  result.config = readSiteConfig(root, theme)
  if theme.len > 0: result.theme = loadThemeInfo(theme)[1]
  else: result.theme.tokens = newJObject()
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
