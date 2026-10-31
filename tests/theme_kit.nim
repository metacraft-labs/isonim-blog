## The theme conformance kit: `just test-theme <theme directory>`.
##
## Any theme -- the shipped `themes/minimal`, a theme package, or a private
## site-local theme -- is checked against the generic fixture site
## `tests/fixtures/theme-conformance/` (content only, no layouts, so every
## page is rendered by the theme under test). The checks, in order:
##
## 1. `theme.toml` is valid and its tokens resolve;
## 2. the theme has every layout the build selects by default
##    (`requiredLayouts`: post, page, index, tag, category, archive), each
##    missing one named;
## 3. the fixture builds with the theme (drafts included), at a fixed build
##    time so the result never depends on the clock or the shell;
## 4. every page kind was produced (the vacuity guard: a fixture that lost a
##    page kind would otherwise make the later checks pass vacuously);
## 5. the fixture's maths and diagrams were rendered at build time (MathML
##    with a fraction, and D2 and Graphviz SVG with labels), so the browser
##    check below has them to judge;
## 6. the directives `theme.toml` declares are exactly the ones its
##    `includes/directives.nim` registers;
## 7. zero JavaScript: no page carries a script other than JSON-LD or an
##    inline event handler, and the output holds no `.js` file;
## 8. every page links the theme's stylesheets, and they exist;
## 9. `isonim-blog check` finds nothing wrong in the production build
##    (links and anchors written by the layouts, alt text, feeds);
## 10. in Chromium, with axe-core: no WCAG 2.0/2.1/2.2 A or AA violation,
##    and no repeated landmark name (axe's `landmark-unique`), on any page,
##    in the light and the dark scheme, at 360 and 1280 pixels wide; and no
##    horizontal scroll at 360 pixels. The summary names the
##    boxes that scroll sideways inside the pages at 360 pixels (code
##    blocks, table wrappers), so whether a theme scrolls or wraps wide
##    content is visible; axe requires every such box to be focusable. Every
##    page is served with the built `_headers` (as Cloudflare Pages applies
##    it), so the generated Content-Security-Policy is enforced, and any
##    violation the browser reports is a failure. Every formula must be
##    laid out (fractions stacked) and every diagram label readable (4.5:1
##    against the shape under it) in both schemes; axe does not judge SVG
##    text.
##
## The browser checks run `theme_kit_browser.mjs` with the dev shell's pinned
## Playwright Chromium and axe-core. Nothing is mocked: the fixture is built
## by the real build, and the pages are served over loopback HTTP to a real
## browser.
import std/[os, osproc, json, strutils, algorithm, streams]
import isonim_blog
import isonim_blog/[runtime, site_check, html_checks]
import isonim/static/scripts
import ./site_helpers

type
  KitCheck* = object
    name*: string
    passed*: bool
    details*: seq[string]
  KitReport* = object
    theme*: string
    checks*: seq[KitCheck]

const
  conformanceFixture* = repoRoot / "tests/fixtures/theme-conformance"
  kitEpoch* = "1735689600"
    ## 2025-01-01T00:00:00Z: after every fixture post, so none is "future".
  browserDriver* = repoRoot / "tests/theme_kit_browser.mjs"
  expectedPages* = [
    ("post", "posts/every-prose-feature/index.html"),
    ("post bundle with a hero image", "posts/pictures/index.html"),
    ("draft post", "posts/unfinished-thoughts/index.html"),
    ("page", "about/index.html"),
    ("home page", "index.html"),
    ("collection entry", "notes/quick-tip/index.html"),
    ("post index", "posts/index.html"),
    ("second index page", "posts/page/2/index.html"),
    ("tag page", "tags/writing/index.html"),
    ("category page", "categories/guides/index.html"),
    ("year archive", "2024/index.html"),
    ("month archive", "2024/01/index.html")]
    ## One page of every kind the fixture must produce.
  generatedPage* = "posts/every-prose-feature/index.html"
    ## The fixture page with build-time maths and diagrams.
  layoutRoles = [("post", "posts"), ("page", "pages and collection entries"),
    ("index", "the paginated post index"), ("tag", "tag pages"),
    ("category", "category pages"), ("archive", "year and month archives")]

proc passed*(report: KitReport): bool =
  for check in report.checks:
    if not check.passed: return false
  report.checks.len > 0

proc failedCheck*(report: KitReport): string =
  ## The name of the first failed check, or "".
  for check in report.checks:
    if not check.passed: return check.name

proc formatReport*(report: KitReport): string =
  result = "Theme conformance: " & report.theme & "\n"
  for check in report.checks:
    result.add (if check.passed: "  PASS " else: "  FAIL ") & check.name & "\n"
    for detail in check.details: result.add "       " & detail & "\n"
  result.add (if report.passed: "The theme conforms.\n" else: "The theme does not conform.\n")

proc add(report: var KitReport; name: string; details: seq[string] = @[]; passed = details.len == 0) =
  report.checks.add KitCheck(name: name, passed: passed, details: details)

