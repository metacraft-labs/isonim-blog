## The theme conformance kit's static checks, and the theme format carrying
## an ambitious design.
##
## - Negative control: a copy of the shipped theme without its post layout
##   fails the kit at "required layouts", naming layouts/post.nim, and a
##   theme declaring a directive it does not register fails naming it.
## - The shipped minimal theme and the capability fixture theme pass every
##   static check of the kit (the browser checks need Chromium and run in
##   `just test-theme`, outside the sandboxed suites).
## - The capability fixture theme's output carries :has() state, a popover,
##   scroll-driven animation, a print stylesheet, layout chosen by
##   `page.extra` fields, a registered directive, required keys and default
##   configuration.
##
## Real builds with the real compiler throughout; no test doubles.
import std/[unittest, json, strutils, sequtils, algorithm]
import isonim_blog
import ./site_helpers
import ./theme_kit

proc themeCopy(source: string): string =
  result = createTempDir("isonim-blog-theme-copy-", "") / "theme"
  copyDir(source, result)

proc stylesheetText(public, page: string): string =
  ## Every stylesheet a page links, concatenated in link order.
  for tag in htmlElements(public / page, "link"):
    if tag.getOrDefault("rel") == "stylesheet":
      result.add readFile(public / tag["href"].strip(chars = {'/'}, trailing = false))

suite "theme conformance kit":
  test "negative control: a theme without the post layout fails naming it":
    let theme = themeCopy(repoRoot / "themes/minimal")
    let work = createTempDir("isonim-blog-kit-", "")
    defer:
      removeDir(theme.parentDir)
      removeDir(work)
    removeFile(theme / "layouts/post.nim")
    let report = runThemeKit(theme, work, browser = false)
    check not report.passed
    check report.failedCheck == "required layouts"
    check report.checks[^1].details == @["missing layouts/post.nim (renders posts)"]
    check "FAIL required layouts" in formatReport(report)
    check "missing layouts/post.nim" in formatReport(report)
    # Nothing was built for a theme that cannot render every page kind.
    check not dirExists(work / "public")

  test "the shipped minimal theme passes every static check":
    let work = createTempDir("isonim-blog-kit-", "")
    defer: removeDir(work)
    let report = runThemeKit(repoRoot / "themes/minimal", work, browser = false)
    if not report.passed: echo formatReport(report)
    check report.passed
    check report.checks.mapIt(it.name) == @["theme.toml and tokens", "required layouts",
      "the fixture builds with the theme", "every page kind is built",
      "maths and diagrams are rendered at build time",
      "declared directives are registered", "zero JavaScript",
      "every page links the theme's stylesheets",
      "isonim-blog check (links, anchors, alt text, feeds)"]
    # Vacuity guard: the fixture really produced every page kind, and the
    # draft was built (the kit builds with drafts).
    for (kind, path) in expectedPages: check fileExists(work / "public" / path)
    let post = readFile(work / "public/posts/every-prose-feature/index.html")
    # Task checkboxes have accessible names: the item text labels each one.
    check "<label><input type=\"checkbox\" disabled checked> Write the content</label>" in post
    check "<label><input type=\"checkbox\" disabled> Review the theme</label>" in post
    check readFile(work / "public/posts/unfinished-thoughts/index.html").contains("class=\"draft-banner\"")

  test "a directive declared in theme.toml must be registered":
    let theme = themeCopy(repoRoot / "tests/fixtures/theme-capabilities")
    let work = createTempDir("isonim-blog-kit-", "")
    defer:
      removeDir(theme.parentDir)
      removeDir(work)
    writeFile(theme / "theme.toml", readFile(theme / "theme.toml").replace(
      "directives = [\"pullquote\"]", "directives = [\"pullquote\", \"sidenote\"]"))
    let report = runThemeKit(theme, work, browser = false)
    check report.failedCheck == "the fixture builds with the theme"
    check report.checks[^1].details.join("\n").contains(
      "declares directive sidenote in theme.toml, but includes/directives.nim does not register it")

