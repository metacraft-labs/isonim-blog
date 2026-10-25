## Responsive images end to end: the generic fixture site is built by its
## real compiled layout program with the real libvips the dev shell supplies
## (`ISONIM_BLOG_VIPS`), and the built pages are read with the standard
## Python standard library's HTML tokenizer, not the code that wrote them. Variant sizes are
## checked with `vipsheader`, libvips' own reader. No test doubles.
import std/[unittest, strutils, sequtils, strtabs]
import isonim_blog/model
import ./site_helpers

let vipsheader = parentDir(getEnv("ISONIM_BLOG_VIPS")) / "vipsheader"
doAssert fileExists(vipsheader), "ISONIM_BLOG_VIPS is not set: run this suite in nix develop"

proc header(file, field: string): string =
  ## A field of an image file as libvips reads it.
  runTool(vipsheader, ["-f", field, file]).strip

proc built(setup: proc(root: string) = nil; args: seq[string] = @[]):
    tuple[root, output, log: string] =
  result.root = fixtureCopy()
  if setup != nil: setup(result.root)
  result.output = result.root / "public"
  result.log = runSite(compileSite(result.root), result.root, result.output, args)

type Element = Table[string, string]

proc attr(element: Element; name: string): string = element.getOrDefault(name)

proc srcset(source: Element): seq[tuple[url: string, width: int]] =
  for candidate in source.attr("srcset").split(", "):
    let parts = candidate.split(' ')
    doAssert parts.len == 2 and parts[1].endsWith("w"), candidate
    result.add (parts[0], parseInt(parts[1][0 ..< ^1]))

proc failure(root: string): string =
  ## The message of a build that must fail, with no output written.
  try:
    discard runSite(compileSite(root), root, root / "failed")
    result = ""
  except BlogError as cause:
    result = cause.msg
  doAssert not dirExists(root / "failed"), "a failed build must not publish: " & result

proc appendToPost(root, text: string) =
  let post = root / "posts/2020-03-03-bundle/index.md"
  writeFile(post, readFile(post) & "\n" & text & "\n")

