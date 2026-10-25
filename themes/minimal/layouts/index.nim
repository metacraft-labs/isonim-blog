## The paginated post index: a summary of each post, then the pages.
import isonim_blog/[model, listing]
import isonim/dsl/ui
import isonim/ssr/escape
import ../includes/minimal
const parent = "base"

proc layout*(page: Page; site: Site; content: string): string =
  var summaries = ""
  for post in page.listing: summaries.add postSummary(post)
  let pager = paginationHtml(page)
  let heading = if page.pageCount > 1: page.title & " (page " & $page.pageNumber & " of " & $page.pageCount & ")"
    else: page.title
  ui:
    section(class = "post-index"):
      h1: text heading
      raw summaries
      raw pager
