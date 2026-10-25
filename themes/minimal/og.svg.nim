## The minimal theme's OpenGraph card: the theme's dark surface and text
## colours, the site title, the page title in up to three lines and the
## date. The colours come from the theme's tokens, so a site that changes
## them changes its cards too.
import isonim_blog/[model, og]

proc tokenColor(site: Site; key, fallback: string): string =
  ## The token's dark-scheme value (its value when it has none).
  if site.theme.tokens.isNil or not site.theme.tokens.hasKey(key): return fallback
  let entry = site.theme.tokens[key]
  if entry.hasKey("dark"): entry["dark"].getStr else: entry["value"].getStr

proc ogImage*(page: Page; site: Site): string =
  let surface = tokenColor(site, "sys.color.surface", "#111316")
  let text = tokenColor(site, "sys.color.text", "#e7e9ec")
  let muted = tokenColor(site, "sys.color.text-muted", "#a9b0bb")
  let accent = tokenColor(site, "sys.color.link", "#9dbcff")
  let lines = wrapLines(page.title, 26, 3)
  result = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"1200\" height=\"630\" " &
    "viewBox=\"0 0 1200 630\"><rect width=\"1200\" height=\"630\" fill=\"" & svgText(surface) & "\"/>" &
    "<rect x=\"80\" y=\"96\" width=\"96\" height=\"8\" fill=\"" & svgText(accent) & "\"/>" &
    "<text x=\"80\" y=\"170\" font-family=\"DejaVu Sans\" font-size=\"34\" fill=\"" & svgText(muted) & "\">" &
    svgText(site.config.title) & "</text>"
  for i, line in lines:
    result.add "<text x=\"80\" y=\"" & $(290 + i * 84) & "\" font-family=\"DejaVu Sans\" " &
      "font-size=\"68\" font-weight=\"bold\" fill=\"" & svgText(text) & "\">" & svgText(line) & "</text>"
  if page.date.len > 0:
    result.add "<text x=\"80\" y=\"560\" font-family=\"DejaVu Sans\" font-size=\"30\" fill=\"" &
      svgText(muted) & "\">" & svgText(page.date) & "</text>"
  result.add "</svg>"
