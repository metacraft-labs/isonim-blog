## The `isonim-blog build` command end to end: the real command dispatcher,
## the real Nim compiler, the real filesystem and the generic fixture site.
## No test doubles. Each compile is a genuine `nim c` of the site program, so
## "Compiled" and "Reused" below are observations of real compiler runs.
import std/[unittest, json, sequtils]
import isonim_blog
import isonim/static/buildinfo
import ./site_helpers

proc build(args: varargs[string]): CliResult =
  runCli(@["build"] & @args)

proc themedFixture(): string =
  ## The generic fixture plus a path-named theme with a layout the site lacks,
  ## an asset the site overrides and an asset only the theme provides.
  result = fixtureCopy()
  let theme = result / "themes/plain"
  createDir(theme / "layouts")
  createDir(theme / "assets")
  writeFile(theme / "layouts/note.nim", """import isonim_blog/model
import isonim/dsl/ui
import isonim/ssr/escape
const parent = "base"
proc layout*(page: Page; site: Site; content: string): string =
  ui:
    article(class = "theme-note"):
      h1: text page.title
      raw content
""")
  writeFile(theme / "theme.toml", "name = \"plain\"\n")
  writeFile(theme / "assets/site.css", "/* theme default, overridden by the site */\n")
  writeFile(theme / "assets/theme.css", ".theme-note { margin: 0; }\n")
  writeFile(result / "site.toml", "theme = \"themes/plain\"\n" & readFile(result / "site.toml"))
  writeFile(result / "pages/themed.md", "---\ntitle: Themed\ndescription: Uses the theme layout\nlayout: note\n---\nThemed body.\n")

