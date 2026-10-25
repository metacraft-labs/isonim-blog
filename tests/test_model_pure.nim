## Pure model contracts on C and JS. Real shared front-matter APIs; no doubles.
import std/[unittest, strutils, sequtils]
import isonim_blog/[model, archives, syndication]

suite "site model":
  test "configuration retains unknown nested values and typed settings":
    let config = parseConfig(%*{"title": "Notebook", "url": "https://example.org/",
      "base_path": "/journal", "author": {"name": "Ada"},
      "extra_feature": {"a": [true, 7, "text"]},
      "collections": {"notes": {"output": true, "permalink": "/notes/:slug/"}}})
    check config.url == "https://example.org"
    check config.basePath == "/journal"
    check config.extra == %*{"extra_feature": {"a": [true, 7, "text"]}}
    check config.collections["notes"].output
    check config.scriptPolicy == spNone
    # Unknown keys nested in known tables stay in those tables for layouts.
    let nested = parseConfig(%*{"title": "N", "feeds": {"future_option": 1},
      "output": {"scripts": "islands", "preload": ["a"]},
      "collections": {"notes": {"permalink": "/n/:slug/", "sort_by": "title"}}})
    check nested.feeds["future_option"].getInt == 1
    check nested.output["preload"] == %*["a"]
    check nested.scriptPolicy == spDeclared
    check nested.collections["notes"].extra == %*{"sort_by": "title"}
    check not nested.collections["notes"].output
    check nested.extra.len == 0
    expect BlogError: discard parseConfig(%*{"title": "N", "output": {"scripts": "all"}})
    expect BlogError: discard parseConfig(%*{"title": "N", "collections": {"posts": {}}})
    expect BlogError: discard parseConfig(%*{"title": "N", "collections": {"bad name": {}}})
    expect BlogError: discard parseConfig(%*{"title": "N", "paginate": 0})
    expect BlogError: discard parseConfig(%*{"title": 7})
    expect BlogError: discard parseConfig(%*{"title": "N", "url": "https://example.org/path"})

  test "dates validate calendars and metadata overrides names":
    let page = pageFromSource("posts/2020-01-02-old.md",
      "---\ndate: 2024-02-29\nslug: new\ntitle: A title\ncustom: [a, b]\n---\nBody", "posts", "/:year/:month/:day/:slug/")
    check page.date == "2024-02-29"
    check page.url == "/2024/02/29/new/"
    check page.extra.getList("custom") == @["a", "b"]
    check page.body == "Body"
    check page.bodyLine == 7
    for bad in ["2023-02-29", "2024-13-01", "2024-00-01", "2024-01-32", "0x24-01-01"]:
      expect BlogError: discard validDate(bad)
    expect BlogError: discard pageFromSource("posts/undated.md", "Body", "posts", "/:slug/")
    check pageFromSource("drafts/undated.md", "Body", "posts", "/:slug/", true).noindex

  test "every permalink placeholder and clean file mapping":
    var page = Page(source: "post.md", date: "2024-02-03", slug: "hello", title: "Hello World",
      categories: @["Nim", "Web UI"], collection: "notes")
    check permalinkFor("/:year/:month/:day/:slug/:title/:categories/:collection/:name/", page) ==
      "/2024/02/03/hello/hello-world/nim/web-ui/notes/hello/"
    check outputPath("/") == "index.html"
    check outputPath("/about") == "about/index.html"
    check outputPath("/404.html") == "404.html"
    for bad in ["relative", "//host/a", "/../a", "/a//b", "/a?x", "/%2e%2e/a", "/a\\b", "/a#x"]:
      expect BlogError: discard cleanRoute(bad)
    expect BlogError: discard permalinkFor("/:unknown/", page)

  test "collisions name both sources and cover case and index aliases":
    for route in ["/same/", "/same", "/SAME/index.html"]:
      try:
        checkCollisions([Page(source: "first.md", url: "/same/", output: true),
          Page(source: "second.md", url: route, output: true)])
        check false
      except BlogError as cause:
        check cause.msg.contains("first.md")
        check cause.msg.contains("second.md")

  test "ordering is date descending then slug ascending":
    var pages = @[Page(slug: "b", date: "2020-01-01"), Page(slug: "z", date: "2021-01-01"), Page(slug: "a", date: "2020-01-01")]
    pages.sortPages()
    check pages[0].slug == "z"
    check pages[1].slug == "a"
    check pages[2].slug == "b"

  test "feed, taxonomy and archive settings keep unknown keys and refuse ambiguous patterns":
    let defaults = parseConfig(%*{"title": "N"})
    check defaults.rssPath == "/feed.xml"
    check defaults.atomPath == "/atom.xml"
    check defaults.perTagFeeds and defaults.fullContentFeeds
    check defaults.tagPermalink == "/tags/:name/"
    check defaults.categoryPermalink == "/categories/:name/"
    check defaults.indexPermalink == "/posts/"
    check defaults.yearPermalink == "/:year/"
    check defaults.monthPermalink == ""
    let custom = parseConfig(%*{"title": "N",
      "feeds": {"rss": "", "atom": "/a/atom.xml", "per_tag": false, "later": 1},
      "archives": {"month": "/:year/:month/", "index": "/", "later": true},
      "taxonomies": {"tags": {"permalink": "/t/:slug/"}, "categories": {"permalink": ""}}})
    check custom.rssPath == "" and custom.atomPath == "/a/atom.xml" and not custom.perTagFeeds
    check custom.feeds["later"].getInt == 1
    check custom.archives["later"].getBool
    check custom.monthPermalink == "/:year/:month/"
    check custom.indexPermalink == "/"
    check custom.tagPermalink == "/t/:slug/" and custom.categoryPermalink == ""
    check custom.extra.len == 0
    for bad in [%*{"feeds": {"rss": "feed.xml"}}, %*{"feeds": {"atom": "/a/"}},
        %*{"feeds": {"rss": "/a/../b.xml"}}, %*{"feeds": {"full_content": "no"}},
        %*{"archives": {"year": "/y/"}}, %*{"archives": {"month": "/:month/"}},
        %*{"archives": {"index": "/:year/"}}, %*{"archives": {"year": "/:year/:day/"}},
        %*{"taxonomies": {"tags": {"permalink": "/tags/"}}},
        %*{"taxonomies": {"tags": {"permalink": "/:name/:name/"}}}]:
      var node = bad
      node["title"] = %"N"
      expect BlogError: discard parseConfig(node)

