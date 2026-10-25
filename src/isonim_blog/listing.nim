## Building blocks for layouts of listing pages and post navigation, written
## with the `ui:` DSL. Layouts import this module to render the post list of
## a generated page, its pagination, previous/next links and a series table
## of contents; the built-in fallback layouts use the same procs.
##
## Every proc returns markup that escapes its text, so titles and terms from
## content files cannot inject markup.
import isonim/dsl/ui
import isonim/ssr/escape
import ./[model, archives]
export archives

proc postListHtml*(posts: openArray[Page]): string =
  ## An ordered list of posts: date and linked title, in the order given
  ## (generated pages pass them newest first, then by slug).
  let items = @posts
  ui:
    ol(class = "post-list"):
      for post in items:
        li(class = "post-list-item"):
          time(datetime = post.date): text post.date
          text " "
          a(href = post.url): text post.title

proc paginationHtml*(page: Page): string =
  ## Newer/older links between index pages; empty for a single page.
  if page.pageCount <= 1: return ""
  let label = "Page " & $page.pageNumber & " of " & $page.pageCount
  ui:
    nav(class = "pagination", `aria-label` = "Pagination"):
      if page.previousPageUrl.len > 0:
        a(href = page.previousPageUrl, rel = "prev"): text "Newer posts"
      span(class = "pagination-position"): text label
      if page.nextPageUrl.len > 0:
        a(href = page.nextPageUrl, rel = "next"): text "Older posts"

proc postNavigationHtml*(page: Page): string =
  ## Links to the older and the newer neighbouring post; empty when the
  ## post has neither.
  if page.previous.url.len == 0 and page.next.url.len == 0: return ""
  ui:
    nav(class = "post-navigation", `aria-label` = "Posts"):
      if page.previous.url.len > 0:
        a(href = page.previous.url, rel = "prev"): text "Previous: " & page.previous.title
      if page.next.url.len > 0:
        a(href = page.next.url, rel = "next"): text "Next: " & page.next.title

proc seriesNavigationHtml*(page: Page): string =
  ## The series this post belongs to, in reading order, with the current
  ## post marked; empty for a post outside a series.
  if page.seriesPosts.len == 0: return ""
  let entries = page.seriesPosts
  let current = page.url
  let heading = "Series: " & page.series
  ui:
    nav(class = "series-navigation", `aria-label` = "Series"):
      p: text heading
      ol:
        for entry in entries:
          if entry.url == current:
            li(class = "series-current", `aria-current` = "page"): text entry.title
          else:
            li:
              a(href = entry.url): text entry.title

proc defaultListLayout*(page: Page; site: Site; content: string): string =
  ## The structural fallback for generated pages when a site has no
  ## `index`, `tag`, `category` or `archive` layout.
  let list = postListHtml(page.listing)
  let pager = paginationHtml(page)
  ui:
    main:
      h1: text page.title
      raw list
      raw pager