suite "build command":
  test "one compile per layout hash; content edits reuse it; failures leave no stale cache":
    let root = themedFixture()
    let previous = getCurrentDir()
    setCurrentDir(root)
    defer:
      setCurrentDir(previous)
      removeDir(root)
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")

    let first = build()
    check first.exitCode == 0
    check first.error == ""
    check first.output.startsWith("Compiled the site program\n")
    let public = root / "public"
    check readFile(public / "themed/index.html").contains("class=\"theme-note\"")
    check readFile(public / "posts/first/index.html").contains("<header>")
    # Theme assets overlay the site's: the site wins for a shared path.
    let manifest = parseFile(public / "asset-manifest.json")
    check readFile(public / manifest["assets/site.css"].getStr) == readFile(root / "assets/site.css")
    check readFile(public / manifest["assets/theme.css"].getStr) == ".theme-note { margin: 0; }\n"
    let info = parseFile(public / "build.json")
    check info["generator"].getStr == "isonim-blog " & isonimBlogVersion
    check info["sourceRevision"].getStr.startsWith("sha256-")
    let components = info["components"]
    check components.len == 2
    check components[1]["name"].getStr == "theme"
    check components[1]["revision"].getStr == themeTreeHash(root / "themes/plain")
    check info["outputHash"].getStr == treeHash(public)
    let firstTree = treeHash(public, [])

    let second = build()
    check second.exitCode == 0
    check second.output.startsWith("Reused the compiled site program")
    # Rebuilding unchanged inputs reproduces every output byte.
    check treeHash(public, []) == firstTree

    # Content is data: an edit is exported by the same program.
    let program = root / "build/isonim-blog/bin/site-program"
    let programHash = sha256Hex(readFile(program))
    writeFile(root / "posts/2020-01-01-first.md",
      readFile(root / "posts/2020-01-01-first.md") & "\nEdited content.\n")
    let third = build()
    check third.output.startsWith("Reused the compiled site program")
    check readFile(public / "posts/first/index.html").contains("Edited content.")
    check sha256Hex(readFile(program)) == programHash
    check parseFile(public / "build.json")["sourceRevision"] != info["sourceRevision"]

    # Code is not: a site layout, an include and a theme layout each recompile.
    for path in ["layouts/post.nim", "includes/header.nim", "themes/plain/layouts/note.nim"]:
      writeFile(root / path, readFile(root / path) & "\n# edited\n")
      let rebuilt = build()
      check rebuilt.exitCode == 0
      check rebuilt.output.startsWith("Compiled the site program\n")

    # A failed compile reports the compiler error, keeps the published output
    # complete and removes the cache key, so the next good build compiles.
    let published = treeHash(public, [])
    let layout = readFile(root / "layouts/page.nim")
    writeFile(root / "layouts/page.nim", "this is not Nim\n")
    let broken = build()
    check broken.exitCode == 1
    check broken.output == ""
    check broken.error.contains("page.nim")
    check treeHash(public, []) == published
    check not fileExists(program & ".key")
    writeFile(root / "layouts/page.nim", layout)
    check build().output.startsWith("Compiled the site program\n")

    # Flags reach the content run without recompiling.
    let preview = build("--drafts", "--future", "--out", "preview", "--url", "https://preview.example")
    check preview.exitCode == 0
    check preview.output.startsWith("Reused the compiled site program")
    let draft = readFile(root / "preview/posts/work-in-progress/index.html")
    check draft.contains("name=\"robots\" content=\"noindex\"")
    check draft.contains("https://preview.example/posts/work-in-progress/")
    check fileExists(root / "preview/posts/future/index.html")
    check not dirExists(public / "posts/work-in-progress")

    # The output may not overlap the inputs, and unknown flags are refused.
    let overlap = build("--out", "posts/out")
    check overlap.exitCode == 1
    check overlap.error.contains("overlaps input directory posts")
    check build("--theme", "x").exitCode == 1

  test "the compile key covers dependency sources, the compiler and the command":
    let root = fixtureCopy()
    defer: removeDir(root)
    let program = root / "build/program"
    let source = prepareProgram(root, program)
    prepareCompileConfig(program)
    let compiler = nimCompiler()
    let command = @["c", "--out:a"]
    let base = compileIdentity(program, source, command, compiler)
    check compileIdentity(program, source, command, compiler) == base
    check compileIdentity(program, source, @["c", "--out:b"], compiler) != base
    # A copy of one selected dependency tree with one extra file changes the key.
    let dependency = getEnv("ISONIM_BLOG_NIM_EVERYWHERE_SRC")
    let copy = createTempDir("isonim-blog-dependency-", "")
    defer:
      putEnv("ISONIM_BLOG_NIM_EVERYWHERE_SRC", dependency)
      removeDir(copy)
    copyDir(dependency / "src", copy / "src")
    putEnv("ISONIM_BLOG_NIM_EVERYWHERE_SRC", copy)
    check compileIdentity(program, source, command, compiler) == base
    writeFile(copy / "src/extra.nim", "discard\n")
    check compileIdentity(program, source, command, compiler) != base
    putEnv("ISONIM_BLOG_NIM_EVERYWHERE_SRC", dependency)
    # Content never enters the key.
    writeFile(root / "posts/2020-01-01-first.md", "---\ntitle: Changed\n---\nChanged")
    check compileIdentity(program, source, command, compiler) == base

  test "islands mode compiles one hashed bundle, cached like the program":
    let root = createTempDir("isonim-blog-islands-", "")
    copyDir(repoRoot / "tests/fixtures/islands-site", root)
    let previous = getCurrentDir()
    setCurrentDir(root)
    defer:
      setCurrentDir(previous)
      removeDir(root)
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let first = build()
    check first.exitCode == 0
    check first.error == ""
    let bundle = root / "build/isonim-blog/bin/islands.js"
    check fileExists(bundle & ".key")
    let published = inputFiles(root / "public").filterIt(it.endsWith(".js"))
    check published.len == 1
    check readFile(published[0]) == readFile(bundle)
    let name = "/" & relativePath(published[0], root / "public")
    check readFile(root / "public/index.html").contains("<script src=\"" & name & "\" defer>")
    check readFile(root / "public/_headers").contains("script-src " & name)
    let key = readFile(bundle & ".key")
    let second = build()
    check second.output.startsWith("Reused the compiled site program")
    check readFile(bundle & ".key") == key
    check inputFiles(root / "public").filterIt(it.endsWith(".js")) == published

  test "--incremental rewrites only changed files and removes what the build no longer writes":
    let root = fixtureCopy()
    let previous = getCurrentDir()
    setCurrentDir(root)
    defer:
      setCurrentDir(previous)
      removeDir(root)
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    check build().exitCode == 0
    let public = root / "public"
    let full = treeHash(public, [])
    let aboutTime = getLastModificationTime(public / "about/index.html")
    # Leftovers of an earlier build, of every kind, in the output.
    writeFile(public / "stale.html", "old")
    createDir(public / "gone/deeper")
    writeFile(public / "gone/deeper/page.html", "old")
    removeFile(public / "robots.txt")
    createDir(public / "robots.txt")           # a directory where a file belongs
    writeFile(public / "robots.txt/x", "old")
    createSymlink(root / "site.toml", public / "linked.txt")
    let unchanged = build("--incremental")
    check unchanged.exitCode == 0
    check unchanged.output.contains("Updated 8 changed files\n")
    for path in ["gone/", "gone/deeper/", "gone/deeper/page.html", "linked.txt", "robots.txt",
        "robots.txt/", "robots.txt/x", "stale.html"]:
      check unchanged.output.contains("\n  " & path & "\n")
    check treeHash(public, []) == full
    check not symlinkExists(public / "linked.txt")
    check readFile(root / "site.toml").len > 0  # the link was removed, not followed
    check getLastModificationTime(public / "about/index.html") == aboutTime
    # A content edit rewrites what it reaches and nothing else.
    writeFile(root / "posts/2020-01-01-first.md",
      readFile(root / "posts/2020-01-01-first.md") & "\nIncremental.\n")
    let edited = build("--incremental")
    check edited.exitCode == 0
    check edited.output.contains("\n  posts/first/index.html\n")
    check edited.output.contains("\n  feed.xml\n")
    check not edited.output.contains("about/index.html")
    check getLastModificationTime(public / "about/index.html") == aboutTime
    # The result equals a complete build.
    check build("--out", "full").exitCode == 0
    check treeHash(public, []) == treeHash(root / "full", [])

