## Backend-independent navigation over a loaded site: previous/next and
## series links on posts, the tag and category indexes, and the generated
## listing pages (the paginated post index, one page per tag and category,
## year and optional month archives).
##
## Every listing uses the site's one post order (`sortPages`: date
## descending, then slug, then source), so equal inputs give equal pages.
import std/[algorithm, strutils, tables]
import ./model

proc pageLink*(page: Page): PageLink =
  PageLink(title: page.title, url: page.url, date: page.date)

proc termRoute(site: Site; pattern, term: string): string =
  var slug: string
  try: slug = slugify(term)
  except BlogError: fail("the term '" & term & "' has no URL slug for " & pattern)
  cleanRoute(site.config.basePath & expandPattern(pattern, [("name", slug), ("slug", slug)]))

proc tagUrl*(site: Site; tag: string): string =
  ## The URL of a tag's page, or "" when tag pages are turned off.
  if site.config.tagPermalink.len == 0: "" else: termRoute(site, site.config.tagPermalink, tag)

proc categoryUrl*(site: Site; category: string): string =
  ## The URL of a category's page, or "" when category pages are turned off.
  if site.config.categoryPermalink.len == 0: ""
  else: termRoute(site, site.config.categoryPermalink, category)

proc tagFeedUrl*(site: Site; tag: string): string =
  ## The site path of a tag's Atom feed (`<tag page>atom.xml`), or "" when
  ## per-tag feeds, Atom or tag pages are turned off.
  if not site.config.perTagFeeds or site.config.atomPath.len == 0: return ""
  let page = tagUrl(site, tag)
  if page.len == 0 or not page.endsWith("/"): return ""
  page & "atom.xml"

proc termTitle*(site: Site; dataKey, term: string): string =
  ## A term's display title: `title` from `data/<tags|categories>.toml`
  ## when that file names one, otherwise the term itself.
  if site.data != nil and site.data.kind == JObject and site.data.hasKey(dataKey):
    let entry = site.data[dataKey].getOrDefault(term)
    if entry != nil and entry.kind == JObject and entry.hasKey("title") and
        entry["title"].kind == JString:
      return entry["title"].getStr
  term

proc seriesOrderCmp(a, b: Page): int =
  ## Reading order: explicit series_order first (ascending), then date and
  ## slug ascending for posts that do not give one.
  let ao = if a.seriesOrder > 0: a.seriesOrder else: high(int)
  let bo = if b.seriesOrder > 0: b.seriesOrder else: high(int)
  result = cmp(ao, bo)
  if result == 0: result = cmp(a.date, b.date)
  if result == 0: result = cmp(a.slug, b.slug)
  if result == 0: result = cmp(a.source, b.source)

proc sortedTerms(terms: Table[string, seq[Page]]): OrderedTable[string, seq[Page]] =
  var names: seq[string]
  for name in terms.keys: names.add name
  names.sort()
  result = initOrderedTable[string, seq[Page]]()
  for name in names: result[name] = terms[name]

proc linkNavigation*(site: var Site) =
  ## Fill previous/next and series links on `site.posts` (and the matching
  ## records in `site.pages`), and rebuild `site.tags` / `site.categories`.
  ## `site.posts` must already be in site order (`sortPages`).
  var series = initTable[string, seq[Page]]()
  for post in site.posts:
    if post.series.len > 0: series.mgetOrPut(post.series, @[]).add post
  var seriesLinks = initTable[string, seq[PageLink]]()
  for name, members in series.mpairs:
    members.sort(seriesOrderCmp)
    var links: seq[PageLink]
    for member in members: links.add pageLink(member)
    seriesLinks[name] = links
  var bySource = initTable[string, int]()
  for i, post in site.posts.mpairs:
    # Site order is newest first: the next (newer) post is the one before.
    post.next = if i > 0: pageLink(site.posts[i - 1]) else: PageLink()
    post.previous = if i + 1 < site.posts.len: pageLink(site.posts[i + 1]) else: PageLink()
    post.seriesPosts = if post.series.len > 0: seriesLinks[post.series] else: @[]
    bySource[post.source] = i
  for page in site.pages.mitems:
    if bySource.hasKey(page.source):
      let post = site.posts[bySource[page.source]]
      page.next = post.next
      page.previous = post.previous
      page.seriesPosts = post.seriesPosts
  var tags = initTable[string, seq[Page]]()
  var categories = initTable[string, seq[Page]]()
  for post in site.posts:
    for tag in post.tags: tags.mgetOrPut(tag, @[]).add post
    for category in post.categories: categories.mgetOrPut(category, @[]).add post
  site.tags = sortedTerms(tags)
  site.categories = sortedTerms(categories)

