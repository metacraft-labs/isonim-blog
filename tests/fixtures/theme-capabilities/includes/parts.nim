## Shared parts: header, footer and the list body of generated pages.
import isonim_blog/[model, listing]
import isonim/dsl/ui
import isonim/ssr/escape

proc header*(site: Site): string =
  let home = site.config.basePath & "/"
  ui:
    header(class = "masthead"):
      a(href = home): text site.config.title

proc footer*(site: Site): string =
  let author = site.config.author.stringValue("name")
  ui:
    footer(class = "colophon"):
      p: text "By " & author

proc listingSection*(page: Page): string =
  let list = postListHtml(page.listing)
  let pager = paginationHtml(page)
  ui:
    section:
      h1: text page.title
      raw list
      raw pager
