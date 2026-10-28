## Controls for the theme conformance kit (`just test-theme-controls`): the
## real kit executable (`build/bin/theme-kit`, as `just test-theme` builds
## it), run on copies of the shipped theme with one defect each, must fail
## naming that defect; the unmodified copy must pass. Without these, a kit
## whose browser half silently checked nothing would look like a pass.
##
## Defects: low text contrast in the light scheme only, then in the dark
## scheme only (both schemes are checked, and separately); a header wider
## than a 360px screen; a layout that emits a script; a missing post layout;
## a table that scrolls without the renderer's focusable wrapper.
##
## The shipped theme's handling of wide content is checked here too, in the
## browser: by default the fixture's long code lines and wide tables scroll
## inside their own (focusable) boxes, and with `wrap_code = true` code
## wraps while tables still scroll. axe passing on a theme that merely
## wrapped everything would prove nothing about scroll boxes, so the counts
## the kit reports are asserted, not only its verdict.
## No test doubles: real Chromium, real axe-core, real builds.
import std/[os, osproc, strutils, tempfiles]

const repoRoot = currentSourcePath().parentDir.parentDir
let kit = repoRoot / "build/bin/theme-kit"

var failures = 0

proc scrollCount(output, name: string): int =
  ## How many `name` boxes the kit's summary reports scrolling sideways at
  ## 360px (0 when it names none); -1 when the summary is missing.
  const marker = "boxes scrolling sideways at 360px: "
  let at = output.find(marker)
  if at < 0: return -1
  for entry in output[at + marker.len .. ^1].splitLines()[0].split(", "):
    let space = entry.rfind(' ')
    if space > 0 and entry[0 ..< space] == name: return parseInt(entry[space + 1 .. ^1])

proc control(name: string; mutate: proc(theme: string); expectPass: bool;
    present: openArray[string] = []; absent: openArray[string] = [];
    inspect: proc(output: string): seq[string] = nil) =
  let work = createTempDir("isonim-blog-kit-control-", "")
  let theme = work / "theme"
  copyDir(repoRoot / "themes/minimal", theme)
  mutate(theme)
  let (output, code) = execCmdEx(quoteShellCommand([kit, theme]))
  var problems: seq[string]
  if (code == 0) != expectPass:
    problems.add "exit " & $code & ", expected " & (if expectPass: "0" else: "1")
  for text in present:
    if text notin output: problems.add "missing from the report: " & text
  for text in absent:
    if text in output: problems.add "unexpected in the report: " & text
  if inspect != nil: problems.add inspect(output)
  if problems.len == 0:
    echo "  [OK] ", name
    removeDir(work)
  else:
    inc failures
    echo "  [FAILED] ", name
    for problem in problems: echo "    ", problem
    echo output.indent(6)

proc replaceIn(path, old, new: string) =
  let content = readFile(path)
  doAssert old in content, path & " does not contain " & old
  writeFile(path, content.replace(old, new))

doAssert fileExists(kit), "build the kit first: just test-theme-controls does"
echo "Theme conformance kit controls"
control("positive control: the unmodified copy conforms", proc(theme: string) = discard,
  expectPass = true, present = ["PASS WCAG 2.2 AA", "axe runs over", "The theme conforms."])
control("light-scheme contrast below 4.5:1 fails in the light scheme only", proc(theme: string) =
  replaceIn(theme / "tokens.json", "\"gray-650\": { \"$value\": \"#525a67\" }",
    "\"gray-650\": { \"$value\": \"#a3a9b2\" }"),
  expectPass = false, present = ["FAIL WCAG 2.2 AA", "(light, 360px): axe color-contrast"],
  absent = ["(dark, 360px): axe color-contrast"])
control("dark-scheme contrast below 4.5:1 fails in the dark scheme only", proc(theme: string) =
  replaceIn(theme / "tokens.json", "\"night-300\": { \"$value\": \"#a9b0bb\" }",
    "\"night-300\": { \"$value\": \"#4b515b\" }"),
  expectPass = false, present = ["FAIL WCAG 2.2 AA", "(dark, 360px): axe color-contrast"],
  absent = ["(light, 360px): axe color-contrast"])
control("a header wider than 360px scrolls the page sideways", proc(theme: string) =
  let css = theme / "assets/minimal.css"
  writeFile(css, readFile(css) & "\n.site-header { min-width: 480px; }\n"),
  expectPass = false, present = ["(light, 360px): scrolls horizontally by", "header.site-header"])
control("a layout that emits a script fails the build", proc(theme: string) =
  replaceIn(theme / "layouts/base.nim", "    raw footer\n",
    "    raw footer\n    raw \"<script src=\\\"/tracker.js\\\"></script>\"\n"),
  expectPass = false, present = ["FAIL the fixture builds with the theme", "undeclared script"])
control("by default, long code lines and wide tables scroll in focusable boxes", proc(theme: string) = discard,
  expectPass = true, present = ["PASS WCAG 2.2 AA"], absent = ["scrollable-region-focusable"],
  inspect = proc(output: string): seq[string] =
    # The fixture has two code blocks and one table wider than 360px
    # (posts/code-heavy, posts/every-prose-feature).
    if scrollCount(output, "pre") < 2: result.add "code blocks scrolling: " & $scrollCount(output, "pre")
    if scrollCount(output, "div.table-scroll") < 1:
      result.add "tables scrolling: " & $scrollCount(output, "div.table-scroll"))
control("wrap_code = true wraps code lines; wide tables still scroll", proc(theme: string) =
  replaceIn(theme / "theme.toml", "wrap_code = false", "wrap_code = true"),
  expectPass = true, present = ["PASS WCAG 2.2 AA"],
  inspect = proc(output: string): seq[string] =
    if scrollCount(output, "pre") != 0: result.add "code blocks scrolling: " & $scrollCount(output, "pre")
    if scrollCount(output, "div.table-scroll") < 1:
      result.add "tables scrolling: " & $scrollCount(output, "div.table-scroll"))
control("a table that scrolls itself, outside the focusable wrapper, fails axe", proc(theme: string) =
  let css = theme / "assets/minimal.css"
  writeFile(css, readFile(css) & "\n.prose table { display: block; overflow-x: auto; }\n"),
  expectPass = false, present = ["(light, 360px): axe scrollable-region-focusable", "> table): Scrollable region must have keyboard access"])
control("a theme without a post layout fails naming it", proc(theme: string) =
  removeFile(theme / "layouts/post.nim"),
  expectPass = false, present = ["FAIL required layouts", "missing layouts/post.nim"])
if failures > 0:
  echo failures, " control(s) failed"
  quit(1)
echo "All controls behaved as expected."
