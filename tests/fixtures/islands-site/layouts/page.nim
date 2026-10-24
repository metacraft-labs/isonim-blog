## Declares the island; `scripts = "islands"` turns it into one hashed bundle.
import isonim_blog/model
import isonim/dsl/ui
import isonim/ssr/escape
import ../includes/counter
const islands* = [Island(module: "includes/counter", selector: "#counter")]
proc layout*(page: Page; site: Site; content: string): string =
  ui:
    main:
      h1: text page.title
      tdiv(id = "counter"):
        raw counterHtml()
      raw content
