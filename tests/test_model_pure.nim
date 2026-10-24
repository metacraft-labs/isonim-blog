## Pure model contracts on C and JS. Real shared front-matter APIs; no doubles.
import std/[unittest, strutils]
import isonim_blog/model

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
