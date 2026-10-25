## OpenGraph image templates. A template is a proc returning the SVG of a
## page's 1200x630 card; the build renders it to PNG (with resvg and the
## bundled fonts, `isonim/static/ogimage`) for every page that sets no
## `og_image`. A theme or site supplies its own as `og.svg.nim`, a module
## exporting `proc ogImage*(page: Page; site: Site): string`; otherwise the
## generic card below is used.
##
## SVG has no automatic line wrapping, so `wrapLines` breaks a title into
## lines a template can place; the text is escaped with `svgText`.
## Backend-independent.
import std/[strutils, unicode]
import isonim/static/urls
import ./model

proc svgText*(text: string): string =
  ## `text` escaped for SVG character data or an attribute value.
  xmlEscape(text)

proc runePrefix(text: string; count: int): string =
  let runes = text.toRunes
  $runes[0 ..< min(count, runes.len)]

proc wrapLines*(text: string; maxChars, maxLines: int): seq[string] =
  ## Words of `text` filled into lines of at most `maxChars` characters
  ## (Unicode code points), at most `maxLines` of them. Text that does not
  ## fit ends in an ellipsis; a single word longer than a line is cut.
  var line = ""
  var lineRunes = 0
  var truncated = false
  for word in strutils.splitWhitespace(text):
    let wordRunes = word.runeLen
    if lineRunes > 0 and lineRunes + 1 + wordRunes <= maxChars:
      line.add " " & word
      lineRunes += 1 + wordRunes
      continue
    if lineRunes > 0:
      result.add line
      if result.len == maxLines:
        truncated = true
        break
    line = word
    lineRunes = wordRunes
    if lineRunes > maxChars:
      line = runePrefix(line, maxChars - 1) & "…"
      lineRunes = maxChars
  if not truncated and lineRunes > 0:
    if result.len < maxLines: result.add line
    else: truncated = true
  if truncated and result.len > 0 and not result[^1].endsWith("…"):
    var last = result[^1]
    if last.runeLen >= maxChars: last = runePrefix(last, maxChars - 1)
    result[^1] = last & "…"

proc defaultOgImage*(page: Page; site: Site): string =
  ## The generic card: the site title, the page title in up to three lines,
  ## and the post date, light on dark, in the bundled DejaVu Sans.
  let lines = wrapLines(page.title, 26, 3)
  result = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1200\" height=\"630\" " &
    "viewBox=\"0 0 1200 630\"><rect width=\"1200\" height=\"630\" fill=\"#16181d\"/>" &
    "<rect x=\"80\" y=\"96\" width=\"96\" height=\"8\" fill=\"#7aa2f7\"/>" &
    "<text x=\"80\" y=\"170\" font-family=\"DejaVu Sans\" font-size=\"34\" fill=\"#a9b1c6\">" &
    svgText(site.config.title) & "</text>"
  for i, line in lines:
    result.add "<text x=\"80\" y=\"" & $(290 + i * 84) & "\" font-family=\"DejaVu Sans\" " &
      "font-size=\"68\" font-weight=\"bold\" fill=\"#ffffff\">" & svgText(line) & "</text>"
  if page.date.len > 0:
    result.add "<text x=\"80\" y=\"560\" font-family=\"DejaVu Sans\" font-size=\"30\" " &
      "fill=\"#a9b1c6\">" & svgText(page.date) & "</text>"
  result.add "</svg>"