suite "the format carries an ambitious design":
  test "the capability fixture theme passes the static checks":
    let work = createTempDir("isonim-blog-kit-", "")
    defer: removeDir(work)
    let report = runThemeKit(repoRoot / "tests/fixtures/theme-capabilities", work, browser = false)
    if not report.passed: echo formatReport(report)
    check report.passed

  test ":has() state, popovers, scroll timelines, print, page.extra, directives and defaults":
    let theme = repoRoot / "tests/fixtures/theme-capabilities"
    let root = createTempDir("isonim-blog-capabilities-", "")
    defer: removeDir(root)
    copyDir(conformanceFixture, root)
    writeFile(root / "site.toml", "theme = " & $(%theme) & "\n" & readFile(root / "site.toml").replace(
      "paginate = 2\n", ""))
    writeFile(root / "posts/2024-03-03-field-report.md", """---
title: Field report
description: A long-form essay with credits
kind: essay
status: revised
credits: [Research by A. Example, Photographs by B. Example]
---

The opening paragraph is the overview.

:::pullquote
Every claim here can be **checked**.
:::

The rest of the essay is the details layer.
""")
    putEnv("SOURCE_DATE_EPOCH", kitEpoch)
    defer: delEnv("SOURCE_DATE_EPOCH")
    discard buildSite(root)
    let public = root / "public"
    let essay = readFile(public / "posts/field-report/index.html")
    let note = readFile(public / "posts/short-note/index.html")
    # page.extra drives the layout: kind, status and credits.
    check "<article class=\"post kind-essay\">" in essay
    check "<p class=\"status status-revised\">Status: revised</p>" in essay
    check "<article class=\"post kind-note\">" in note
    check "class=\"status" notin note
    # A popover opened by a button, with no script.
    check "<button type=\"button\" popovertarget=\"credits-field-report\">Credits</button>" in essay
    check "<div id=\"credits-field-report\" popover=\"auto\" class=\"credits\">" in essay
    check "<li>Photographs by B. Example</li>" in essay
    check "popover" notin note
    # The CSS-only switch: two labelled radio inputs.
    check "<input type=\"radio\" name=\"layer\" id=\"layer-details\" />" in essay or
      "<input type=\"radio\" name=\"layer\" id=\"layer-details\">" in essay
    check "<label for=\"layer-details\">Details</label>" in essay
    # The registered directive renders its Markdown body as a quotation.
    check "<blockquote><p>Every claim here can be **checked**.</p></blockquote>" in essay
    let css = stylesheetText(public, "posts/field-report/index.html")
    check "body:has(#layer-details:checked) .details" in css
    check "animation-timeline: scroll(root)" in css
    check "@media print" in css
    # Tokens from two documents, with dark values from `Dark` modes; the
    # composite typography token is not a CSS property.
    check "--sys-color-paper: #fbfaf7;" in css
    check "--sys-color-paper: #15161a;" in css
    check "--sys-typography-body" notin css
    check "<meta name=\"theme-color\" content=\"#15161a\" media=\"(prefers-color-scheme: dark)\" />" in essay
    # The theme's default configuration: three posts a page, no tag feeds.
    check fileExists(public / "posts/page/2/index.html")
    check not fileExists(public / "posts/page/3/index.html")
    check not fileExists(public / "tags/writing/atom.xml")
    # Zero JavaScript, as everywhere.
    check "<script src=" notin essay
    # The theme's required key: without author.name the build fails naming it.
    writeFile(root / "site.toml", readFile(root / "site.toml").replace(
      "author = { name = \"Example Author\", url = \"/about/\" }\n", ""))
    var message = ""
    try: discard buildSite(root)
    except BlogError as cause: message = cause.msg
    check "theme fixture-capabilities requires site.toml key author.name" in message

