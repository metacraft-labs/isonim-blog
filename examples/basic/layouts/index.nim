## The paginated post index: excerpts, then links between index pages.
import isonim_blog/[model, listing]
import isonim/dsl/ui
import isonim/ssr/escape
const parent = "base"
proc layout*(page: Page; site: Site; content: string): string =
  let posts = page.listing
  let pager = paginationHtml(page)
  ui:
    section(class = "post-index"):
      h1: text page.title
      for post in posts:
        article(class = "post-summary"):
          h2(class = "post-title"):
            a(href = post.url): text post.title
          # The excerpt is generated Markdown output, not authored structure.
          raw post.excerpt
      raw pager
