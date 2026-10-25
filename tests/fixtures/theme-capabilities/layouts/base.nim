import isonim_blog/model
import isonim/dsl/ui
import isonim/ssr/escape
import ../includes/parts

proc layout*(page: Page; site: Site; content: string): string =
  let top = header(site)
  let bottom = footer(site)
  ui:
    # Scroll-driven animation: a reading-progress bar with no script.
    tdiv(class = "reading-progress", `aria-hidden` = "true")
    raw top
    main(id = "content"):
      raw content
    raw bottom
