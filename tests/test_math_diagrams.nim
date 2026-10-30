## Maths and diagrams rendered at build time, end to end through the real
## site program: `[markdown] math` renders `$…$`, `$$…$$` and fenced `math`
## to MathML with the KaTeX the environment injects (`ISONIM_BLOG_KATEX`),
## and `[markdown] diagrams` renders the listed fence languages to inline SVG
## with D2 and Graphviz (`ISONIM_BLOG_D2`, `ISONIM_BLOG_DOT`). The output
## carries no `style` attribute; each generated `<style>` element is allowed
## by its hash in the page's Content-Security-Policy. Errors name the file
## and the line.
##
## Real compiler, real KaTeX, D2 and Graphviz (the dev shell and the package
## build provide them), real filesystem; no test doubles. Whether a browser
## lays the output out under the policy is the theme conformance kit's
## check (`just test-theme`), which needs Chromium.
import std/[unittest, sequtils]
import isonim_blog/model
import isonim_blog/html_checks
import isonim/static/csp
import ./site_helpers

for variable in ["ISONIM_BLOG_KATEX", "ISONIM_BLOG_D2", "ISONIM_BLOG_DOT"]:
  doAssert getEnv(variable).len > 0, variable & " is not set; run the suite in nix develop"

const
  postSource = "posts/2020-04-04-formulas.md"
  post = """---
title: Formulas
description: Maths and diagrams
---

Inline maths $a^2 + b^2 = c^2$ in a sentence.

$$
\frac{n(n+1)}{2}
$$

```math
e^{i\pi} + 1 = 0
```

```d2
draft -> post: publish
```

```dot
digraph { post -> feed }
```
"""
  enabled = "\n[markdown]\nmath = true\ndiagrams = [\"d2\", \"dot\"]\n"

proc site(): tuple[root, binary: string] =
  ## A copy of the generic example site with the formulas post, compiled.
  let root = fixtureCopy()
  writeFile(root / postSource, post)
  (root, compileSite(root))

proc enable(root: string; markdown = enabled) =
  writeFile(root / "site.toml", readFile(root / "site.toml").replace("[collections.notes]",
    markdown & "[collections.notes]"))

proc pageFile(output: string): string =
  ## The built page of the formulas post, wherever its permalink put it.
  for file in walkDirRec(output):
    if file.endsWith("index.html") and "/formulas/" in file: return file
  doAssert false, "no page for the formulas post in " & output

proc policyOf(headers, route: string): string =
  ## The Content-Security-Policy `_headers` gives `route`.
  const field = "\n  Content-Security-Policy: "
  let at = headers.find(route & field)
  doAssert at >= 0, "no _headers rule for " & route
  headers[at + route.len + field.len .. ^1].splitLines()[0].strip()

proc buildError(binary, root, output: string): string =
  try:
    discard runSite(binary, root, output)
  except BlogError as cause:
    return cause.msg
  "the build succeeded"

