import isonim_blog/model
import isonim/dsl/ui
import isonim/ssr/escape
const parent = "base"

proc layout*(page: Page; site: Site; content: string): string =
  ui:
    article(class = "page"):
      h1: text page.title
      raw content