suite "responsive images":
  test "a fixture raster yields the configured variants with srcset and dimensions; an SVG passes through":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let (root, output, _) = built()
    defer: removeDir(root)
    let page = output / "posts/bundle/index.html"
    check htmlElements(page, "picture").len == 1
    let sources = htmlElements(page, "source")
    check sources.mapIt(it.attr("type")) == @["image/avif", "image/webp"]
    for (source, loader) in [(sources[0], "heifload"), (sources[1], "webpload")]:
      let candidates = srcset(source)
      # The default widths below the 1000-pixel source, plus the source width.
      check candidates.mapIt(it.width) == @[480, 960, 1000]
      check source.attr("sizes") == "(min-width: 1000px) 1000px, 100vw"
      for (url, width) in candidates:
        check url.startsWith("/assets/posts/2020-03-03-bundle/photo-" & $width & ".")
        let file = output / url[1 .. ^1]
        check header(file, "width") == $width
        check header(file, "height") == $(width * 600 div 1000)
        check header(file, "vips-loader") == loader
    let images = htmlElements(page, "img")
    check images.len == 2
    let photo = images[0]
    check photo.attr("src").startsWith("/assets/posts/2020-03-03-bundle/photo.")
    check photo.attr("width") == "1000" and photo.attr("height") == "600"
    # The page's first image loads eagerly; every later one lazily.
    check photo.attr("loading") == ""
    # The SVG passes through: its own size, lazy, and no picture around it.
    let figure = images[1]
    check figure.attr("src").startsWith("/assets/posts/2020-03-03-bundle/figure.")
    check figure.attr("width") == "24" and figure.attr("height") == "24"
    check figure.attr("loading") == "lazy"
    check readFile(page).count("<picture>") == 1
    # Negative control: the SVG produced no raster variants, the PNG did.
    var variants: seq[string]
    for file in inputFiles(output / "assets/posts/2020-03-03-bundle"):
      variants.add extractFilename(file)
    check variants.filterIt(it.startsWith("figure")).len == 1
    check variants.filterIt(it.startsWith("photo-")).len == 6
    # The source itself is published too, as the fallback.
    check fileExists(output / photo.attr("src")[1 .. ^1])

  test "the [images] widths and formats are what is built":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let (root, output, _) = built(setup = proc(root: string) =
      writeFile(root / "site.toml", readFile(root / "site.toml") &
        "[images]\nwidths = [300, 600]\nformats = [\"webp\"]\n"))
    defer: removeDir(root)
    let sources = htmlElements(output / "posts/bundle/index.html", "source")
    check sources.mapIt(it.attr("type")) == @["image/webp"]
    # No configured width reaches 1000, so the source width is not added.
    check srcset(sources[0]).mapIt(it.width) == @[300, 600]
    check toSeq(walkFiles(output / "assets/posts/2020-03-03-bundle/*.avif")).len == 0
    for bad in ["[images]\nwidths = [0]\n", "[images]\nformats = [\"gif\"]\n",
        "[images]\nmax_source_bytes = -1\n", "[images]\nwidths = \"480\"\n"]:
      writeFile(root / "site.toml", readFile(root / "site.toml").split("[images]")[0] & bad)
      expect BlogError: discard loadSite(root)

  test "a missing alt text, an oversized source and a missing image fail the build":
    # The post must be in the build: the dev shell sets SOURCE_DATE_EPOCH to
    # 1980, which would leave every post out as future-dated.
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    var root = fixtureCopy()
    defer: removeDir(root)
    appendToPost(root, "![](photo.png)")
    let missingAlt = failure(root)
    check "posts/2020-03-03-bundle/index.md: the image /assets/posts/2020-03-03-bundle/photo." in missingAlt
    check "has no alt text" in missingAlt
    removeDir(root)
    root = fixtureCopy()
    writeFile(root / "site.toml", readFile(root / "site.toml") & "[images]\nmax_source_bytes = 1000\n")
    let size = getFileSize(root / "posts/2020-03-03-bundle/photo.png")
    check "is " & $size & " bytes, over the limit of 1000" in failure(root)
    # Positive control: a limit the source fits under builds.
    writeFile(root / "site.toml", readFile(root / "site.toml").replace("max_source_bytes = 1000",
      "max_source_bytes = " & $size))
    discard runSite(compileSite(root), root, root / "public")
    check fileExists(root / "public/posts/bundle/index.html")
    removeDir(root)
    root = fixtureCopy()
    appendToPost(root, "![Gone](/missing.png)")
    check "the image /missing.png is not a file of the site" in failure(root)

  test "a layout image gets dimensions and variants; a remote image is a warning":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let (root, output, log) = built(setup = proc(root: string) =
      copyFile(root / "posts/2020-03-03-bundle/photo.png", root / "assets/banner.png")
      # The header include shows the banner on every page, through the
      # hashed asset URL a layout gets from site.assets.
      writeFile(root / "includes/header.nim", readFile(root / "includes/header.nim").replace(
        "    header:\n", "    header:\n      img(src = site.assets[\"assets/banner.png\"], alt = \"Banner\")\n"))
      appendToPost(root, "![A remote picture](https://elsewhere.example/a.png)"))
    defer: removeDir(root)
    for file in [output / "about/index.html", output / "posts/bundle/index.html"]:
      let images = htmlElements(file, "img")
      check images[0].attr("alt") == "Banner"
      check images[0].attr("width") == "1000" and images[0].attr("loading") == ""
      for later in images[1 .. ^1]: check later.attr("loading") == "lazy"
    let bundle = htmlElements(output / "posts/bundle/index.html", "img")
    check bundle[^1].attr("src") == "https://elsewhere.example/a.png"
    check bundle[^1].attr("width") == ""
    check "warning: posts/2020-03-03-bundle/index.md: the image https://elsewhere.example/a.png " &
      "is not a file of the site" in log
    # The banner's variants are made once, however many pages show it.
    check toSeq(walkFiles(output / "assets/banner-*.webp")).len == 3

  test "a missing libvips is an error naming its setting, never a silent skip":
    let root = fixtureCopy()
    defer: removeDir(root)
    let env = newStringTable(modeCaseSensitive)
    for key, value in envPairs():
      if key != "ISONIM_BLOG_VIPS": env[key] = value
    try:
      discard runTool(compileSite(root), [root / "failed", "--root", root], env = env)
      check false
    except BlogError as cause:
      check "ISONIM_BLOG_VIPS is not set" in cause.msg
    check not dirExists(root / "failed")
