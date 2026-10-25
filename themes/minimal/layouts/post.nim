## A post: title, metadata, the draft notice, the hero image, the series it
## belongs to, the content and links to the neighbouring posts.
import isonim_blog/[model, listing]
import isonim/dsl/ui
import isonim/ssr/escape
import ../includes/minimal
const parent = "base"

proc layout*(page: Page; site: Site; content: string): string =
  let meta = postMeta(site, page)
  let series = seriesNavigationHtml(page)
  let neighbours = postNavigationHtml(page)
  let hero = pageAssetUrl(site, page, page.image)
  ui:
    article(class = "post"):
      header:
        h1: text page.title
        raw meta
      if page.draft:
        aside(class = "draft-banner", role = "note"): text "Draft preview: this post is not published."
      if hero.len > 0:
        figure(class = "post-hero"):
          img(src = hero, alt = page.imageAlt)
      raw series
      tdiv(class = "prose"):
        # Shared Markdown output is generated content, not authored structure.
        raw content
      raw neighbours
