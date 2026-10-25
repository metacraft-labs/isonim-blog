## Generate a site's layout registry and compile it. Preparation reads code
## only (layouts/ and includes/ of the site and its theme); content is loaded
## by runtime.nim when the compiled program runs.
import std/[os, strutils, tables, algorithm, json]
import ./[model, inputs]
import isonim/static/buildinfo
import isonim/ssr/markers

proc writeChanged*(path, content: string) =
  ## Stable preparation avoids touching identical compiler inputs.
  if fileExists(path) and readFile(path) == content: return
  createDir(parentDir(path))
  writeFile(path, content)

const ogTemplateName* = "og.svg.nim"
  ## A theme's or site's OpenGraph template, at its root.

proc prepareProgram*(root, directory: string; theme = ""): string =
  ## Copy the theme/site code overlay into an owned compilation directory.
  ## A wrapper exposes an optional private parent constant without parsing Nim.
  var sources = initTable[string, string]()
  for base in [theme, root]:
    if base.len == 0: continue
    for dir in ["layouts", "includes"]:
      for source in inputFiles(base / dir):
        if source.endsWith(".nim"):
          let rel = relativePath(source, base).replace('\\', '/')
          sources[rel] = readFile(source)
  var keys: seq[string]
  for key in sources.keys: keys.add key
  keys.sort()
  var layoutNames: seq[string]
  for key in keys:
    writeChanged(directory / key, sources[key])
    if key.startsWith("layouts/"):
      let name = key[8..^5]
      validateName(name)
      layoutNames.add name
  # A theme's or site's OpenGraph template (the site's wins), compiled
  # into the program as og_template.nim (`og.svg.nim` is not a module name).
  var ogTemplate = ""
  var hasOgTemplate = false
  for base in [theme, root]:
    if base.len == 0: continue
    let path = base / ogTemplateName
    if symlinkExists(path): fail("input symlinks are not supported: " & path)
    if fileExists(path):
      ogTemplate = readFile(path)
      hasOgTemplate = true
  if hasOgTemplate: writeChanged(directory / "og_template.nim", ogTemplate)
  elif fileExists(directory / "og_template.nim"): removeFile(directory / "og_template.nim")
  # Deleted code must not survive in the prepared tree or satisfy an import.
  for dir in ["layouts", "includes"]:
    for old in inputFiles(directory / dir):
      if relativePath(old, directory).replace('\\', '/') notin sources: removeFile(old)
  var program = "import isonim_blog/runtime\n"
  for i, name in layoutNames:
    let wrapper = "include " & $(%("layouts/" & name & ".nim")) & "\n" &
      "proc blogParent*(): string =\n  when declared(parent): parent\n  else: \"\"\n" &
      "proc blogIslands*(): seq[Island] =\n  when declared(islands): @islands\n  else: @[]\n"
    writeChanged(directory / ("layout_" & $i & ".nim"), "import isonim_blog/model\n" & wrapper)
    program.add "import layout_" & $i & " as layout" & $i & "\n"
  program.add "let layouts = @["
  if layoutNames.len == 0:
    program = "import isonim_blog/runtime\nlet layouts: seq[LayoutEntry] = @["
  for i, name in layoutNames:
    if i > 0: program.add ","
    let prefix = "layout" & $i
    program.add "\n  LayoutEntry(name: " & $(%name) & ", parent: " & prefix & ".blogParent(), render: " & prefix & ".layout, islands: " & prefix & ".blogIslands())"
  program.add "]\n"
  # Directive renderers (`includes/directives.nim` of the site or its theme)
  # reach the Markdown parser of every page.
  let directives =
    if "includes/directives.nim" in sources:
      program.add "import includes/directives as blogdirectives\n" &
        "proc blogDirectives(): seq[DirectiveRegistration] =\n" &
        "  when declared(blogdirectives.directives): blogdirectives.directives()\n" &
        "  else: {.error: \"includes/directives.nim must export proc directives*(): seq[DirectiveRegistration]\".}\n"
      "blogDirectives()"
    else: "@[]"
  if hasOgTemplate:
    program.add "import og_template as ogtemplate\nwhen isMainModule: siteMain(layouts, ogtemplate.ogImage, " & directives & ")\n"
  else: program.add "when isMainModule: siteMain(layouts, directives = " & directives & ")\n"
  result = directory / "site_program.nim"
  writeChanged(result, program)

proc sourcePaths*(): seq[string] =
  ## Explicit selected sources are supplied by config.nims or the package.
  for name in ["ISONIM_BLOG_SRC", "ISONIM_BLOG_ISONIM_SRC", "ISONIM_BLOG_NIM_EVERYWHERE_SRC"]:
    let path = getEnv(name)
    if path.len == 0 or not dirExists(path / "src"):
      fail("missing compiler input " & name & "; enter nix develop or use the packaged CLI")
    result.add path / "src"

proc prepareCompileConfig*(directory: string) =
  var config = "# Generated compiler inputs; no content paths.\n"
  for path in sourcePaths(): config.add "--path:" & $(%path) & "\n"
  writeChanged(directory / "nim.cfg", config)

const bundleSourceName* = "islands.nim"

