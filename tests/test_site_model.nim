## Full fixture discovery and export through real generated Nim layouts.
## No mocked compiler, filesystem, parser or publication boundary.
import std/[unittest, json, sequtils, times]
import isonim_blog/[model, runtime]
import isonim/static/buildinfo
import ./site_helpers

suite "native site builds":
  test "fixture layout, filtering, data, resources and real output":
    let root = fixtureCopy()
    defer: removeDir(root)
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    # Vacuity guard: at least three published posts, a draft, a bundle post
    # and a future-dated post exist in the fixture itself.
    let postSources = inputFiles(root / "posts").filterIt(it.endsWith(".md"))
    check postSources.filterIt("2099-" notin it).len >= 3
    check postSources.anyIt(it.endsWith("/2099-01-01-future.md"))
    check fileExists(root / "posts/2020-03-03-bundle/index.md")
    check inputFiles(root / "drafts").filterIt(it.endsWith(".md")).len >= 1
    # Files outside site.toml and the declared directories are never read:
    # an unreadable directory and malformed content there cannot fail a build.
    writeFile(root / "README.md", "---\nnot: [valid\n---\n")
    writeFile(root / "unrelated/broken.md", "---\ndate: not-a-date\n---\n")
    setFilePermissions(root / "unrelated", {})
    defer: setFilePermissions(root / "unrelated", {fpUserRead, fpUserWrite, fpUserExec})
    # Positive control: the permission really denies reading (not running as root).
    expect IOError: discard readFile(root / "unrelated/private.md")
    let site = loadSite(root)
    check site.posts.mapIt(it.slug) == @["another", "third", "bundle", "second", "first"]
    check site.pages.len == 8
    check site.collections["notes"].len == 1
    check site.data["navigation"]["items"][0]["url"].getStr == "/about/"
    check site.extra["custom"]["enabled"].getBool
    check loadSite(root, BuildOptions(drafts: true)).pages.len == 9
    # `draft: true` keeps a dated file under posts/ out unless --drafts.
    writeFile(root / "posts/2020-04-04-hidden.md", "---\ntitle: Hidden\ndraft: true\n---\nHidden")
    check not loadSite(root).posts.anyIt(it.slug == "hidden")
    let withDrafts = loadSite(root, BuildOptions(drafts: true))
    check withDrafts.posts.filterIt(it.slug == "hidden").mapIt(it.noindex) == @[true]
    removeFile(root / "posts/2020-04-04-hidden.md")
    check loadSite(root, BuildOptions(future: true)).posts.len == 6
    let binary = compileSite(root)
    let output = root / "public"
    discard runSite(binary, root, output)
    for path in ["index.html", "about/index.html", "posts/first/index.html",
        "posts/second/index.html", "posts/bundle/index.html", "notes/short/index.html",
        "verification.txt", "asset-manifest.json", "build.json", "_headers"]:
      check fileExists(output / path)
    check not dirExists(output / "posts/future")
    check not dirExists(output / "posts/work-in-progress")
    check not dirExists(output / "unrelated")
    check not dirExists(output / "layouts")
    let post = readFile(output / "posts/first/index.html")
    check post.contains("<header>")
    check post.contains("<main><article>")
    check post.contains("id=\"beginnings\"")
    check post.contains("https://example.org/posts/first/")
    let manifest = parseFile(output / "asset-manifest.json")
    let image = manifest["posts/2020-03-03-bundle/figure.svg"].getStr
    check fileExists(output / image)
    check readFile(output / "posts/bundle/index.html").contains("href=\"/" & image & "\"")
    check parseFile(output / "build.json")["outputHash"].getStr == treeHash(output)
    let hash = treeHash(output, [])
    discard runSite(binary, root, output)
    check treeHash(output, []) == hash
    discard runSite(binary, root, output, @["--drafts", "--future", "--url", "https://preview.example"])
    let draft = readFile(output / "posts/work-in-progress/index.html")
    check draft.contains("class=\"draft-banner\"")
    check draft.contains("name=\"robots\" content=\"noindex\"")
    check draft.contains("https://preview.example/posts/work-in-progress/")
    check fileExists(output / "posts/future/index.html")
    # Content is data: the exact same executable sees edits without compilation.
    let compiledHash = sha256Hex(readFile(binary))
    writeFile(root / "posts/2020-01-01-first.md", readFile(root / "posts/2020-01-01-first.md") & "\nNew content.\n")
    discard runSite(binary, root, output)
    check readFile(output / "posts/first/index.html").contains("New content.")
    check sha256Hex(readFile(binary)) == compiledHash
    # Invalid compilation is a real error; the old output remains complete.
    let existing = treeHash(output, [])
    writeFile(root / "layouts/post.nim", "this is invalid Nim\n")
    expect BlogError: discard compileSite(root)
    check treeHash(output, []) == existing

  test "two-source collisions, output isolation and missing or invalid dates fail":
    let root = fixtureCopy()
    defer: removeDir(root)
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    writeFile(root / "pages/collision.md", "---\npermalink: /posts/first/\n---\nCollision")
    try:
      discard loadSite(root)
      check false
    except BlogError as cause:
      check cause.msg.contains("pages/collision.md")
      check cause.msg.contains("posts/2020-01-01-first.md")
    removeFile(root / "pages/collision.md")
    writeFile(root / "posts/undated.md", "missing date")
    expect BlogError: discard loadSite(root)
    removeFile(root / "posts/undated.md")
    writeFile(root / "posts/2023-02-29-invalid.md", "invalid date")
    expect BlogError: discard loadSite(root)
    removeFile(root / "posts/2023-02-29-invalid.md")
    expect BlogError: discard exportBlog(root, root / "posts/output", [])
    # An unreadable declared directory fails instead of dropping content.
    setFilePermissions(root / "posts/2020-03-03-bundle", {})
    try:
      discard loadSite(root)
      check false
    except BlogError as cause:
      check cause.msg.contains("cannot read input directory")
      check cause.msg.contains("2020-03-03-bundle")
    setFilePermissions(root / "posts/2020-03-03-bundle", {fpUserRead, fpUserWrite, fpUserExec})
    createSymlink(root / "unrelated", root / "pages/linked")
    expect BlogError: discard loadSite(root)

  test "TOML uses the real standard parser with lossless extended-value protocol":
    let root = createTempDir("isonim-blog-toml-", "")
    defer: removeDir(root)
    let file = root / "values.toml"
    writeFile(file, """title = """ & "\"Notebook\"\n" & """
quoted = { "a.b" = [true, "hello", 1] }
large = 9223372036854775807
when = 2020-01-02T03:04:05+02:00
day = 2020-01-02
clock = 03:04:05
nan = nan
infinity = -inf
"$toml" = "literal key"
""")
    let tagged = readToml(file)
    check tagged["$toml"].getStr == "table"
    let values = tagged["value"]
    check values["large"] == %*{"$toml": "integer", "value": "9223372036854775807"}
    check values["when"] == %*{"$toml": "datetime", "value": "2020-01-02T03:04:05+02:00"}
    check values["day"]["$toml"].getStr == "date"
    check values["clock"]["$toml"].getStr == "time"
    check values["nan"]["value"].getStr == "nan"
    check values["infinity"]["value"].getStr == "-inf"
    check values["quoted"]["a.b"] == %*[true, "hello", 1]
    # A literal "$toml" key at the root of site.toml survives as site.extra.
    writeFile(root / "site.toml", "title = \"Tagged\"\n\"$toml\" = \"kept\"\n")
    let tagConfig = readSiteConfig(root)
    check tagConfig.title == "Tagged"
    check tagConfig.extra == %*{"$toml": "kept"}
    writeFile(file, "title = 1\ntitle = 2\n")
    expect BlogError: discard readToml(file)
    writeFile(file, "a = [1,,2]\n")
    expect BlogError: discard readToml(file)

  test "missing parent and cyclic parent chains fail without silent fallback":
    let render: LayoutProc = proc(page: Page; site: Site; content: string): string = content
    let page = Page(source: "test.md", layout: "a", content: "Body")
    expect BlogError: discard applyLayouts(page, Site(), [LayoutEntry(name: "a", parent: "missing", render: render)])
    expect BlogError: discard applyLayouts(page, Site(), [LayoutEntry(name: "a", parent: "a", render: render)])

