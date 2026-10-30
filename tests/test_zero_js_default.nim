## Real default export and actual Nim-JS island compilation. No fake bundles.
import std/[unittest, json, sequtils]
import isonim_blog/model
import isonim_blog/[html_checks, runtime]
import isonim/static/[scripts, assets, csp]
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
    # 8 content pages and 9 generated listings (3 index pages, 2 tags,
    # 2 categories, 2 years).
    check pages == 17
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
    # The bundle is on the site, so 'self' allows it: a path alone is not a
    # CSP source expression, and browsers would ignore it and block the
    # bundle. A script can make requests, so connect-src is 'self'.
    let islandHeaders = readFile(output / "_headers")
    check islandHeaders.contains("; script-src 'self'; style-src 'self';")
    check islandHeaders.contains("; connect-src 'self';")
    check not islandHeaders.contains(expected)
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

suite "content security policy":
  test "the policy starts from default-src 'none' and allows only what pages load":
    let root = fixtureCopy()
    defer: removeDir(root)
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let output = root / "public"
    discard runSite(compileSite(root), root, output)
    # The whole default policy: no 'unsafe-inline', framing refused, forms
    # and <base> kept on the site, nothing a script-free page cannot use.
    check readFile(output / "_headers").endsWith("/*\n  Content-Security-Policy: default-src 'none'; " &
      "script-src 'none'; style-src 'self'; img-src 'self' data:; font-src 'self'; media-src 'self'; " &
      "manifest-src 'self'; base-uri 'self'; form-action 'self'; frame-ancestors 'none'\n")
    # The policy as the build composes it for other script sets.
    let snippet = "console.log(1)"
    let analytics = blogContentSecurityPolicy([inlineScript(snippet, role = srAnalytics)], [])
    check analytics.contains("; script-src " & cspHashSource(snippet) & "; ")
    check analytics.contains("; connect-src 'self'; ")
    let beacon = blogContentSecurityPolicy([externalScript("https://stats.example/beacon.js"),
      externalScript("/assets/islands.0123456789.js"), externalScript("/js/local.js")],
      ["https://cdn.example", "https://img.example:8443"])
    check beacon.contains("; script-src https://stats.example/beacon.js 'self'; ")
    check beacon.contains("; img-src 'self' data: https://cdn.example https://img.example:8443; ")
    for policy in [analytics, beacon]:
      check policy.startsWith("default-src 'none'; ")
      check policy.endsWith("; base-uri 'self'; form-action 'self'; frame-ancestors 'none'")
      check "unsafe-inline" notin policy
      check "/assets/" notin policy

  test "style elements are found with their exact text, outside comments and scripts":
    let (styles, rest) = styleElements("<p title=\"a>b <style>\">x</p><!-- <style>no</style> -->" &
      "<STYLE media=\"print\">a > b { content: \"&amp;\" }\r\n</style >y" &
      "<script type=\"application/ld+json\">\"</style><style>\"</script>" &
      "<svg><style>c {}</style><style/></svg><style>d {}</STYLE>")
    check styles == @[StyleElement(body: "a > b { content: \"&amp;\" }\r\n"),
      StyleElement(body: "c {}", foreign: true), StyleElement(body: "", foreign: true),
      StyleElement(body: "d {}")]
    check rest == "<p title=\"a>b <style>\">x</p><!-- <style>no</style> -->y" &
      "<script type=\"application/ld+json\">\"</style><style>\"</script><svg></svg>"
    # `</styles` does not end the element; an unterminated one runs to the end.
    check styleElements("<style>a</styles>b</style>").styles == @[StyleElement(body: "a</styles>b")]
    check styleElements("<style>a</style").styles == @[StyleElement(body: "a</style")]
    check styleElements("<p>no style</p>") == (styles: newSeq[StyleElement](), rest: "<p>no style</p>")

  test "a <style> element is allowed by its hash; a style attribute fails the build":
    let root = fixtureCopy()
    defer: removeDir(root)
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let output = root / "public"
    # Positive control: the fixture's own layouts carry no inline CSS, and
    # its policy carries no hash.
    discard runSite(compileSite(root), root, output)
    check inlineStyles(readFile(output / "about/index.html")).len == 0
    check "sha256-" notin readFile(output / "_headers")
    proc pageLayout(markup: string) =
      writeFile(root / "layouts/page.nim", "import isonim_blog/model\n" &
        "proc layout*(page: Page; site: Site; content: string): string = \"" & markup & "\" & content\n")

    # A <style> element, in HTML and in inline SVG, builds; its text (line
    # endings as the browser's parser leaves them) is hashed into style-src.
    pageLayout("<style>p { color: red }\\r\\n</style><svg width=\\\"1\\\" height=\\\"1\\\">" &
      "<style>rect { fill: red }</style><rect/></svg>")
    discard runSite(compileSite(root), root, output)
    check readFile(output / "about/index.html").contains("<style>p { color: red }\r\n</style>")
    let headers = readFile(output / "_headers")
    let styled = "; style-src 'self' " & cspHashSource("p { color: red }\n") & " " &
      cspHashSource("rect { fill: red }") & "; "
    check headers.contains(styled)
    # Posts do not use the page layout, so they keep the plain policy and
    # each page gets its own rule.
    check headers.contains("; style-src 'self'; img-src ")
    check not headers.contains("/*\n  Content-Security-Policy:")
    check headers.contains("/about/\n  Content-Security-Policy: default-src 'none'; script-src 'none'" & styled)

    for (markup, message) in [
        ("<p style=\\\"color: red\\\">Red</p>", "a layout emitted inline CSS (<p style>), which the " &
          "Content-Security-Policy blocks; move it into a stylesheet under assets/ or a <style> element"),
        ("<style>p {}</style><svg width=\\\"1\\\" height=\\\"1\\\"><rect STYLE=\\\"fill: red\\\"/></svg>",
          "a layout emitted inline CSS (<rect style>)"),
        ("<svg width=\\\"1\\\" height=\\\"1\\\"><style>rect::after { content: \\\"&amp;\\\" }</style></svg>",
          "a layout emitted a <style> element whose text the Content-Security-Policy cannot allow by its hash")]:
      checkpoint markup
      pageLayout(markup)
      let binary = compileSite(root)
      try:
        discard runSite(binary, root, output)
        check false
      except BlogError as cause:
        # The first page the page layout renders is named (about, index or a note).
        check cause.msg.contains(".md: " & message)