suite "the minimal theme: long code lines and wide tables":
  # The renderer makes every code block and table wrapper a focusable scroll
  # box; the theme scrolls them by default and wraps code with `wrap_code`.
  # The browser half (that they really scroll or wrap, and axe's
  # scrollable-region-focusable rule) is in `just test-theme-controls`.
  proc buildFixture(root, siteKeys: string): string =
    ## The conformance fixture, copied into the empty directory `root` and
    ## built with the shipped theme, `siteKeys` added as top-level site.toml
    ## keys; returns the output directory.
    copyDir(conformanceFixture, root / "site")
    writeFile(root / "site/site.toml", "theme = " & $(%(repoRoot / "themes/minimal")) & "\n" &
      siteKeys & readFile(root / "site/site.toml"))
    result = root / "public"
    discard buildSite(root / "site", BuildOptions(drafts: true, outDir: result, now: "@" & kitEpoch))

  test "code blocks and tables are focusable scroll boxes, and code scrolls by default":
    let root = createTempDir("isonim-blog-wide-content-", "")
    defer: removeDir(root)
    let public = buildFixture(root, "")
    var blocks, tables: int
    for page in ["posts/code-heavy/index.html", "posts/every-prose-feature/index.html"]:
      check htmlElements(public / page, "main")[0]["class"] == "site-main"
      let elements = htmlElements(public / page, "pre", "table", "div")
      for n, element in elements:
        if element["<tag>"] == "pre":
          inc blocks
          check element.getOrDefault("tabindex") == "0"
        elif element["<tag>"] == "table":
          inc tables
          let wrapper = elements[n - 1]
          check wrapper["<tag>"] == "div"
          check wrapper.getOrDefault("class") == "table-scroll"
          check wrapper.getOrDefault("role") == "region"
          check wrapper.getOrDefault("tabindex") == "0"
    # Vacuity guard: the fixture's long code lines and wide table are there.
    check blocks == 3
    check tables == 3
    let css = stylesheetText(public, "posts/code-heavy/index.html")
    check "white-space: pre;\n  overflow-wrap: normal;\n  overflow-x: auto;" in css
    check ".table-scroll {\n  max-width: 100%;\n  overflow-x: auto;\n}" in css
    check ".wrap-code pre {\n  white-space: pre-wrap;" in css

  test "every table region on a page has its own name, from its caption or heading":
    # A region landmark needs a name, and repeated ones need different
    # names (axe-core's landmark-unique; the browser half runs it in
    # `just test-theme`). Listing pages join the excerpts of several posts,
    # each rendered alone, so they are checked as well as the posts.
    let root = createTempDir("isonim-blog-table-names-", "")
    defer: removeDir(root)
    let public = buildFixture(root, "")
    proc regions(page: string): seq[string] =
      ## Each table region's name source, in document order:
      ## `label:<aria-label>` or `caption:<caption text>`; and a check that
      ## every aria-labelledby names exactly one element, a caption.
      let elements = htmlElements(public / page, "div", "caption", "table")
      let html = readFile(public / page)
      for element in elements:
        if element["<tag>"] != "div" or element.getOrDefault("class") != "table-scroll": continue
        check element.getOrDefault("role") == "region"
        if element.hasKey("aria-labelledby"):
          check not element.hasKey("aria-label")
          let id = element["aria-labelledby"]
          var targets = 0
          for other in elements:
            if other.getOrDefault("id") == id:
              inc targets
              check other["<tag>"] == "caption"
          check targets == 1
          check html.count("id=\"" & id & "\"") == 1
          let start = html.find("<caption id=\"" & id & "\">") + 15 + id.len
          result.add "caption:" & html[start ..< html.find("</caption>", start)]
        else:
          check element.getOrDefault("aria-label").len > 0
          result.add "label:" & element["aria-label"]
    var pages: seq[string]
    for file in walkDirRec(public):
      if file.endsWith(".html"): pages.add relativePath(file, public)
    var withTables = 0
    var listings: seq[string]
    for page in pages:
      let names = regions(page)
      if names.len > 0: inc withTables
      if names.len > 1 and page != "posts/every-prose-feature/index.html".replace('/', DirSep): listings.add page
      var seen: seq[string]
      for name in names:
        let key = name.split(':', 1)[1].toLowerAscii()
        if key in seen: checkpoint(page & " repeats the region name " & name)
        check key notin seen
        seen.add key
    check regions("posts/every-prose-feature/index.html") == @["label:Table",
      "caption:How three features are written", "label:Table: Table"]
    check regions("posts/pictures/index.html") == @["label:Table"]
    # The first page of the post list joins two excerpts with an uncaptioned
    # table before any heading, named "Table" on each post's own page. On
    # the listing each excerpt sits under its post's title, and is named
    # after it.
    check listings == @["posts" & DirSep & "index.html"]
    check sorted(regions(listings[0])) == @["label:Table: Every prose feature",
      "label:Table: Pictures and figures"]
    # Vacuity guard: the post pages and the listing were seen.
    check withTables == 3

  test "an excerpt printed beside its own post's content keeps its table names apart":
    # The capability theme's post layout prints the excerpt and the full
    # content on one page. An excerpt whose captioned table is also in the
    # content would repeat the caption's name there, unless the excerpt is
    # named apart from its own post's content.
    let root = createTempDir("isonim-blog-excerpt-names-", "")
    defer: removeDir(root)
    copyDir(conformanceFixture, root / "site")
    writeFile(root / "site/site.toml", "theme = " &
      $(%(repoRoot / "tests/fixtures/theme-capabilities")) & "\n" & readFile(root / "site/site.toml"))
    let post = root / "site/posts/2024-02-14-pictures/index.md"
    let source = readFile(post)
    check "| figure.svg | SVG    |\n\n<!--more-->" in source
    writeFile(post, source.replace("<!--more-->", "Table: Files in the bundle\n\n<!--more-->"))
    let public = root / "public"
    discard buildSite(root / "site", BuildOptions(drafts: true, outDir: public, now: "@" & kitEpoch))
    var names: seq[string]
    for element in htmlElements(public / "posts/pictures/index.html", "div"):
      if element.getOrDefault("class") != "table-scroll": continue
      names.add(if element.hasKey("aria-labelledby"): "caption " & element["aria-labelledby"]
                else: "label " & element.getOrDefault("aria-label"))
    # The excerpt (printed first) is numbered; the content keeps the caption.
    check names == @["label Files in the bundle (2)", "caption table_caption-1"]

  test "wrap_code = true marks the main element so code lines wrap":
    let root = createTempDir("isonim-blog-wide-content-", "")
    defer: removeDir(root)
    let public = buildFixture(root, "wrap_code = true\n")
    for page in ["posts/code-heavy/index.html", "index.html", "tags/writing/index.html"]:
      check htmlElements(public / page, "main")[0]["class"] == "site-main wrap-code"
    # Code blocks and tables keep their focusable markup either way.
    check htmlElements(public / "posts/code-heavy/index.html", "pre")[0]["tabindex"] == "0"

  test "wrap_code must be a boolean":
    let root = createTempDir("isonim-blog-wide-content-", "")
    defer: removeDir(root)
    var message = ""
    try: discard buildFixture(root, "wrap_code = \"yes\"\n")
    except BlogError as cause: message = cause.msg
    check "wrap_code must be a boolean" in message