suite "build clock and origin":
  test "a dev shell's SOURCE_DATE_EPOCH hides nothing; --now sets the clock; the summary names it":
    let root = fixtureCopy()
    let previous = getCurrentDir()
    setCurrentDir(root)
    defer:
      setCurrentDir(previous)
      removeDir(root)
    # The value nixpkgs' stdenv exports into every `nix develop` shell.
    putEnv("SOURCE_DATE_EPOCH", "315532800")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let shell = build()
    check shell.exitCode == 0
    check shell.error == ""
    for slug in ["first", "second", "bundle", "third", "another"]:
      check fileExists(root / "public/posts" / slug / "index.html")
    check not dirExists(root / "public/posts/future")
    # SOURCE_DATE_EPOCH still stamps the output.
    check parseFile(root / "public/build.json")["sourceDateEpoch"].getInt == 315532800
    check shell.output.contains("Future-dated posts are judged against ")
    check shell.output.contains("(the wall clock")
    # An explicit clock: the RFC 3339 form and the epoch form.
    let early = build("--now", "2020-02-01T12:00:00Z", "--out", "early")
    check early.exitCode == 0
    check early.output.contains("Future-dated posts are judged against 2020-02-01T12:00:00Z (--now)")
    check fileExists(root / "early/posts/first/index.html")
    check not dirExists(root / "early/posts/second")
    let late = build("--now", "@4070995200", "--out", "late")  # 2099-01-02T00:00:00Z
    check late.exitCode == 0
    check fileExists(root / "late/posts/future/index.html")
    # An explicit clock repeats byte for byte.
    check build("--now", "@4070995200", "--out", "late-again").exitCode == 0
    check treeHash(root / "late", []) == treeHash(root / "late-again", [])
    let bad = build("--now", "next week")
    check bad.exitCode == 1
    check bad.error.contains("--now")
    # A compact date is not an epoch: it is refused, naming the `@` form.
    let compact = build("--now", "20261028")
    check compact.exitCode == 1
    check compact.error.contains("write '@20261028'")
    check build("--now", "@253402214400").error.contains("must lie between")
    check build("--now").exitCode == 1

  test "a reserved example origin is a warning, not an error; a real one is not":
    let root = fixtureCopy()
    let previous = getCurrentDir()
    setCurrentDir(root)
    defer:
      setCurrentDir(previous)
      removeDir(root)
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    # The fixture's site.toml carries the placeholder `new site` writes.
    check readFile(root / "site.toml").contains("url = \"https://example.org\"\n")
    let placeholder = build()
    check placeholder.exitCode == 0
    check placeholder.output.contains("warning: url https://example.org is a placeholder")
    check fileExists(root / "public/index.html")
    let real = build("--url", "https://notes.test", "--out", "real")
    check real.exitCode == 0
    check not real.output.contains("is a placeholder")
    check readFile(root / "real/posts/first/index.html").contains("https://notes.test/posts/first/")
