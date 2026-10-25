## A year or month archive: its posts.
import isonim_blog/[model, listing]
import isonim/dsl/ui
import isonim/ssr/escape
const parent = "base"

proc layout*(page: Page; site: Site; content: string): string =
  let list = postListHtml(page.listing)
  ui:
    section(class = "archive-page"):
      h1: text page.title
      raw list
