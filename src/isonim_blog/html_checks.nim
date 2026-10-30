## Blog output policy checks: complete script elements, including inert data,
## `<style>` elements, which the generated Content-Security-Policy allows by
## their hashes, and style attributes, which it blocks.
## The framework's executable-script scanner intentionally has a wider data
## exemption; blog pages allow only JSON-LD plus explicitly declared scripts.
import std/[htmlparser, xmltree, strutils, strtabs]
export xmltree

proc scriptElements*(html: string): seq[XmlNode] =
  let document = parseHtml(html)
  var pending = @[document]
  while pending.len > 0:
    let node = pending.pop()
    if node.kind != xnElement: continue
    if node.tag.toLowerAscii == "script": result.add node
    for child in node: pending.add child

type
  StyleElement* = object
    ## One `<style>` element of a page, as `styleElements` found it.
    body*: string
      ## The exact text between its start and end tags.
    foreign*: bool
      ## Inside inline `<svg>` or `<math>`, where the HTML parser treats the
      ## text as markup (character references, CDATA) instead of raw text.

proc tagEnd(html: string; start: int): int =
  ## The index of the `>` that ends the tag whose attributes start at
  ## `start` (a `>` inside a quoted attribute value does not), or -1.
  var quote = '\0'
  for i in start ..< html.len:
    let c = html[i]
    if quote != '\0':
      if c == quote: quote = '\0'
    elif c in {'"', '\''}: quote = c
    elif c == '>': return i
  -1

proc endTag(html, lower, name: string; start: int): int =
  ## The index of the first `</name` at or after `start` that ends a raw-text
  ## element: compared without case and followed by whitespace, `/` or `>`
  ## (https://html.spec.whatwg.org/multipage/parsing.html#appropriate-end-tag-token).
  ## -1 when the element runs to the end of the document.
  var at = start
  while true:
    at = lower.find("</" & name, at)
    if at < 0: return -1
    let after = at + 2 + name.len
    if after < html.len and html[after] in {'\t', '\n', '\f', '\r', ' ', '/', '>'}: return at
    at = after

proc styleElements*(html: string): tuple[styles: seq[StyleElement], rest: string] =
  ## Every `<style>` element of a built page with its exact text, as the
  ## browser's tokenizer delimits it (a `<style>` element is raw text up to
  ## `</style`), which is what a CSP hash source must match
  ## (https://www.w3.org/TR/CSP3/#match-element-to-source-list). `rest` is
  ## the page without those elements, for the other checks. Comments and
  ## script contents are skipped, so `<style>` written inside them is not an
  ## element. A tolerant scanner, not a parser: built pages are the output
  ## of the renderer and layouts, and a `<style>` it missed would only be
  ## blocked by the browser (and reported by `inlineStyles` on `rest`).
  let lower = html.toLowerAscii
  var foreignDepth = 0
  var i = 0
  var copied = 0
  while i < html.len:
    if html[i] != '<':
      inc i
      continue
    if html.continuesWith("<!--", i):
      let stop = html.find("-->", i + 4)
      if stop < 0: break
      i = stop + 3
      continue
    let closing = i + 1 < html.len and html[i + 1] == '/'
    let nameStart = i + (if closing: 2 else: 1)
    var nameEnd = nameStart
    while nameEnd < html.len and html[nameEnd] in {'a'..'z', 'A'..'Z', '0'..'9', '-', ':'}: inc nameEnd
    if nameEnd == nameStart or html[nameStart] notin Letters:
      inc i
      continue
    let name = lower[nameStart ..< nameEnd]
    let stop = tagEnd(html, nameEnd)
    if stop < 0: break
    let selfClosing = html[stop - 1] == '/'
    if name in ["svg", "math"]:
      if closing: foreignDepth = max(foreignDepth - 1, 0)
      elif not selfClosing: inc foreignDepth
      i = stop + 1
    elif not closing and name == "script":
      let ending = endTag(html, lower, "script", stop + 1)
      i = if ending < 0: html.len else: ending
    elif not closing and name == "style":
      let foreign = foreignDepth > 0
      result.rest.add html[copied ..< i]
      if foreign and selfClosing:
        # `<style/>` in SVG is an empty element; in HTML it is a start tag.
        result.styles.add StyleElement(body: "", foreign: true)
        i = stop + 1
      else:
        let ending = endTag(html, lower, "style", stop + 1)
        if ending < 0:
          result.styles.add StyleElement(body: html[stop + 1 .. ^1], foreign: foreign)
          i = html.len
        else:
          result.styles.add StyleElement(body: html[stop + 1 ..< ending], foreign: foreign)
          let close = tagEnd(html, ending + 2)
          i = if close < 0: html.len else: close + 1
      copied = i
    else:
      i = stop + 1
  result.rest.add html[min(copied, html.len) .. ^1]

proc inlineStyles*(html: string): seq[string] =
  ## Every place a page carries inline CSS, in document order: a `<style>`
  ## element (`"<style> element"`) or a `style` attribute (`"<p style>"`).
  ## A Content-Security-Policy whose `style-src` lacks `'unsafe-inline'`
  ## blocks both (https://www.w3.org/TR/CSP3/#directive-style-src), and a
  ## style attribute cannot be allowed by a hash without `'unsafe-hashes'`.
  ## Inline `<svg>` content counts too: its style attributes are governed by
  ## the page's policy. The build runs it on a page without the `<style>`
  ## elements `styleElements` found, whose hashes the policy carries.
  var pending = @[parseHtml(html)]
  var found: seq[string]
  while pending.len > 0:
    let node = pending.pop()
    if node.kind != xnElement: continue
    let name = node.tag.toLowerAscii
    if name == "style": found.add "<style> element"
    if node.attrs != nil:
      for key, _ in node.attrs.pairs:
        if key.toLowerAscii == "style":
          found.add "<" & name & " style>"
          break
    for i in countdown(node.len - 1, 0): pending.add node[i]
  found