proc pureSite(): Site =
  ## A site assembled from real front matter, without the native loader.
  result.config = parseConfig(%*{"title": "Notes", "url": "https://example.org",
    "base_path": "/journal", "paginate": 2, "author": {"name": "Ada", "url": "/about/"}})
  var pages: seq[Page]
  for (source, raw) in [
      ("posts/2020-01-01-a.md", "---\ntitle: A\ntags: [x]\nseries: S\nseries_order: 2\n---\nA"),
      ("posts/2020-01-01-b.md", "---\ntitle: B\ntags: [x, y]\nseries: S\nseries_order: 1\n---\nB"),
      ("posts/2021-03-04-c.md", "---\ntitle: C\ncategories: [k]\nseries: S\n---\nSee [a](/journal/posts/a/)."),
      ("posts/2022-05-06-d.md", "---\ntitle: D\ntags: [y]\n---\nD")]:
    var page = pageFromSource(source, raw, "posts", "/posts/:slug/")
    page.url = cleanRoute(result.config.basePath & page.url)
    page.content = "<p>" & page.title & " <a href=\"/journal/posts/a/\">a</a></p>"
    pages.add page
  var draft = pageFromSource("drafts/e.md", "---\ntitle: E\ntags: [x]\n---\nE", "posts", "/posts/:slug/", true)
  draft.url = cleanRoute(result.config.basePath & draft.url)
  pages.add draft
  var future = pageFromSource("posts/2099-01-01-f.md", "---\ntitle: F\ntags: [x]\n---\nF", "posts", "/posts/:slug/")
  future.future = true
  future.url = cleanRoute(result.config.basePath & future.url)
  pages.add future
  pages.sortPages()
  result.pages = pages
  result.posts = pages
  result.buildDate = "2023-01-01"
  linkNavigation(result)