proc missingLayouts*(theme: string): seq[string] =
  ## Every required layout the theme lacks, with the pages it renders.
  for (name, role) in layoutRoles:
    let path = "layouts/" & name & ".nim"
    if not fileExists(theme / path): result.add "missing " & path & " (renders " & role & ")"

proc prepareFixture*(theme, work: string): string =
  ## A fresh copy of the generic fixture whose site.toml names `theme`.
  result = work / "site"
  copyDir(conformanceFixture, result)
  writeFile(result / "site.toml", "theme = " & $(%absolutePath(theme)) & "\n" &
    readFile(result / "site.toml"))

proc htmlPages(output: string): seq[string] =
  for file in walkDirRec(output, relative = true):
    if file.endsWith(".html"): result.add file.replace('\\', '/')
  result.sort()

proc stylesheetHrefs(html: string): seq[string] =
  for tag in startTags([html])[0]:
    if tag.name == "link" and "stylesheet" in tag.attr("rel").toLowerAscii.splitWhitespace():
      result.add tag.attr("href")

proc scrollerSummary*(scrollers: JsonNode): string =
  ## The boxes that scroll sideways inside the pages at 360 pixels, by tag
  ## and class, in byte order: `boxes scrolling sideways at 360px:
  ## div.table-scroll 2, pre 4`, or `... none`. A theme that wraps wide
  ## content has none; one that scrolls it must make each box focusable,
  ## which axe checks.
  var entries: seq[string]
  if not scrollers.isNil and scrollers.kind == JObject:
    for name, count in scrollers: entries.add name & " " & $count.getInt
  entries.sort()
  "boxes scrolling sideways at 360px: " & (if entries.len == 0: "none" else: entries.join(", "))

proc generatedProblems*(html: string): seq[string] =
  ## What the fixture's maths and diagrams page lacks: MathML with a
  ## fraction, a D2 and a Graphviz diagram (inline SVG) with labels, and no
  ## Markdown left unrendered. The browser check judges them only if they
  ## are there.
  if "<math " notin html or "<mfrac>" notin html: result.add "no MathML formula with a fraction"
  if "$$" in html or "language-math" in html: result.add "maths left as Markdown"
  if html.count("class=\"d2-") == 0 or html.count("class=\"isonim-diagram\"") < 2:
    result.add "no D2 and Graphviz diagrams (inline SVG)"
  if "language-d2" in html or "language-dot" in html: result.add "a diagram left as a code block"
  if "<text" notin html: result.add "no diagram labels"

proc generatedSummary*(counts: JsonNode): string =
  ## `maths and diagrams laid out: 12 formulas (4 fractions, 8 display), 8 diagrams
  ## (40 labels); 0 hidden with their content`, summed over every page,
  ## width and scheme. Hidden ones sit in content the theme does not show
  ## in the page's initial state, and are not judged.
  proc count(key: string): int =
    if counts.isNil or counts.kind != JObject: 0 else: counts{key}.getInt(0)
  "maths and diagrams laid out: " & $count("maths") & " formulas (" & $count("fractions") &
    " fractions, " & $count("displays") & " display), " & $count("diagrams") & " diagrams (" &
    $count("labels") & " labels); " & $count("hidden") & " hidden with their content"

proc browserChecks*(output: string; pages: seq[string]): tuple[problems: seq[string], summary: string] =
  ## Run the browser driver: every problem it reports (or why it could not
  ## run), and what it checked.
  let node = findExe("node")
  if node.len == 0: return (@["node is not on PATH; run the kit in nix develop"], "")
  for variable in ["PLAYWRIGHT_CORE_PATH", "ISONIM_BLOG_AXE"]:
    if getEnv(variable).len == 0:
      return (@[variable & " is not set; run the kit in nix develop (it pins Chromium and axe-core)"], "")
  let input = $(%*{"root": output, "pages": pages})
  let process = startProcess(node, args = [browserDriver], options = {poStdErrToStdOut})
  var transcript: string
  try:
    process.inputStream.write(input)
    process.inputStream.close()
    transcript = process.outputStream.readAll()
    let code = process.waitForExit()
    let marker = transcript.rfind("\n{\"report\":")
    let start = if transcript.startsWith("{\"report\":"): 0 elif marker >= 0: marker + 1 else: -1
    if start < 0:
      return (@["the browser driver produced no report (exit " & $code & "):"] & transcript.strip().splitLines(), "")
    let report = parseJson(transcript[start .. ^1])["report"]
    for problem in report["problems"]: result.problems.add problem.getStr
    # Vacuity guard: the fixture's maths and diagrams reached the browser.
    let counts = report{"generated"}
    if report.hasKey("runs") and (counts.isNil or counts{"present"}.getInt(0) == 0):
      result.problems.add "the browser saw no formula or diagram (" & generatedSummary(counts) & ")"
    if code != 0 and result.problems.len == 0:
      result.problems.add "the browser driver exited " & $code & " without naming a problem"
    if report.hasKey("runs"):
      result.summary = $report["runs"].getInt & " axe runs over " & $pages.len & " pages, each under " &
        "the generated Content-Security-Policy (axe-core " &
        report{"axe"}.getStr("?") & ", Chromium " & report{"browser"}.getStr("?") & "); " &
        scrollerSummary(report{"scrollers"}) & "\n" & generatedSummary(report{"generated"})
  finally: process.close()