proc generateBundle*(directory: string; islands: JsonNode): string =
  ## Bundle code delegates hydration to each declared IsoNim island module.
  ## Island modules receive IsoNim's own DOM binding (isonim/web/dom_api),
  ## the type that `hydration.hydrate` accepts, so no conversion is needed.
  var source = "import isonim/web/dom_api\n" &
    "proc blogIslandTargets(selector: cstring): seq[Element] {.importjs: " &
    "\"Array.from(document.querySelectorAll(#))\".}\n"
  let bootstrap = generateHydrationScript()
  source.add "{.emit: " & $(%bootstrap[8..<bootstrap.find("</script>")]) & ".}\n"
  for i in 0..<islands.len:
    let island = islands[i]
    let module = island["module"].getStr.changeFileExt("")
    if not fileExists(directory / (module & ".nim")): fail("missing island module: " & module)
    source.add "import " & $(%module) & " as island" & $i & "\n"
  for i in 0..<islands.len:
    let island = islands[i]
    source.add "for element in blogIslandTargets(cstring(" & $(%island["selector"].getStr) & ")):\n  island" & $i & ".mount(element)\n"
  result = directory / bundleSourceName
  writeChanged(result, source)

type
  CompiledProgram* = object
    ## A compiled artifact and whether this invocation had to compile it.
    path*: string
    reused*: bool

proc nimCompiler*(): string =
  result = findExe("nim")
  if result.len == 0: fail("the Nim compiler is required; enter nix develop or use the packaged CLI")

proc compileIdentity*(directory, source: string; command: openArray[string];
                      compiler: string): string =
  ## The cache key of one compile: every byte of the prepared program, every
  ## file of each selected source tree, the compiler's version report and the
  ## exact command. Content is not part of it, so content edits reuse the
  ## program; any layout, include, dependency or toolchain change does not.
  var files: seq[tuple[path, content: string]]
  for file in inputFiles(directory / "layouts") & inputFiles(directory / "includes"):
    files.add ("program/" & relativePath(file, directory).replace('\\', '/'), readFile(file))
  for kind, file in walkDir(directory):
    # The islands bundle source is generated from the native program's
    # output, so it belongs to the JS compile's key only.
    if kind == pcFile and file.splitFile.ext in [".nim", ".cfg"] and
        (extractFilename(file) != bundleSourceName or extractFilename(source) == bundleSourceName):
      files.add ("program/" & extractFilename(file), readFile(file))
  for i, tree in sourcePaths():
    for file in walkDirRec(tree, relative = true):
      files.add ("source-" & $i & "/" & file.replace('\\', '/'), readFile(tree / file))
  files.add ("compiler", compiler & "\n" & runTool(compiler, ["--version"]))
  files.add ("command", @command.join("\0") & "\0" & source)
  treeHashOf(files)

proc compileCached*(directory, source, output, nimcache, backend: string): CompiledProgram =
  ## Compile `source` unless a previous compile of identical inputs produced
  ## `output`. The key file is written only after a successful compile, so an
  ## interrupted or failed compile can never be mistaken for a cached one.
  let compiler = nimCompiler()
  # Configuration files above the program (a site's or repository's own
  # config.nims) and the user's are not inputs of the key, so they are not
  # read; the generated nim.cfg beside the program supplies the search paths.
  let command = @[backend, "--hints:off", "-d:release", "--skipParentCfg:on",
    "--skipUserCfg:on", "--nimcache:" & nimcache, "--out:" & output]
  let identity = compileIdentity(directory, source, command, compiler)
  let keyFile = output & ".key"
  result.path = output
  if fileExists(output) and fileExists(keyFile) and readFile(keyFile) == identity:
    result.reused = true
    return
  if fileExists(keyFile): removeFile(keyFile)
  createDir(parentDir(output))
  discard runTool(compiler, command & @[source])
  writeFile(keyFile, identity)

proc buildSite*(root: string; options = BuildOptions()): string =
  ## CLI orchestration: prepare the layout program (code only), compile it
  ## once per source hash, then run it over the content. A content-only edit
  ## therefore runs the existing program without invoking the compiler.
  let root = absolutePath(root)
  let directory = root / "build" / "isonim-blog"
  let theme = resolveTheme(root, options.theme)
  let source = prepareProgram(root, directory / "program", theme)
  prepareCompileConfig(directory / "program")
  let program = compileCached(directory / "program", source,
    directory / "bin" / "site-program", directory / "nimcache" / "native", "c")
  result = (if program.reused: "Reused the compiled site program (layouts unchanged)\n"
    else: "Compiled the site program\n")
  var bundle = ""
  if readSiteConfig(root, theme).scriptPolicy == spDeclared:
    let islands = parseJson(runTool(program.path, ["--islands"]))
    if islands.len > 0:
      let client = compileCached(directory / "program",
        generateBundle(directory / "program", islands),
        directory / "bin" / "islands.js", directory / "nimcache" / "js", "js")
      bundle = client.path
  let output = if options.outDir.len > 0: absolutePath(options.outDir, root) else: root / "public"
  var args = @[output, "--root", root]
  if theme.len > 0: args.add @["--theme", theme]
  if options.drafts: args.add "--drafts"
  if options.future: args.add "--future"
  if options.incremental: args.add "--incremental"
  if options.url.len > 0: args.add @["--url", options.url]
  if bundle.len > 0: args.add @["--bundle", bundle]
  # Image variants are reused across builds of this site.
  args.add @["--image-cache", directory / "images"]
  result.add runTool(program.path, args)