suite "the build clock":
  # "Now" for future-dated posts is an explicit input (`BuildOptions.now`,
  # `--now`), defaulting to the wall clock. SOURCE_DATE_EPOCH stamps output
  # only, and file modification times play no part.
  test "SOURCE_DATE_EPOCH, as a Nix dev shell sets it, hides no post":
    let root = fixtureCopy()
    defer: removeDir(root)
    # nixpkgs' stdenv (and so every mkShell) exports this 1980-01-01 value.
    putEnv("SOURCE_DATE_EPOCH", "315532800")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let site = loadSite(root)
    check site.posts.mapIt(it.slug) == @["another", "third", "bundle", "second", "first"]
    # It still stamps the output: build.json and an empty feed's date use it.
    check site.sourceDateEpoch == 315532800
    check site.buildDate == "1980-01-01"
    # The clock used for visibility is the wall clock here.
    check abs(site.now - epochTime().int64) < 600

  test "now decides which posts are future; file times do not":
    let root = fixtureCopy()
    defer: removeDir(root)
    delEnv("SOURCE_DATE_EPOCH")
    # Positive control for the fixture: one post is dated 2099-01-01.
    check fileExists(root / "posts/2099-01-01-future.md")
    # A content file modified "in 2099" does not move the clock.
    setLastModificationTime(root / "site.toml", fromUnix(4_102_444_800 + 86_400 * 180))
    check loadSite(root).posts.allIt(it.slug != "future")
    # An epoch after `@`, and RFC 3339 date-times with any offset.
    proc slugs(now: string): seq[string] = loadSite(root, BuildOptions(now: now)).posts.mapIt(it.slug)
    check slugs("@1577836800") == @["first"]                         # 2020-01-01T00:00:00Z
    check slugs("@1580515200") == @["first"]                         # 2020-02-01T00:00:00Z
    check slugs("@0001580515200") == @["first"]                      # leading zeros
    check slugs("2020-02-02T00:00:00Z") == @["second", "first"]
    check slugs("2020-02-01T23:30:00-01:00") == @["second", "first"]  # 2020-02-02T00:30Z
    check slugs("2020-02-02t00:59:59.5+01:00") == @["first"]           # 2020-02-01T23:59:59.5Z
    check slugs("2099-01-01T00:00:00Z")[0] == "future"
    let stamped = loadSite(root, BuildOptions(now: "@1577836800"))
    check stamped.now == 1577836800
    # Without SOURCE_DATE_EPOCH, output timestamps follow the build clock.
    check stamped.sourceDateEpoch == 1577836800
    check stamped.buildDate == "2020-01-01"
    for bad in [" ", "tomorrow", "2020-02-02", "2020-02-02T00:00:00", "2020-13-02T00:00:00Z",
        "2020-02-02T25:00:00Z", "@-5", "@", "2020-02-02T00:00:00+0100", "@1e9", "@ 5", "@+5"]:
      try:
        discard parseBuildClock(bad)
        checkpoint "accepted " & bad
        check false
      except BlogError as cause:
        check cause.msg.contains("--now")

  test "a bare number is refused with a pointer to '@'; the clock is bounded":
    proc refusal(value: string): string =
      try:
        discard parseBuildClock(value)
        checkpoint "accepted " & value
        check false
      except BlogError as cause:
        result = cause.msg
    # A compact date would otherwise be an epoch in 1970 and hide every post.
    for bare in ["20261028", "1580515200", "0"]:
      let message = refusal(bare)
      check message.contains("does not take a bare number")
      check message.contains("'@" & bare & "'")
    # The bounds are accepted exactly, in both forms.
    check parseBuildClock("@0") == minBuildClock
    check parseBuildClock("1970-01-01T00:00:00Z") == minBuildClock
    check parseBuildClock("@" & $maxBuildClock) == maxBuildClock
    check parseBuildClock("9999-12-30T23:59:59Z") == maxBuildClock
    check formatBuildClock(maxBuildClock) == "9999-12-30T23:59:59Z"
    # Past them, the refusal names the range, not the syntax: an epoch the
    # civil date could not represent, one past int64, and date-times before
    # 1970 or on the last day of 9999.
    for outside in ["@" & $(maxBuildClock + 1), "@9223372036854775807", "@99999999999999999999",
        "9999-12-31T00:00:00Z", "9999-12-30T23:59:59-00:01", "1969-12-31T23:59:59Z",
        "1970-01-01T00:30:00+01:00"]:
      let message = refusal(outside)
      check message.contains("must lie between 1970-01-01T00:00:00Z (@0) and 9999-12-30T23:59:59Z")
    # The upper bound leaves the civil date representable in every timezone,
    # so a value parseBuildClock accepts cannot fail later, in the build.
    check civilDate(maxBuildClock, "Pacific/Kiritimati") == "9999-12-31"  # UTC+14
    check civilDate(maxBuildClock, "Etc/GMT+12") == "9999-12-30"          # UTC-12
    check civilDate(minBuildClock, "Etc/GMT+12") == "1969-12-31"