suite "maths and diagrams at build time":
  test "they render to MathML and inline SVG, with no inline CSS, allowed by hash":
    let (root, binary) = site()
    defer: removeDir(root)
    enable(root)
    let output = root / "public"
    discard runSite(binary, root, output, @["--diagram-cache", root / "build/diagrams"])
    let page = readFile(pageFile(output))
    # Three formulas, the display ones as blocks, one with a fraction.
    check page.count("<math ") == 3
    check page.count("<math display=\"block\"") == 2
    check "<mfrac>" in page
    check "$" notin page.replace("$$", "")
    check "language-math" notin page
    # A D2 and a Graphviz diagram, with their labels as SVG text.
    check page.count("class=\"isonim-diagram\"") == 2
    check "class=\"d2-" in page
    for label in [">publish</text>", ">draft</text>", ">feed</text>"]: check label in page
    check "language-d2" notin page and "language-dot" notin page
    # No style attribute anywhere; every <style> element is in the page's
    # policy by its hash, and the policy allows nothing inline otherwise.
    let (styles, rest) = styleElements(page)
    check inlineStyles(rest).len == 0
    check styles.len >= 2
    check styles.allIt(it.foreign)
    let route = "/" & relativePath(pageFile(output).parentDir, output).replace('\\', '/') & "/"
    let policy = policyOf(readFile(output / "_headers"), route)
    for element in styles: check cspHashSource(element.body) in policy
    check "'unsafe-inline'" notin policy
    check "'unsafe-hashes'" notin policy
    check policy.startsWith("default-src 'none'; script-src 'none'; style-src 'self' 'sha256-")
    # Other pages keep the plain policy.
    check "style-src 'self'; img-src" in policyOf(readFile(output / "_headers"), "/about/")

  test "they are off by default: dollars and diagram fences stay text":
    let (root, binary) = site()
    defer: removeDir(root)
    let output = root / "public"
    discard runSite(binary, root, output)
    let page = readFile(pageFile(output))
    check "<math" notin page
    check "isonim-diagram" notin page
    check "$a^2 + b^2 = c^2$" in page
    check "class=\"language-d2\"" in page
    check "class=\"language-dot\"" in page

  test "a diagram cache is reused and changes nothing":
    let (root, binary) = site()
    defer: removeDir(root)
    enable(root)
    let cache = root / "build/diagrams"
    discard runSite(binary, root, root / "first", @["--diagram-cache", cache])
    var entries = toSeq(walkFiles(cache / "*.svg"))
    check entries.len == 2
    discard runSite(binary, root, root / "second", @["--diagram-cache", cache])
    check toSeq(walkFiles(cache / "*.svg")) == entries
    # Without a cache directory (as in the Nix sandbox) the build caches in
    # a directory of its own, and the output is the same bytes.
    discard runSite(binary, root, root / "third")
    let first = readFile(pageFile(root / "first"))
    check first == readFile(pageFile(root / "second"))
    check first == readFile(pageFile(root / "third"))

  test "an invalid formula fails the build naming the file and the line":
    let (root, binary) = site()
    defer: removeDir(root)
    enable(root)
    # The error names the display formula's opening `$$`, on line 8 of the
    # file (front matter included).
    writeFile(root / postSource, post.replace("\\frac{n(n+1)}{2}", "\\frac{n(n+1)}{2"))
    let message = buildError(binary, root, root / "public")
    check message.contains(postSource & ":8: KaTeX exited with status")
    check not dirExists(root / "public")

  test "a renderer that is not injected fails naming its variable":
    let (root, binary) = site()
    let saved = ["ISONIM_BLOG_KATEX", "ISONIM_BLOG_D2", "ISONIM_BLOG_DOT"].mapIt((it, getEnv(it)))
    defer:
      for (variable, value) in saved: putEnv(variable, value)
      removeDir(root)
    enable(root)
    for (variable, tool, line) in [("ISONIM_BLOG_KATEX", "KaTeX", 6), ("ISONIM_BLOG_D2", "D2", 16),
        ("ISONIM_BLOG_DOT", "Graphviz", 20)]:
      checkpoint variable
      for (name, value) in saved: putEnv(name, value)
      delEnv(variable)
      let message = buildError(binary, root, root / "public")
      check message.contains(postSource & ":" & $line & ": " & tool & " not configured (" & variable &
        " is not set: enter nix develop or use the packaged CLI)")
    # A site without maths or diagrams needs none of them.
    writeFile(root / postSource, "---\ntitle: Formulas\n---\n\nNo formulas here.\n")
    for (variable, value) in saved: delEnv(variable)
    check buildError(binary, root, root / "public") == "the build succeeded"

  test "a diagram language the site does not list fails naming it":
    let (root, binary) = site()
    defer: removeDir(root)
    enable(root, "\n[markdown]\ndiagrams = [\"dot\"]\n")
    let message = buildError(binary, root, root / "public")
    check message.contains(postSource & ":16: a d2 diagram, but [markdown] diagrams in site.toml " &
      "lists only dot; add d2 to it")