proc runThemeKit*(theme: string; work: string; browser = true): KitReport =
  ## Check the theme at `theme`, building in the empty directory `work`.
  let theme = absolutePath(theme)
  result.theme = theme
  var manifest: ThemeManifest
  try:
    if not dirExists(theme): fail("no theme directory at " & theme)
    manifest = readThemeManifest(theme)
    discard loadThemeInfo(theme)
    result.add "theme.toml and tokens"
  except CatchableError as cause:
    result.add "theme.toml and tokens", @[cause.msg]
    return
  let missing = missingLayouts(theme)
  result.add "required layouts", missing
  if missing.len > 0: return
  let site = prepareFixture(theme, work)
  let output = work / "public"
  let previousEpoch = getEnv("SOURCE_DATE_EPOCH")
  putEnv("SOURCE_DATE_EPOCH", kitEpoch)
  defer:
    if previousEpoch.len > 0: putEnv("SOURCE_DATE_EPOCH", previousEpoch)
    else: delEnv("SOURCE_DATE_EPOCH")
  try:
    # The fixture is judged at a fixed time, so its posts are the same on any day.
    discard buildSite(site, BuildOptions(drafts: true, outDir: output, now: "@" & kitEpoch))
    result.add "the fixture builds with the theme"
  except CatchableError as cause:
    result.add "the fixture builds with the theme", cause.msg.strip().splitLines()
    return
  var absent: seq[string]
  for (kind, path) in expectedPages:
    if not fileExists(output / path): absent.add "no " & kind & " at " & path
  result.add "every page kind is built", absent
  let generated =
    if fileExists(output / generatedPage): generatedProblems(readFile(output / generatedPage))
    else: @["no " & generatedPage]
  result.add "maths and diagrams are rendered at build time", generated
  # Directives: declared in theme.toml exactly when registered.
  var registered: seq[string]
  try:
    for name in parseJson(runTool(site / "build/isonim-blog/bin/site-program", ["--directives"])):
      registered.add name.getStr
    var problems: seq[string]
    for name in manifest.directives:
      if name notin registered: problems.add "declared but not registered: " & name
    for name in registered:
      if name notin manifest.directives: problems.add "registered but not declared in theme.toml: " & name
    result.add "declared directives are registered", problems
  except CatchableError as cause:
    result.add "declared directives are registered", @[cause.msg]
  let pages = htmlPages(output)
  var scripted, unstyled: seq[string]
  for page in pages:
    let html = readFile(output / page)
    for script in scriptElements(html):
      if script.attr("type").toLowerAscii != "application/ld+json":
        scripted.add page & ": a script element"
    for handler in eventHandlerAttributes(html): scripted.add page & ": " & handler
    let hrefs = stylesheetHrefs(html)
    if manifest.stylesheets.len + (if manifest.tokenFiles.len > 0: 1 else: 0) > hrefs.len or hrefs.len == 0:
      unstyled.add page & ": links " & $hrefs.len & " stylesheets"
    for href in hrefs:
      if href.len == 0 or not fileExists(output / href.strip(leading = true, trailing = false, chars = {'/'})):
        unstyled.add page & ": stylesheet " & href & " is not in the output"
  for file in walkDirRec(output, relative = true):
    if file.endsWith(".js") or file.endsWith(".mjs"): scripted.add file & ": a JavaScript file"
  result.add "zero JavaScript", scripted
  result.add "every page links the theme's stylesheets", unstyled
  let check = checkSite(site)
  var findings: seq[string]
  for finding in check.findings:
    if finding.severity == svError: findings.add finding.location & ": " & finding.message
  if check.pages == 0: findings.add "the production check saw no pages"
  result.add "isonim-blog check (links, anchors, alt text, feeds)", findings
  if browser:
    let (problems, summary) = browserChecks(output, pages)
    result.add "WCAG 2.2 AA and unique landmark names (axe-core) in both schemes; " &
      "no horizontal scroll at 360px; " &
      "no Content-Security-Policy violation",
      (if problems.len > 0: problems else: summary.splitLines()), passed = problems.len == 0

when isMainModule:
  let args = commandLineParams()
  if args.len != 1 or args[0].startsWith("-"):
    stderr.writeLine "usage: theme-kit <theme directory>"
    quit(2)
  let work = createTempDir("isonim-blog-theme-kit-", "")
  let report = runThemeKit(args[0], work)
  stdout.write formatReport(report)
  if report.passed:
    removeDir(work)
    quit(0)
  stdout.writeLine "Build and output kept in " & work
  quit(1)
