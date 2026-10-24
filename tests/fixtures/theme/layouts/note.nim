## A theme layout the example site does not define; it must compile with it.
import isonim_blog/model
import isonim/dsl/ui
import isonim/ssr/escape
const parent = "base"
proc layout*(page: Page; site: Site; content: string): string =
  ui:
    article(class = "theme-note"):
      h1: text page.title
      raw content