proc isPreview*(post: Page): bool =
  ## A post that exists only in a preview build: a draft (`--drafts`) or a
  ## post dated after the build date (`--future`).
  post.draft or post.future

proc newestUpdate(posts: openArray[Page]): string =
  ## The newest `updated` (or date) among the published posts. Previews do
  ## not count, so a preview build reports the value production will have.
  for post in posts:
    if post.isPreview: continue
    let value = if post.updated.len > 0: post.updated else: post.date
    if value > result: result = value

proc listsOnlyPreviews*(page: Page): bool =
  ## A generated page that lists posts, none of them published. It exists
  ## only because a preview build included drafts or future posts (a year
  ## archive of future posts, the last index page of a drafts build), so it
  ## stays out of the sitemap like the posts it lists.
  if page.kind == pkContent or page.listing.len == 0: return false
  for post in page.listing:
    if not post.isPreview: return false
  true

proc listingPage(kind: PageKind; layout, url, title, description, term, source: string;
    posts: seq[Page]): Page =
  Page(kind: kind, layout: layout, url: url, title: title, description: description,
    term: term, source: source, listing: posts, updated: newestUpdate(posts),
    output: true, pageNumber: 1, pageCount: 1)

proc generatedPages*(site: Site): seq[Page] =
  ## The listing pages for `site`, in a fixed order: index pages, tags,
  ## categories, years, months. Layout names: `index`, `tag`, `category`
  ## and `archive` (years and months; `kind` tells them apart). Drafts and
  ## future posts are listed only in builds that include them.
  let config = site.config
  if config.indexPermalink.len > 0:
    let first = cleanRoute(config.basePath & config.indexPermalink)
    let count = max(1, (site.posts.len + config.paginate - 1) div config.paginate)
    proc indexUrl(n: int): string =
      if n == 1: first
      else: cleanRoute((if first.endsWith("/"): first else: first & "/") & "page/" & $n & "/")
    for n in 1 .. count:
      let start = (n - 1) * config.paginate
      let stop = min(site.posts.len, start + config.paginate)
      var page = listingPage(pkIndex, "index", indexUrl(n),
        if n == 1: "Posts" else: "Posts, page " & $n,
        "Every post of " & config.title & (if n == 1: "" else: ", page " & $n), "",
        "generated post index page " & $n,
        if start < stop: site.posts[start ..< stop] else: @[])
      page.pageNumber = n
      page.pageCount = count
      if n > 1: page.previousPageUrl = indexUrl(n - 1)
      if n < count: page.nextPageUrl = indexUrl(n + 1)
      result.add page
  if config.tagPermalink.len > 0:
    for tag, posts in site.tags:
      let title = termTitle(site, "tags", tag)
      result.add listingPage(pkTag, "tag", tagUrl(site, tag), title,
        "Posts tagged " & title, tag, "generated tag page '" & tag & "'", posts)
  if config.categoryPermalink.len > 0:
    for category, posts in site.categories:
      let title = termTitle(site, "categories", category)
      result.add listingPage(pkCategory, "category", categoryUrl(site, category), title,
        "Posts in " & title, category, "generated category page '" & category & "'", posts)
  for (kind, pattern, width) in [(pkYear, config.yearPermalink, 4), (pkMonth, config.monthPermalink, 7)]:
    if pattern.len == 0: continue
    var groups = initOrderedTable[string, seq[Page]]()
    for post in site.posts:
      if post.date.len >= width: groups.mgetOrPut(post.date[0 ..< width], @[]).add post
    var keys: seq[string]
    for key in groups.keys: keys.add key
    keys.sort(Descending)
    for key in keys:
      let url = cleanRoute(config.basePath & expandPattern(pattern,
        [("year", key[0 .. 3]), ("month", if width == 7: key[5 .. 6] else: "")]))
      result.add listingPage(kind, "archive", url, key, "Posts from " & key, key,
        "generated " & (if kind == pkYear: "year" else: "month") & " archive " & key, groups[key])
