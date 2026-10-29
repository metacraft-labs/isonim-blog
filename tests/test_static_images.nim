## Responsive images end to end: the generic fixture site is built by its
## real compiled layout program with the real libvips the dev shell supplies
## (`ISONIM_BLOG_VIPS`), and the built pages are read with the standard
## Python standard library's HTML tokenizer, not the code that wrote them. Variant sizes are
## checked with `vipsheader`, libvips' own reader. No test doubles.
import std/[unittest, strutils, sequtils, strtabs, algorithm]
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
    # The page's first content image loads eagerly; every later one lazily.
    # Both decode asynchronously.
    check photo.attr("loading") == ""
    check photo.attr("decoding") == "async"
    # The SVG passes through: its own size, lazy, and no picture around it.
    let figure = images[1]
    check figure.attr("src").startsWith("/assets/posts/2020-03-03-bundle/figure.")
    check figure.attr("width") == "24" and figure.attr("height") == "24"
    check figure.attr("loading") == "lazy" and figure.attr("decoding") == "async"
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
        "[images]\nmax_source_bytes = -1\n", "[images]\nwidths = \"480\"\n",
        "[images]\nquality = 50\n", "[images]\nquality = { avif = 0 }\n",
        "[images]\nquality = { webp = 101 }\n", "[images]\nquality = { webp = 7.5 }\n",
        "[images]\nquality = { jpeg = 80 }\n", "[images]\nremote_origins = \"https://cdn.example\"\n",
        "[images]\nremote_origins = [\"https://cdn.example/images/\"]\n",
        "[images]\nremote_origins = [\"cdn.example\"]\n"]:
      writeFile(root / "site.toml", readFile(root / "site.toml").split("[images]")[0] & bad)
      expect BlogError: discard loadSite(root)

  test "a Markdown image without alt text, an oversized source and a missing image fail the build":
    # A fixed SOURCE_DATE_EPOCH keeps the output timestamps stable.
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    var root = fixtureCopy()
    defer: removeDir(root)
    appendToPost(root, "![](photo.png)")
    let missingAlt = failure(root)
    # The error names the source file and the image's line (the post has 12
    # lines; the appended image is on line 14).
    check "posts/2020-03-03-bundle/index.md:14: the image /posts/2020-03-03-bundle/photo.png has no alt text" in missingAlt
    check "![](...){decorative}" in missingAlt
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

  test "a layout image gets dimensions and variants; an allowed remote image is a warning":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let (root, output, log) = built(setup = proc(root: string) =
      copyFile(root / "posts/2020-03-03-bundle/photo.png", root / "assets/banner.png")
      # The header include shows the banner on every page, through the
      # hashed asset URL a layout gets from site.assets.
      writeFile(root / "includes/header.nim", readFile(root / "includes/header.nim").replace(
        "    header:\n", "    header:\n      img(src = site.assets[\"assets/banner.png\"], alt = \"Banner\")\n"))
      appendToPost(root, "![A remote picture](https://elsewhere.example/a.png)")
      writeFile(root / "site.toml", readFile(root / "site.toml") &
        "[images]\nremote_origins = [\"https://elsewhere.example\"]\n"))
    defer: removeDir(root)
    for file in [output / "about/index.html", output / "posts/bundle/index.html"]:
      let images = htmlElements(file, "img")
      check images[0].attr("alt") == "Banner"
      check images[0].attr("width") == "1000" and images[0].attr("loading") == ""
      # The banner is in the header, outside <main>: not a content image, so
      # it loads as the layout wrote it, and does not use up the eager slot.
      check images[0].attr("decoding") == ""
    let about = htmlElements(output / "about/index.html", "img")
    check about.len == 1
    let content = htmlElements(output / "posts/bundle/index.html", "img")[1 .. ^1]
    check content.len == 3
    check content[0].attr("alt") == "A green hill under a blue sky with a yellow sun"
    check content[0].attr("loading") == "" and content[0].attr("decoding") == "async"
    for later in content[1 .. ^1]:
      check later.attr("loading") == "lazy" and later.attr("decoding") == "async"
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

  test "decorative images: ![](src){decorative} and a layout's alt=\"\" build; contradictions fail":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let (root, output, _) = built(setup = proc(root: string) =
      copyFile(root / "posts/2020-03-03-bundle/photo.png", root / "assets/rule.png")
      writeFile(root / "includes/header.nim", readFile(root / "includes/header.nim").replace(
        "    header:\n", "    header:\n      img(src = site.assets[\"assets/rule.png\"], alt = \"\")\n"))
      appendToPost(root, "![](figure.svg){decorative}"))
    defer: removeDir(root)
    let images = htmlElements(output / "posts/bundle/index.html", "img")
    # The header rule and the Markdown figure are both decorative: alt="".
    check images[0].hasKey("alt") and images[0].attr("alt") == ""
    check images[^1].hasKey("alt") and images[^1].attr("alt") == ""
    check images[^1].attr("src").startsWith("/assets/posts/2020-03-03-bundle/figure.")
    check "{decorative}" notin readFile(output / "posts/bundle/index.html")
    # Alt text on an image marked decorative is a contradiction.
    var contradictory = fixtureCopy()
    defer: removeDir(contradictory)
    appendToPost(contradictory, "![A hill](photo.png){decorative}")
    check "index.md:14: the image /posts/2020-03-03-bundle/photo.png is marked {decorative} but has alt text" in
      failure(contradictory)
    # A layout image with no alt attribute at all is an error.
    let layout = fixtureCopy()
    defer: removeDir(layout)
    copyFile(layout / "posts/2020-03-03-bundle/photo.png", layout / "assets/rule.png")
    writeFile(layout / "includes/header.nim", readFile(layout / "includes/header.nim").replace(
      "    header:\n", "    header:\n      img(src = site.assets[\"assets/rule.png\"])\n"))
    check "the image /assets/rule." in failure(layout)
    check "has no alt attribute (alt=\"\" marks a decorative image)" in failure(layout)

  test "a hero image needs image_alt; image_alt: \"\" marks it decorative":
    let root = fixtureCopy()
    defer: removeDir(root)
    let post = root / "posts/2020-03-03-bundle/index.md"
    let original = readFile(post)
    writeFile(post, original.replace("tags: [web]", "tags: [web]\nimage: photo.png"))
    try:
      discard loadSite(root)
      check false
    except BlogError as cause:
      check "posts/2020-03-03-bundle/index.md: image_alt is required with image" in cause.msg
    writeFile(post, original.replace("tags: [web]", "tags: [web]\nimage: photo.png\nimage_alt: \"\""))
    let site = loadSite(root)
    for page in site.pages:
      if page.source == "posts/2020-03-03-bundle/index.md":
        check page.image == "photo.png" and page.imageAlt == ""

  test "remote images come only from [images] remote_origins, which the CSP allows":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    var root = fixtureCopy()
    appendToPost(root, "![A remote picture](https://cdn.example/a.png)")
    let refused = failure(root)
    check "posts/2020-03-03-bundle/index.md: the image https://cdn.example/a.png is on " &
      "https://cdn.example, which is not an allowed remote image origin" in refused
    check "[images] remote_origins" in refused
    removeDir(root)
    let (allowedRoot, output, log) = built(setup = proc(root: string) =
      appendToPost(root, "![A remote picture](https://cdn.example/a.png)")
      writeFile(root / "site.toml", readFile(root / "site.toml") &
        "[images]\nremote_origins = [\"https://CDN.example/\", \"https://static.example:8443\"]\n"))
    defer: removeDir(allowedRoot)
    check htmlElements(output / "posts/bundle/index.html", "img")[^1].attr("src") == "https://cdn.example/a.png"
    check "the image https://cdn.example/a.png is not a file of the site" in log
    # The policy names exactly the configured origins, normalised.
    let headers = readFile(output / "_headers")
    check "img-src 'self' data: https://cdn.example https://static.example:8443;" in headers
    # Positive control: without remote origins the policy names none.
    let (plainRoot, plainOutput, _) = built()
    defer: removeDir(plainRoot)
    check "img-src 'self' data:;" in readFile(plainOutput / "_headers")

  test "an absolute URL on the site's own origin needs no listing and stays out of the CSP":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    # site.toml's url is https://example.org, which is not listed here.
    let (root, output, _) = built(setup = proc(root: string) =
      appendToPost(root, "![Our own picture](https://EXAMPLE.org:443/elsewhere.png)")
      writeFile(root / "site.toml", readFile(root / "site.toml") &
        "[images]\nremote_origins = [\"https://cdn.example\"]\n"))
    defer: removeDir(root)
    check htmlElements(output / "posts/bundle/index.html", "img")[^1].attr("src") ==
      "https://EXAMPLE.org:443/elsewhere.png"
    check "img-src 'self' data: https://cdn.example;" in readFile(output / "_headers")
    # Listing it anyway adds nothing: the policy's 'self' already covers it.
    let (listedRoot, listedOutput, _) = built(setup = proc(root: string) =
      writeFile(root / "site.toml", readFile(root / "site.toml") &
        "[images]\nremote_origins = [\"https://example.org\", \"https://cdn.example\"]\n"))
    defer: removeDir(listedRoot)
    check "img-src 'self' data: https://cdn.example;" in readFile(listedOutput / "_headers")
    # Positive control: the same image on a site whose url is another origin
    # is a remote image, refused because it is not listed.
    let other = fixtureCopy()
    defer: removeDir(other)
    appendToPost(other, "![Our own picture](https://EXAMPLE.org:443/elsewhere.png)")
    writeFile(other / "site.toml", readFile(other / "site.toml").replace(
      "url = \"https://example.org\"", "url = \"https://blog.example.net\""))
    check "is on https://example.org, which is not an allowed remote image origin" in failure(other)

  test "[images] quality sets the encoder quality of the variants":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    proc variants(output: string): seq[tuple[kind, name: string, size: int64]] =
      ## Each variant by its width and format (`photo-480.avif`), then its
      ## fingerprinted name and size.
      for file in inputFiles(output / "assets/posts/2020-03-03-bundle"):
        let name = extractFilename(file)
        if name.startsWith("photo-"):
          result.add (name.split('.')[0] & "." & name.split('.')[^1], name, getFileSize(file))
      result.sort()
    let (plainRoot, plainOutput, _) = built()
    defer: removeDir(plainRoot)
    # The defaults are AVIF 50 and WebP 75: written out, the same files.
    let (sameRoot, sameOutput, _) = built(setup = proc(root: string) =
      writeFile(root / "site.toml", readFile(root / "site.toml") &
        "[images]\nquality = { avif = 50, webp = 75 }\n"))
    defer: removeDir(sameRoot)
    check variants(sameOutput) == variants(plainOutput)
    let (lowRoot, lowOutput, _) = built(setup = proc(root: string) =
      writeFile(root / "site.toml", readFile(root / "site.toml") &
        "[images]\nquality = { avif = 20, webp = 30 }\n"))
    defer: removeDir(lowRoot)
    let plain = variants(plainOutput)
    let low = variants(lowOutput)
    check plain.len == 6 and low.len == 6
    for i in 0 ..< 6:
      # Same width and format, different bytes, fewer of them.
      check low[i].kind == plain[i].kind
      check low[i].name != plain[i].name
      check low[i].size < plain[i].size
