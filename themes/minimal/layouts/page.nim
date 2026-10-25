## A standalone page or a collection entry.
import isonim_blog/model
import isonim/dsl/ui
import isonim/ssr/escape
const parent = "base"

proc layout*(page: Page; site: Site; content: string): string =
  ui:
    article(class = "page"):
      h1: text page.title
      if page.draft:
        aside(class = "draft-banner", role = "note"): text "Draft preview: this page is not published."
      tdiv(class = "prose"):
        # Shared Markdown output is generated content, not authored structure.
        raw content
