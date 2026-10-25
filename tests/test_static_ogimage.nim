## OpenGraph images end to end: the generic fixture site is built by its
## real compiled layout program with the real resvg and the bundled fonts
## the dev shell supplies (`ISONIM_BLOG_RESVG`, `ISONIM_BLOG_OG_FONTS`).
## Pages are read with the standard library's HTML parser, and the PNGs with
## `vipsheader` and `vips getpoint` (libvips, an independent reader). Two
## builds from fixture copies at different paths are compared byte for
## byte. No test doubles.
import std/[unittest, strutils, sequtils, htmlparser, xmltree, strtabs, tables]
import isonim_blog/model
import ./site_helpers

let vips = getEnv("ISONIM_BLOG_VIPS")
doAssert fileExists(vips), "ISONIM_BLOG_VIPS is not set: run this suite in nix develop"
doAssert getEnv("ISONIM_BLOG_RESVG").len > 0, "ISONIM_BLOG_RESVG is not set: run this suite in nix develop"

proc header(file, field: string): string =
  runTool(parentDir(vips) / "vipsheader", ["-f", field, file]).strip

proc pixel(file: string; x, y: int): string =
  ## The colour at (x, y), as libvips reads it ("r g b").
  runTool(vips, ["getpoint", file, $x, $y]).strip

proc metas(file: string): Table[string, string] =
  ## The page's `<meta property|name content>` values.
  proc visit(node: XmlNode; found: var Table[string, string]) =
    if node.kind != xnElement: return
    if node.tag == "meta":
      let key = if node.attr("property").len > 0: node.attr("property") else: node.attr("name")
      if key.len > 0: found[key] = node.attr("content")
    for child in node: visit(child, found)
  visit(parseHtml(readFile(file)), result)

proc build(setup: proc(root: string) = nil): tuple[root, output: string] =
  result.root = fixtureCopy()
  if setup != nil: setup(result.root)
  result.output = result.root / "public"
  discard runSite(compileSite(result.root), result.root, result.output)

proc tree(dir: string): seq[tuple[path, content: string]] =
  for file in inputFiles(dir): result.add (relativePath(file, dir), readFile(file))

proc failure(root: string; env: StringTableRef = nil): string =
  try:
    discard runTool(compileSite(root), [root / "failed", "--root", root], env = env)
  except BlogError as cause:
    result = cause.msg
  doAssert not dirExists(root / "failed"), "a failed build must not publish"

const posts = ["first", "second", "bundle", "another", "third"]

suite "OpenGraph images":
  test "each fixture post gets a 1200x630 PNG referenced by og:image, and two builds produce identical bytes":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let first = build()
    defer: removeDir(first.root)
    var images: seq[string]
    for post in posts:
      let page = first.output / "posts" / post / "index.html"
      let meta = metas(page)
      let url = meta["og:image"]
      check url.startsWith("https://example.org/assets/og/posts/" & post & ".") and url.endsWith(".png")
      check meta["twitter:image"] == url
      check meta["twitter:card"] == "summary_large_image"
      let file = first.output / url["https://example.org/".len .. ^1]
      check header(file, "vips-loader") == "pngload"
      check header(file, "width") == "1200" and header(file, "height") == "630"
      images.add readFile(file)
    # One card per post, each showing its own title.
    check images.deduplicate.len == posts.len
    # Every other page gets one too (pages and generated listings).
    for page in ["index.html", "about/index.html", "tags/nim/index.html", "2020/index.html"]:
      check metas(first.output / page)["og:image"].startsWith("https://example.org/assets/og/")
    # A second build, from another copy at another path, is byte-identical.
    let second = build()
    defer: removeDir(second.root)
    check first.root != second.root
    check tree(first.output) == tree(second.output)
    check tree(first.output).filterIt(it.path.startsWith("assets/og/")).len == 17

  test "og_image overrides the generated card":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let (root, output) = build(setup = proc(root: string) =
      let bundle = root / "posts/2020-03-03-bundle/index.md"
      copyFile(root / "posts/2020-03-03-bundle/photo.png", root / "posts/2020-03-03-bundle/cover.png")
      writeFile(bundle, readFile(bundle).replace("tags: [web]", "tags: [web]\nog_image: cover.png"))
      let first = root / "posts/2020-01-01-first.md"
      writeFile(first, readFile(first).replace("kind: essay", "kind: essay\nog_image: https://cdn.example/first.png")))
    defer: removeDir(root)
    let bundle = metas(output / "posts/bundle/index.html")["og:image"]
    check bundle.startsWith("https://example.org/assets/posts/2020-03-03-bundle/cover.") and bundle.endsWith(".png")
    check fileExists(output / bundle["https://example.org/".len .. ^1])
    check metas(output / "posts/first/index.html")["og:image"] == "https://cdn.example/first.png"
    # Neither page got a generated card; the others still do.
    check toSeq(walkFiles(output / "assets/og/posts/bundle.*.png")).len == 0
    check toSeq(walkFiles(output / "assets/og/posts/first.*.png")).len == 0
    check toSeq(walkFiles(output / "assets/og/posts/second.*.png")).len == 1
    # An og_image that names no file is an error naming the page.
    let missing = fixtureCopy()
    defer: removeDir(missing)
    let about = missing / "pages/about.md"
    writeFile(about, readFile(about).replace("title: About", "title: About\nog_image: nowhere.png"))
    check "pages/about.md: og_image nowhere.png is not a file of the site" in failure(missing)

  test "a site's og.svg.nim replaces the built-in template":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let (root, output) = build(setup = proc(root: string) =
      writeFile(root / "og.svg.nim", "import isonim_blog/[model, og]\n" &
        "proc ogImage*(page: Page; site: Site): string =\n" &
        "  \"<svg xmlns=\\\"http://www.w3.org/2000/svg\\\" viewBox=\\\"0 0 1200 630\\\">\" &\n" &
        "    \"<rect width=\\\"1200\\\" height=\\\"630\\\" fill=\\\"#ff0000\\\"/>\" &\n" &
        "    \"<text x=\\\"40\\\" y=\\\"300\\\" font-size=\\\"60\\\">\" & svgText(page.title) & \"</text></svg>\"\n"))
    defer: removeDir(root)
    let url = metas(output / "posts/first/index.html")["og:image"]
    let file = output / url["https://example.org/".len .. ^1]
    check header(file, "width") == "1200"
    check pixel(file, 10, 10) == "255 0 0 255"
    # Positive control: the built-in card is not red there.
    let plain = build()
    defer: removeDir(plain.root)
    let builtIn = metas(plain.output / "posts/first/index.html")["og:image"]
    check pixel(plain.output / builtIn["https://example.org/".len .. ^1], 10, 10) != "255 0 0 255"
    # A template that reaches outside itself is refused.
    writeFile(root / "og.svg.nim", readFile(root / "og.svg.nim").replace(
      "<rect width", "<image href=\\\"/etc/hostname\\\" width=\\\"9\\\" height=\\\"9\\\"/><rect width"))
    check "OpenGraph image: <image href=\"/etc/hostname\">" in failure(root)

  test "a missing resvg or font directory is an error naming its setting":
    let root = fixtureCopy()
    defer: removeDir(root)
    for name in ["ISONIM_BLOG_RESVG", "ISONIM_BLOG_OG_FONTS"]:
      let env = newStringTable(modeCaseSensitive)
      for key, value in envPairs():
        if key != name: env[key] = value
      check name in failure(root, env)
