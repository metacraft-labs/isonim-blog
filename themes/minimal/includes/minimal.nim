## Shared parts of the minimal theme's layouts: the site header and footer,
## post metadata and post summaries. Every proc escapes the text it is
## given (the `ui:` DSL's `text`), so content cannot inject markup.
import std/strutils
import isonim_blog/[model, listing]
import isonim/dsl/ui
import isonim/ssr/escape

type NavItem = tuple[title, url: string]

proc siteUrl*(site: Site; path: string): string =
  ## A site path (`/about/`) under the site's base path; other URLs as given.
  if path.startsWith("/") and not path.startsWith("//"): site.config.basePath & path
  else: path

proc navigationItems(site: Site): seq[NavItem] =
  ## `data/navigation.(toml|json)`: `items = [{ title, url }, ...]`. A site
  ## without that file has no navigation list; nothing is invented.
  if site.data.isNil or site.data.kind != JObject or not site.data.hasKey("navigation"): return
  let items = site.data["navigation"].getOrDefault("items")
  if items.isNil or items.kind != JArray: return
  for item in items:
    if item.kind == JObject and item.hasKey("title") and item.hasKey("url") and
        item["title"].kind == JString and item["url"].kind == JString:
      result.add (item["title"].getStr, siteUrl(site, item["url"].getStr))

proc siteHeader*(site: Site; page: Page): string =
  let home = site.config.basePath & "/"
  let items = navigationItems(site)
  let current = page.url
  ui:
    header(class = "site-header"):
      a(class = "site-title", href = home): text site.config.title
      if site.config.description.len > 0:
        p(class = "site-description"): text site.config.description
      if items.len > 0:
        nav(class = "site-nav", `aria-label` = "Site"):
          ul:
            for item in items:
              li:
                if item.url == current:
                  a(href = item.url, `aria-current` = "page"): text item.title
                else:
                  a(href = item.url): text item.title

proc siteFooter*(site: Site): string =
  let rss = if site.config.rssPath.len > 0: site.config.basePath & site.config.rssPath else: ""
  let atom = if site.config.atomPath.len > 0: site.config.basePath & site.config.atomPath else: ""
  let author = site.config.author.stringValue("name")
  let authorUrl = siteUrl(site, site.config.author.stringValue("url"))
  ui:
    footer(class = "site-footer"):
      if author.len > 0:
        p:
          text "Written by "
          if authorUrl.len > 0:
            a(href = authorUrl, rel = "author"): text author
          else:
            text author
      if rss.len > 0 or atom.len > 0:
        p(class = "feed-links"):
          text "Follow: "
          if rss.len > 0:
            a(href = rss, `type` = "application/rss+xml"): text "RSS feed"
          if atom.len > 0:
            a(href = atom, `type` = "application/atom+xml"): text "Atom feed"

proc termListHtml(label: string; terms: seq[tuple[name, url: string]]): string =
  ui:
    p:
      text label & ": "
      ul(class = "term-list"):
        for term in terms:
          li:
            if term.url.len > 0:
              a(href = term.url): text term.name
            else:
              text term.name

proc postMeta*(site: Site; page: Page): string =
  ## Date, update, tags and categories of a post, linked to their pages
  ## when those pages are generated.
  var tags, categories: seq[tuple[name, url: string]]
  for tag in page.tags: tags.add (termTitle(site, "tags", tag), tagUrl(site, tag))
  for category in page.categories:
    categories.add (termTitle(site, "categories", category), categoryUrl(site, category))
  let tagList = if tags.len > 0: termListHtml("Tags", tags) else: ""
  let categoryList = if categories.len > 0: termListHtml("Categories", categories) else: ""
  let updated = page.updated.len > 0 and page.updated != page.date
  ui:
    tdiv(class = "post-meta"):
      if page.date.len > 0:
        p:
          text "Published "
          time(datetime = page.date): text page.date
          if updated:
            text ", updated "
            time(datetime = page.updated): text page.updated
      raw tagList
      raw categoryList

proc postSummary*(post: Page): string =
  ## A post on a listing: linked title, date and excerpt.
  ui:
    article(class = "post-summary"):
      h2:
        a(href = post.url): text post.title
      if post.date.len > 0:
        time(datetime = post.date): text post.date
      tdiv(class = "prose"):
        # The excerpt is generated Markdown output, not authored structure.
        raw post.excerpt

proc wrapsCode*(site: Site): bool =
  ## `wrap_code = true` in site.toml: code lines wrap instead of scrolling
  ## inside their block. The theme's `[config]` defaults it to false; any
  ## value other than a boolean fails the build.
  if site.config.extra.isNil: false
  else: site.config.extra.boolValue("wrap_code")

proc mainClass*(site: Site): string =
  ## The main element's classes: `wrap-code` selects the opt-in wrapping.
  # `result` is set before the call that can raise. Written as one
  # `if`-expression, Nim 2.2.4 (ARC/ORC, debug and release builds) returns
  # an uninitialized string when `wrapsCode` raises; the caller then frees
  # it, and the site program crashed (SIGSEGV) instead of reporting the
  # invalid value.
  result = "site-main"
  if wrapsCode(site): result.add " wrap-code"
