import isonim_blog/[model, listing]
import isonim/dsl/ui
import isonim/ssr/escape
const parent = "base"
proc layout*(page: Page; site: Site; content: string): string =
  let series = seriesNavigationHtml(page)
  let neighbours = postNavigationHtml(page)
  ui:
    article:
      h1: text page.title
      if page.draft:
        aside(class = "draft-banner", role = "status"): text "Draft preview"
      raw series
      # Shared Markdown output is generated content, not authored structure.
      raw content
      raw neighbours