suite "navigation, listings and feeds":
  test "previous/next, series order, term indexes and generated pages":
    let site = pureSite()
    check site.posts.mapIt(it.slug) == @["f", "d", "c", "a", "b", "e"]
    let b = site.posts[4]
    check b.next.url == "/journal/posts/a/" and b.previous.url == "/journal/posts/e/"
    check site.posts[0].next.url == "" and site.posts[^1].previous.url == ""
    # Explicit series_order first, then date and slug.
    check b.seriesPosts.mapIt(it.title) == @["B", "A", "C"]
    check site.pages[4].seriesPosts == b.seriesPosts
    check toSeq(site.tags.keys) == @["x", "y"]
    check site.tags["x"].mapIt(it.slug) == @["f", "a", "b", "e"]
    let generated = generatedPages(site)
    check generated.mapIt(it.url) == @["/journal/posts/", "/journal/posts/page/2/",
      "/journal/posts/page/3/", "/journal/tags/x/", "/journal/tags/y/",
      "/journal/categories/k/", "/journal/2099/", "/journal/2022/", "/journal/2021/",
      "/journal/2020/"]
    check generated.mapIt(it.layout) == @["index", "index", "index", "tag", "tag",
      "category", "archive", "archive", "archive", "archive"]
    check generated[1].listing.mapIt(it.slug) == @["c", "a"]
    check generated[1].previousPageUrl == "/journal/posts/" and generated[1].nextPageUrl == "/journal/posts/page/3/"
    check generated[2].pageNumber == 3 and generated[2].pageCount == 3
    check generated[9].listing.mapIt(it.slug) == @["a", "b"]
    check generated[9].kind == pkYear and generated[9].term == "2020"
    check generated[4].updated == "2022-05-06"
    # An undated draft is listed by the index and its tags, never by a year.
    check generated.filterIt(it.kind == pkYear).mapIt(it.term) == @["2099", "2022", "2021", "2020"]
    check generated[2].listing.mapIt(it.slug) == @["b", "e"]
    check tagFeedUrl(site, "x") == "/journal/tags/x/atom.xml"

  test "feeds skip drafts and future posts; JSON-LD types; absolute URLs":
    let site = pureSite()
    check feedPosts(site).mapIt(it.slug) == @["d", "c", "a", "b"]
    let files = siteFeeds(site)
    check files.mapIt(it.path) == @["/journal/feed.xml", "/journal/atom.xml",
      "/journal/tags/x/atom.xml", "/journal/tags/y/atom.xml"]
    check files[0].content.count("<item>") == 4
    check "<title>E</title>" notin files[0].content and "<title>F</title>" notin files[0].content
    check files[2].content.count("<entry>") == 2
    check files[1].content.contains("href=&quot;https://example.org/journal/posts/a/&quot;")
    check files[1].content.contains("<uri>https://example.org/about/</uri>")
    check jsonLdFor(site, site.posts[1], "https://example.org/journal/posts/d/").contains("\"@type\":\"BlogPosting\"")
    let home = Page(url: "/journal/", title: "Home")
    check jsonLdFor(site, home, "https://example.org/journal/").contains("\"@type\":\"WebSite\"")
    check jsonLdFor(site, Page(url: "/journal/x/"), "u").contains("\"@type\":\"WebPage\"")
    var empty = site
    empty.posts = @[]
    empty.tags.clear()
    check siteFeeds(empty)[1].content.contains("<updated>2023-01-01T00:00:00Z</updated>")
    var noOrigin = site
    noOrigin.config.url = ""
    expect BlogError: discard siteFeeds(noOrigin)
