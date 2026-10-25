## Resolution between a site and its theme (§7): a site file shadows the
## theme file of the same path (a layout, an include, an asset and the
## OpenGraph template), `isonim-blog theme eject <file>` copies the theme's
## file into the site, and removing the site's file restores the theme's.
##
## Everything is real: the shipped minimal theme found by its package name,
## the `build` and `theme eject` commands, the Nim compiler, resvg and the
## filesystem. "Restores" is checked as byte equality of the whole output
## tree with the build that never had the site file.
import std/[unittest, json, tables, algorithm]
import isonim_blog
import ./site_helpers

proc outputTree(dir: string): OrderedTable[string, string] =
  ## Every output file by relative path, except build.json, which records
  ## the hash of the site's own inputs (the shadowing files among them).
  var paths: seq[string]
  for path in walkDirRec(dir, relative = true): paths.add path.replace('\\', '/')
  paths.sort()
  for path in paths:
    if path != "build.json": result[path] = readFile(dir / path)

proc themedSite(): string =
  ## The generic example's content with no layouts of its own, using the
  ## shipped theme by package name, as `new site` writes it.
  result = createTempDir("isonim-blog-override-", "")
  for dir in ["posts", "pages", "collections", "data", "assets", "static"]:
    copyDir(repoRoot / "examples/basic" / dir, result / dir)
  writeFile(result / "site.toml", "theme = \"isonim-blog-theme-minimal\"\n" &
    readFile(repoRoot / "examples/basic/site.toml"))

proc cli(args: varargs[string]): CliResult = runCli(@args)

proc manifestAsset(public, path: string): string =
  readFile(public / parseFile(public / "asset-manifest.json")[path].getStr)

proc ogCard(public, page: string): string =
  ## The bytes of a page's OpenGraph card, found through its og:image URL.
  for tag in htmlElements(public / page, "meta"):
    if tag.getOrDefault("property") == "og:image":
      return readFile(public / tag["content"].replace("https://example.org/", ""))
  doAssert false, "no og:image on " & page

suite "site files shadow theme files":
  test "a site file wins; removing it restores the theme's; eject copies the theme's file":
    let root = themedSite()
    let theme = repoRoot / "themes/minimal"
    let previous = getCurrentDir()
    setCurrentDir(root)
    defer:
      setCurrentDir(previous)
      removeDir(root)
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let public = root / "public"

    # The theme alone.
    check cli("build").exitCode == 0
    let themeOnly = outputTree(public)
    let post = "posts/first/index.html"
    check readFile(public / post).contains("<article class=\"post\">")
    check readFile(public / post).contains("<footer class=\"site-footer\">")
    check manifestAsset(public, "assets/minimal.css") == readFile(theme / "assets/minimal.css")
    let themeCard = ogCard(public, post)

    # Shadow a layout, an include, an asset and the OpenGraph template.
    createDir(root / "layouts")
    createDir(root / "includes")
    writeFile(root / "layouts/post.nim", readFile(theme / "layouts/post.nim").replace(
      "article(class = \"post\")", "article(class = \"site-post\")"))
    writeFile(root / "includes/minimal.nim", readFile(theme / "includes/minimal.nim").replace(
      "footer(class = \"site-footer\")", "footer(class = \"site-footer site-owned\")"))
    writeFile(root / "assets/minimal.css", "/* the site's own stylesheet */\nbody { margin: 0; }\n")
    writeFile(root / "og.svg.nim", readFile(theme / "og.svg.nim").replace(
      "\"#111316\"", "\"#000000\"").replace("tokenColor(site, \"sys.color.surface\", \"#000000\")",
      "\"#204060\""))
    let shadowed = cli("build")
    check shadowed.exitCode == 0
    check shadowed.output.startsWith("Compiled the site program")
    let page = readFile(public / post)
    check page.contains("<article class=\"site-post\">")
    check not page.contains("<article class=\"post\">")
    # The theme's other layouts still import the site's include.
    check readFile(public / "about/index.html").contains("class=\"site-footer site-owned\"")
    check manifestAsset(public, "assets/minimal.css") == readFile(root / "assets/minimal.css")
    # The page links the site's stylesheet in the theme's place.
    check page.contains(parseFile(public / "asset-manifest.json")["assets/minimal.css"].getStr)
    check ogCard(public, post) != themeCard

    # Removing the site's files restores the theme's, byte for byte.
    for path in ["layouts/post.nim", "includes/minimal.nim", "assets/minimal.css", "og.svg.nim"]:
      removeFile(root / path)
    check cli("build").exitCode == 0
    check outputTree(public) == themeOnly

    # Eject copies the theme's file; the copy now wins (and, unchanged,
    # produces the theme's output); a second eject never overwrites it.
    let ejected = cli("theme", "eject", "layouts/post.nim")
    check ejected.exitCode == 0
    check ejected.output.startsWith("Ejected layouts/post.nim")
    check readFile(root / "layouts/post.nim") == readFile(theme / "layouts/post.nim")
    let again = cli("theme", "eject", "layouts/post.nim")
    check again.exitCode == 1
    check again.error.contains("already exists in the site")
    check cli("theme", "eject", "./assets/minimal.css").exitCode == 0
    check readFile(root / "assets/minimal.css") == readFile(theme / "assets/minimal.css")
    check cli("theme", "eject", "og.svg.nim").exitCode == 0
    check cli("build").exitCode == 0
    check outputTree(public) == themeOnly
    # Editing the ejected copy changes the site; deleting it returns to the theme.
    writeFile(root / "layouts/post.nim", readFile(root / "layouts/post.nim").replace(
      "article(class = \"post\")", "article(class = \"edited-post\")"))
    check cli("build").exitCode == 0
    check readFile(public / post).contains("<article class=\"edited-post\">")
    for path in ["layouts/post.nim", "assets/minimal.css", "og.svg.nim"]: removeFile(root / path)
    check cli("build").exitCode == 0
    check outputTree(public) == themeOnly

  test "eject refuses paths that are not theme files resolving against the site":
    let root = themedSite()
    let previous = getCurrentDir()
    setCurrentDir(root)
    defer:
      setCurrentDir(previous)
      removeDir(root)
    for (path, message) in [("theme.toml", "only layouts/, includes/, assets/ and og.svg.nim"),
        ("tokens.json", "only layouts/"), ("../site.toml", "a path inside the theme"),
        ("/etc/passwd", "a path inside the theme"), ("layouts/../theme.toml", "a path inside the theme"),
        ("layouts", "only layouts/"), ("layouts/missing.nim", "the theme has no layouts/missing.nim"),
        ("assets", "only layouts/")]:
      let response = cli("theme", "eject", path)
      check response.exitCode == 1
      check message in response.error
    check cli("theme", "eject").exitCode == 1
    check cli("theme", "copy", "layouts/post.nim").exitCode == 1
    check not dirExists(root / "layouts")
    # A site without a theme has nothing to eject.
    writeFile(root / "site.toml", readFile(repoRoot / "examples/basic/site.toml"))
    let none = cli("theme", "eject", "layouts/post.nim")
    check none.exitCode == 1
    check none.error.contains("site.toml names no theme")
