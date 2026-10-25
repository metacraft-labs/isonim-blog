## Generated listing pages end to end: the generic fixture site is loaded,
## its real layout program is compiled with the real Nim compiler and run
## over the content, and the written HTML is parsed. No test doubles.
##
## The expected post orders below are written out by hand from the fixture's
## dates and slugs (an independent oracle), not computed with the code under
## test.
import std/[unittest, json, sequtils, tables, htmlparser]
import isonim_blog/[model, html_checks]
import ./site_helpers

proc hasClass(node: XmlNode; name: string): bool =
  node.kind == xnElement and name in node.attr("class").split(' ')

proc linksUnder(node: XmlNode; container: string; inside = false; into: var seq[string]) =
  ## The `href` of every `<a>` inside an element with class `container`,
  ## in document order.
  if node.kind != xnElement: return
  let within = inside or node.hasClass(container)
  if within and node.tag == "a": into.add node.attr("href")
  for child in node: linksUnder(child, container, within, into)

proc listed(output, route, container: string): seq[string] =
  ## The posts a written page lists, as slugs (`/posts/<slug>/`).
  let file = output / outputPath(route)
  check fileExists(file)
  if not fileExists(file): return
  var links: seq[string]
  linksUnder(parseHtml(readFile(file)), container, false, links)
  for link in links:
    check link.startsWith("/posts/") and link.endsWith("/")
    result.add link[7 .. ^2]

proc relLinks(output, route: string): Table[string, string] =
  ## `rel` -> `href` of the links of a page's pagination or post navigation.
  result = initTable[string, string]()
  var pending = @[parseHtml(readFile(output / outputPath(route)))]
  while pending.len > 0:
    let node = pending.pop()
    if node.kind != xnElement: continue
    if node.tag == "a" and node.attr("rel").len > 0: result[node.attr("rel")] = node.attr("href")
    for child in node: pending.add child

proc fixedEpoch() = putEnv("SOURCE_DATE_EPOCH", "1704067200")

