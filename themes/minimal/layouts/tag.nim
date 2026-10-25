## A tag's page: its posts and, when generated, its own Atom feed.
import isonim_blog/[model, listing]
import isonim/dsl/ui
import isonim/ssr/escape
const parent = "base"

proc layout*(page: Page; site: Site; content: string): string =
  let list = postListHtml(page.listing)
  let feed = tagFeedUrl(site, page.term)
  ui:
    section(class = "term-page"):
      h1: text page.title
      if feed.len > 0:
        p(class = "feed-note"):
          a(href = feed, `type` = "application/atom+xml"): text "Atom feed of this tag"
      raw list
