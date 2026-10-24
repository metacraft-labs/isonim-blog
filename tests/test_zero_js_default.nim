## Real default export and actual Nim-JS island compilation. No fake bundles.
import std/[unittest, json, sequtils]
import isonim_blog/model
import isonim_blog/html_checks
import isonim/static/[scripts, assets]
import ./site_helpers

suite "script policy":
  test "every default page is script-free except JSON-LD; islands produce one hashed bundle":
    let root = fixtureCopy()
    defer: removeDir(root)
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let binary = compileSite(root)
    let output = root / "public"
    discard runSite(binary, root, output)
    var pages = 0
    for file in inputFiles(output):
      if file.endsWith(".html"):
        inc pages
        let html = readFile(file)
        check executableScripts(html).len == 0
        for script in scriptElements(html): check script.attr("type") == "application/ld+json"
        check eventHandlerAttributes(html).len == 0
    check pages == 6
    # Negative control: the islands fixture's layout and island module (the
    # actual IsoNim DSL and hydration API on both halves) replace page.nim.
    let islandsSite = repoRoot / "tests/fixtures/islands-site"
    copyFile(islandsSite / "includes/counter.nim", root / "includes/counter.nim")
    copyFile(islandsSite / "layouts/page.nim", root / "layouts/page.nim")
    writeFile(root / "site.toml", readFile(root / "site.toml").replace("scripts = \"none\"", "scripts = \"islands\""))
    let islandBinary = compileSite(root)
    let declarations = parseJson(runTool(islandBinary, ["--islands"]))
    check declarations == %*[{"module": "includes/counter", "selector": "#counter"}]
    let source = generateBundle(root / "build/program", declarations)
    let bundle = root / "build/islands.js"
    var args = @["js", "--hints:off", "--out:" & bundle, "--nimcache:" & root / "build/nimcache-js"]
    for path in sourcePaths(): args.add "--path:" & path
    args.add source
    discard runTool(findExe("nim"), args)
    discard runTool(findExe("node"), ["--check", bundle])
    discard runSite(islandBinary, root, output, @["--bundle", bundle])
    let expected = "assets/" & hashedAssetName("islands.js", readFile(bundle))
    check fileExists(output / expected)
    check readFile(output / expected) == readFile(bundle)
    let jsFiles = inputFiles(output).filterIt(it.endsWith(".js"))
    check jsFiles.len == 1
    let scripts = executableScripts(readFile(output / "about/index.html"))
    check scripts == @["<script src=\"/" & expected & "\" defer>"]
    check readFile(output / "about/index.html").contains("data-hk=\"counter-1\"")
    check readFile(output / "_headers").contains("script-src /" & expected)
    # A hand-authored script cannot evade the default policy.
    writeFile(root / "site.toml", readFile(root / "site.toml").replace("scripts = \"islands\"", "scripts = \"none\""))
    writeFile(root / "layouts/page.nim", """import isonim_blog/model
proc layout*(page: Page; site: Site; content: string): string = "<SCRIPT type=\"application/json\">{}</SCRIPT>"
""")
    let bad = compileSite(root)
    try:
      discard runSite(bad, root, output)
      check false
    except BlogError as cause:
      check cause.msg.contains("a layout emitted an undeclared script or data block")