suite "collections, taxonomies, archives and pagination":
  test "tag, category, archive and index pages list exactly the expected posts in date-then-slug order":
    let root = fixtureCopy()
    defer: removeDir(root)
    fixedEpoch()
    defer: delEnv("SOURCE_DATE_EPOCH")
    # Month archives are opt-in; turn them on to cover them too.
    writeFile(root / "site.toml", readFile(root / "site.toml") & "[archives]\nmonth = \"/:year/:month/\"\n")
    let site = loadSite(root)
    # Vacuity guard: at least two tags, two years and more than one index page,
    # and a same-date pair so the slug tie-break is exercised.
    check site.tags.len >= 2
    check site.posts.mapIt(it.date[0 .. 3]).deduplicate.len >= 2
    check site.posts.len > site.config.paginate
    check site.posts.filterIt(it.date == "2021-05-05").len == 2
    # Layouts receive the term indexes, each in byte order of term and site
    # order of posts.
    check toSeq(site.tags.keys) == @["nim", "web"]
    check site.tags["nim"].mapIt(it.slug) == @["third", "second", "first"]
    check toSeq(site.categories.keys) == @["media", "notes"]
    let binary = compileSite(root)
    let output = root / "public"
    discard runSite(binary, root, output)
    # The paginated index (the fixture's own `index` layout).
    check listed(output, "/posts/", "post-title") == @["another", "third"]
    check listed(output, "/posts/page/2/", "post-title") == @["bundle", "second"]
    check listed(output, "/posts/page/3/", "post-title") == @["first"]
    check not fileExists(output / "posts/page/4/index.html")
    check not fileExists(output / "posts/page/1/index.html")
    # Excerpts link to fingerprinted bundle resources, like full posts.
    let figure = parseFile(output / "asset-manifest.json")["posts/2020-03-03-bundle/figure.svg"].getStr
    let secondIndex = readFile(output / "posts/page/2/index.html")
    check secondIndex.contains("href=\"/" & figure & "\"")
    check not secondIndex.contains("figure.svg\"")
    check relLinks(output, "/posts/") == {"next": "/posts/page/2/"}.toTable
    check relLinks(output, "/posts/page/2/") == {"prev": "/posts/", "next": "/posts/page/3/"}.toTable
    check relLinks(output, "/posts/page/3/") == {"prev": "/posts/page/2/"}.toTable
    # Terms and archives (the built-in list layout).
    check listed(output, "/tags/nim/", "post-list") == @["third", "second", "first"]
    check listed(output, "/tags/web/", "post-list") == @["another", "bundle", "second"]
    check listed(output, "/categories/notes/", "post-list") == @["another", "third", "second", "first"]
    check listed(output, "/categories/media/", "post-list") == @["bundle"]
    check listed(output, "/2021/", "post-list") == @["another", "third"]
    check listed(output, "/2020/", "post-list") == @["bundle", "second", "first"]
    check listed(output, "/2021/05/", "post-list") == @["another", "third"]
    check listed(output, "/2020/02/", "post-list") == @["second"]
    check listed(output, "/2020/03/", "post-list") == @["bundle"]
    # Exactly these listing pages exist: nothing for an absent term or year.
    var listings: seq[string]
    for file in inputFiles(output):
      let rel = relativePath(file, output)
      if rel.endsWith("index.html") and not rel.startsWith("posts/") and
          rel.split('/')[0] in ["tags", "categories", "2020", "2021", "2099"]:
        listings.add rel
    check listings == @["2020/01/index.html", "2020/02/index.html", "2020/03/index.html",
      "2020/index.html", "2021/05/index.html", "2021/index.html",
      "categories/media/index.html", "categories/notes/index.html",
      "tags/nim/index.html", "tags/web/index.html"]
    # The tag page title comes from data/tags.toml.
    check readFile(output / "tags/web/index.html").contains("<h1>The web</h1>")
    # Previous (older) and next (newer) posts, and the series in reading order.
    check relLinks(output, "/posts/second/") == {"prev": "/posts/first/", "next": "/posts/bundle/"}.toTable
    check relLinks(output, "/posts/first/") == {"next": "/posts/second/"}.toTable
    check relLinks(output, "/posts/another/") == {"prev": "/posts/third/"}.toTable
    var series: seq[string]
    linksUnder(parseHtml(readFile(output / "posts/second/index.html")), "series-navigation", false, series)
    check series == @["/posts/first/"]
    check readFile(output / "posts/second/index.html").contains(
      "<li class=\"series-current\" aria-current=\"page\">Second note</li>")
    check not readFile(output / "posts/third/index.html").contains("series-navigation")

  test "drafts and future posts are listed only in builds that include them":
    let root = fixtureCopy()
    defer: removeDir(root)
    fixedEpoch()
    defer: delEnv("SOURCE_DATE_EPOCH")
    let binary = compileSite(root)
    let output = root / "public"
    discard runSite(binary, root, output, @["--drafts", "--future"])
    # The draft has no date, so it sorts after every dated post.
    check listed(output, "/tags/nim/", "post-list") == @["future", "third", "second", "first", "work-in-progress"]
    check listed(output, "/posts/", "post-title") == @["future", "another"]
    check listed(output, "/posts/page/4/", "post-title") == @["work-in-progress"]
    check listed(output, "/2099/", "post-list") == @["future"]
    discard runSite(binary, root, output)
    check listed(output, "/tags/nim/", "post-list") == @["third", "second", "first"]
    check not dirExists(output / "2099")

  test "excerpts on listing pages carry root-relative links":
    let root = fixtureCopy()
    defer: removeDir(root)
    fixedEpoch()
    defer: delEnv("SOURCE_DATE_EPOCH")
    # The newest post, so the first index page lists it with its excerpt.
    writeFile(root / "posts/2021-06-06-related.md", "---\ntitle: Related\ndescription: Links\n---\n\n" &
      "See [the first note](2020-01-01-first.md), [below](#more-below) and [the site](https://example.net/x).\n\n" &
      "## More below\n\nThe rest.\n")
    let binary = compileSite(root)
    let output = root / "public"
    discard runSite(binary, root, output)
    var hrefs: seq[string]
    var pending = @[parseHtml(readFile(output / "posts/index.html"))]
    while pending.len > 0:
      let node = pending.pop()
      if node.kind != xnElement: continue
      if node.tag == "a": hrefs.add node.attr("href")
      for child in node: pending.add child
    check "/posts/first/" in hrefs
    check "/posts/related/#more-below" in hrefs
    check "https://example.net/x" in hrefs
    check "#more-below" notin hrefs
    # The post's own page keeps its same-page fragment.
    let own = readFile(output / "posts/related/index.html")
    check own.contains("href=\"#more-below\"")

  test "collisions name both sources; listings can be moved or turned off":
    let root = fixtureCopy()
    defer: removeDir(root)
    fixedEpoch()
    defer: delEnv("SOURCE_DATE_EPOCH")
    let config = readFile(root / "site.toml")
    # A content page at a generated URL.
    createDir(root / "pages/tags")
    writeFile(root / "pages/tags/nim.md", "---\ntitle: Clash\n---\nClash")
    try:
      discard loadSite(root)
      check false
    except BlogError as cause:
      check cause.msg.contains("pages/tags/nim.md")
      check cause.msg.contains("generated tag page 'nim'")
    removeDir(root / "pages/tags")
    # Two terms with one URL slug.
    writeFile(root / "data/tags.toml", readFile(root / "data/tags.toml") & "\n[Nim]\ntitle = \"Nim again\"\n")
    writeFile(root / "posts/2020-04-04-case.md", "---\ntitle: Case\ntags: [Nim]\n---\nCase")
    try:
      discard loadSite(root)
      check false
    except BlogError as cause:
      check cause.msg.contains("generated tag page 'Nim'")
      check cause.msg.contains("generated tag page 'nim'")
    removeFile(root / "posts/2020-04-04-case.md")
    # A pattern that cannot tell its pages apart is refused at configuration.
    for bad in ["[archives]\nyear = \"/years/\"\n", "[archives]\nmonth = \"/:year/\"\n",
        "[archives]\nindex = \"/:year/\"\n", "[taxonomies]\ntags = { permalink = \"/tags/\" }\n",
        "[archives]\nyear = \"/:year/:slug/\"\n"]:
      writeFile(root / "site.toml", config & bad)
      expect BlogError: discard loadSite(root)
    # Moved and turned-off listings.
    writeFile(root / "site.toml", config.replace("paginate = 2", "paginate = 10") &
      "[archives]\nindex = \"/\"\nyear = \"\"\n[taxonomies]\ncategories = { permalink = \"\" }\n")
    removeFile(root / "pages/index.md")
    let binary = compileSite(root)
    let output = root / "public"
    discard runSite(binary, root, output)
    check listed(output, "/", "post-title") == @["another", "third", "bundle", "second", "first"]
    check not fileExists(output / "posts/index.html")
    check not dirExists(output / "posts/page")
    check not dirExists(output / "2020")
    check not dirExists(output / "categories")
    check fileExists(output / "tags/nim/index.html")

  test "collections declared in site.toml: published, unpublished and ordered":
    let root = fixtureCopy()
    defer: removeDir(root)
    fixedEpoch()
    defer: delEnv("SOURCE_DATE_EPOCH")
    writeFile(root / "collections/notes/2020-05-05-dated.md", "---\ntitle: Dated\n---\nDated")
    createDir(root / "collections/drafts-box")
    writeFile(root / "collections/drafts-box/kept.md", "---\ntitle: Kept\n---\nKept")
    writeFile(root / "collections/undeclared.md", "not a collection")
    writeFile(root / "site.toml", readFile(root / "site.toml") &
      "[collections.drafts-box]\noutput = false\nsort_by = \"title\"\n")
    let site = loadSite(root)
    check toSeq(site.collections.keys) == @["drafts-box", "notes"]
    # Dated entries first, newest first, then by slug.
    check site.collections["notes"].mapIt(it.slug) == @["dated", "short"]
    check site.collections["drafts-box"].mapIt(it.slug) == @["kept"]
    check site.config.collections["drafts-box"].extra == %*{"sort_by": "title"}
    # Collection entries are not posts: no feeds, tags or archives.
    check site.posts.allIt(it.collection == "posts")
    let binary = compileSite(root)
    let output = root / "public"
    discard runSite(binary, root, output)
    check fileExists(output / "notes/short/index.html")
    check fileExists(output / "notes/dated/index.html")
    check not dirExists(output / "drafts-box")
    check not readFile(output / "feed.xml").contains("notes/short")
