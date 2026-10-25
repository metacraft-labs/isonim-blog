## Feeds, structured data and the sitemap end to end: the generic fixture
## site is built by its real compiled layout program, and every XML file it
## writes is parsed by an independent conforming XML parser (Python's
## standard `xml.etree.ElementTree`, the interpreter the build already uses
## for TOML). No test doubles.
import std/[unittest, json, sequtils, strutils, tables, htmlparser]
import isonim_blog/[model, html_checks]
import ./site_helpers

const feedReader = """
import json, sys, xml.etree.ElementTree as ET
A = "{http://www.w3.org/2005/Atom}"
C = "{http://purl.org/rss/1.0/modules/content/}"
def text(node, tag):
    found = node.find(tag)
    return None if found is None else (found.text or "")
out = {}
for path in sys.argv[1:]:
    root = ET.parse(path).getroot()
    if root.tag == "rss":
        channel = root.find("channel")
        out[path] = {"format": "rss", "title": text(channel, "title"), "link": text(channel, "link"),
          "self": channel.find(A + "link").get("href"),
          "entries": [{"title": text(i, "title"), "link": text(i, "link"), "id": text(i, "guid"),
            "date": text(i, "pubDate"), "content": text(i, C + "encoded"),
            "summary": text(i, "description"),
            "categories": [c.text for c in i.findall("category")]} for i in channel.findall("item")]}
    elif root.tag == A + "feed":
        links = {l.get("rel"): l.get("href") for l in root.findall(A + "link")}
        out[path] = {"format": "atom", "title": text(root, A + "title"), "link": links.get("alternate"),
          "self": links.get("self"), "updated": text(root, A + "updated"),
          "author": text(root.find(A + "author"), A + "name"),
          "entries": [{"title": text(e, A + "title"), "link": e.find(A + "link").get("href"),
            "id": text(e, A + "id"), "date": text(e, A + "published"), "updated": text(e, A + "updated"),
            "content": text(e, A + "content"), "summary": text(e, A + "summary"),
            "categories": [c.get("term") for c in e.findall(A + "category")]}
            for e in root.findall(A + "entry")]}
    else:
        ns = "{http://www.sitemaps.org/schemas/sitemap/0.9}"
        out[path] = {"format": "sitemap", "urls": [[text(u, ns + "loc"), text(u, ns + "lastmod")]
          for u in root.findall(ns + "url")]}
print(json.dumps(out))
"""

proc parseXml(files: varargs[string]): JsonNode =
  ## Each file parsed by the independent reader; a malformed file fails it.
  parseJson(runPython(@["-c", feedReader] & @files))

proc built(drafts = false; extraConfig = ""; setup: proc(root: string) = nil):
    tuple[root, output: string] =
  result.root = fixtureCopy()
  if setup != nil: setup(result.root)
  if extraConfig.len > 0:
    writeFile(result.root / "site.toml", readFile(result.root / "site.toml") & extraConfig)
  let binary = compileSite(result.root)
  result.output = result.root / "public"
  discard runSite(binary, result.root, result.output,
    if drafts: @["--drafts", "--future"] else: @[])

const published = @["Another note", "Third note", "A bundled note", "Second note", "First note"]

suite "feeds":
  test "RSS and Atom parse and carry every non-draft, non-future post with absolute links and full content":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    # Built with --drafts and --future, so a draft and a future post are
    # part of the site and the feed writer must filter them out itself. The
    # draft here is dated (`draft: true` under posts/), so a feed that let it
    # through would still be valid: only the no-drafts assertions catch it.
    let (root, output) = built(drafts = true, setup = proc(root: string) =
      removeFile(root / "drafts/work-in-progress.md")
      writeFile(root / "posts/2020-04-04-hidden.md",
        "---\ntitle: Hidden draft\ndescription: Not yet\ntags: [nim]\ndraft: true\n---\nHidden.\n"))
    defer: removeDir(root)
    # Positive controls: both really are in this build, in listings too.
    check fileExists(output / "posts/hidden/index.html")
    check fileExists(output / "posts/future/index.html")
    check readFile(output / "tags/nim/index.html").contains("/posts/hidden/")
    let rss = output / "feed.xml"
    let atom = output / "atom.xml"
    let tagFeed = output / "tags/nim/atom.xml"
    let feeds = parseXml(rss, atom, tagFeed)
    for path in [rss, atom]:
      let feed = feeds[path]
      check feed["title"].getStr == "Field Notes"
      check feed["link"].getStr == "https://example.org/"
      check feed["self"].getStr == "https://example.org/" & extractFilename(path)
      let entries = feed["entries"]
      # Exactly the published posts, newest first then by slug: no drafts.
      check entries.mapIt(it["title"].getStr) == published
      for entry in entries:
        check entry["title"].getStr notin ["Hidden draft", "A future note"]
        check entry["link"].getStr.startsWith("https://example.org/posts/")
        check entry["id"].getStr == entry["link"].getStr
        let content = entry["content"].getStr
        check content.len > 0
        # Full content, every reference absolute.
        check "href=\"/" notin content and "src=\"/" notin content
        check "href=\"https://example.org/" in content or "href" notin content
    for path in [rss, atom]:
      let entries = feeds[path]["entries"]
      check entries[0]["content"].getStr == "<p>Two notes share a date; the slug orders them.</p>"
      check entries[3]["content"].getStr.contains(
        "<a href=\"https://example.org/posts/first/#beginnings\">first note</a>")
      check entries[2]["content"].getStr.contains("href=\"https://example.org/assets/posts/2020-03-03-bundle/figure.")
      check entries[3]["categories"].mapIt(it.getStr) == @["nim", "web", "notes"]
    check feeds[rss]["entries"][3]["date"].getStr == "Sun, 02 Feb 2020 00:00:00 +0000"
    check feeds[atom]["entries"][3]["date"].getStr == "2020-02-02T00:00:00Z"
    check feeds[atom]["entries"][3]["updated"].getStr == "2020-06-01T00:00:00Z"
    check feeds[atom]["updated"].getStr == "2021-05-05T00:00:00Z"
    check feeds[atom]["author"].getStr == "Example Author"
    # The per-tag Atom feed: the tag's published posts only.
    check feeds[tagFeed]["entries"].mapIt(it["title"].getStr) == @["Third note", "Second note", "First note"]
    check feeds[tagFeed]["link"].getStr == "https://example.org/tags/nim/"
    check feeds[tagFeed]["self"].getStr == "https://example.org/tags/nim/atom.xml"
    check fileExists(output / "tags/web/atom.xml")
    # A tag feed is titled by the tag's title in data/tags.toml, like its page
    # (`web` is titled "The web", so the raw tag cannot pass for it).
    check feeds[tagFeed]["title"].getStr == "Field Notes — Nim"
    check parseXml(output / "tags/web/atom.xml")[output / "tags/web/atom.xml"]["title"].getStr ==
      "Field Notes — The web"
    check readFile(output / "tags/web/index.html").contains("title=\"Field Notes — The web (Atom)\"")

  test "every page links the feeds; a tag page links its own":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let (root, output) = built()
    defer: removeDir(root)
    var pages = 0
    for file in inputFiles(output):
      if not file.endsWith(".html"): continue
      inc pages
      var alternates: seq[string]
      var pending = @[parseHtml(readFile(file))]
      while pending.len > 0:
        let node = pending.pop()
        if node.kind != xnElement: continue
        if node.tag == "link" and node.attr("rel") == "alternate":
          alternates.add node.attr("type") & " " & node.attr("href")
        for child in node: pending.add child
      check "application/rss+xml https://example.org/feed.xml" in alternates
      check "application/atom+xml https://example.org/atom.xml" in alternates
      let isTag = relativePath(file, output).startsWith("tags/nim/")
      check ("application/atom+xml https://example.org/tags/nim/atom.xml" in alternates) == isTag
    check pages == 17

  test "summaries, turned-off feeds and a missing origin":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    var site = built(extraConfig = "[feeds]\nfull_content = false\nper_tag = false\nrss = \"/rss.xml\"\n")
    defer: removeDir(site.root)
    let feeds = parseXml(site.output / "rss.xml", site.output / "atom.xml")
    for path in [site.output / "rss.xml", site.output / "atom.xml"]:
      check feeds[path]["entries"].mapIt(it["title"].getStr) == published
      for entry in feeds[path]["entries"]: check entry["content"].kind == JNull
      check feeds[path]["entries"][3]["summary"].getStr.contains("https://example.org/posts/first/#beginnings")
    check not fileExists(site.output / "feed.xml")
    check not fileExists(site.output / "tags/nim/atom.xml")
    removeDir(site.root)
    site = built(extraConfig = "[feeds]\nrss = \"\"\natom = \"\"\n")
    check not fileExists(site.output / "atom.xml")
    check not readFile(site.output / "posts/first/index.html").contains("rel=\"alternate\"")
    # Absolute links need an origin: without url, the build fails and names it.
    writeFile(site.root / "site.toml", readFile(site.root / "site.toml").replace("url = \"https://example.org\"\n", ""))
    let binary = compileSite(site.root)
    try:
      discard runSite(binary, site.root, site.root / "other")
      check false
    except BlogError as cause:
      check cause.msg.contains("url is required")
    check not dirExists(site.root / "other")
    for bad in ["[feeds]\nrss = \"feed.xml\"\n", "[feeds]\natom = \"/feeds/\"\n",
        "[feeds]\nrss = \"/../feed.xml\"\n", "[feeds]\nper_tag = \"yes\"\n"]:
      writeFile(site.root / "site.toml", readFile(site.root / "site.toml").split("[feeds]")[0] & bad)
      expect BlogError: discard loadSite(site.root)

suite "structured data and sitemap":
  test "BlogPosting, WebSite and Person JSON-LD; sitemap lastmod from updated":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let (root, output) = built(drafts = true)
    defer: removeDir(root)
    proc jsonLd(route: string): JsonNode =
      let scripts = scriptElements(readFile(output / outputPath(route)))
        .filterIt(it.attr("type") == "application/ld+json")
      check scripts.len == 1
      parseJson(scripts[0].innerText)
    let post = jsonLd("/posts/second/")
    check post["@type"].getStr == "BlogPosting"
    check post["headline"].getStr == "Second note"
    check post["url"].getStr == "https://example.org/posts/second/"
    check post["datePublished"].getStr == "2020-02-02"
    check post["dateModified"].getStr == "2020-06-01"
    check post["author"] == %*{"@type": "Person", "name": "Example Author", "url": "https://example.org/about/"}
    check post["keywords"] == %*["nim", "web"]
    let home = jsonLd("/")
    check home["@type"].getStr == "WebSite"
    check home["url"].getStr == "https://example.org/"
    check home["author"]["@type"].getStr == "Person"
    let listing = jsonLd("/tags/nim/")
    check listing["@type"].getStr == "WebPage"
    check listing["isPartOf"]["@type"].getStr == "WebSite"
    # A title that tries to close the script element stays inside it.
    writeFile(root / "posts/2020-01-01-first.md",
      readFile(root / "posts/2020-01-01-first.md").replace("title: First note", "title: \"</script><b>x\""))
    discard runSite(compileSite(root), root, output)
    # The raw block runs to the first `</script>`: it must be the whole JSON
    # document, which it is only if the title's `<` was escaped.
    let escaped = readFile(output / "posts/first/index.html")
    let start = escaped.find("<script type=\"application/ld+json\">") + len("<script type=\"application/ld+json\">")
    let raw = escaped[start ..< escaped.find("</script>", start)]
    check parseJson(raw)["headline"].getStr == "</script><b>x"
    check jsonLd("/posts/first/")["headline"].getStr == "</script><b>x"

  test "a root-relative author url is a path under the base path":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    # The fixture's author url is "/about/"; under base_path "/blog" the about
    # page is /blog/about/, and the author links must say so.
    let (root, output) = built(setup = proc(root: string) =
      # A top-level key, so it goes before the file's first table.
      writeFile(root / "site.toml", "base_path = \"/blog\"\n" & readFile(root / "site.toml")))
    defer: removeDir(root)
    # Pages are written under the base path, like their URLs.
    check fileExists(output / "blog/about/index.html")
    let first = readFile(output / "blog/posts/first/index.html")
    check first.contains("https://example.org/blog/posts/first/")
    let scripts = scriptElements(first)
      .filterIt(it.attr("type") == "application/ld+json")
    check scripts.len == 1
    let ld = parseJson(scripts[0].innerText)
    check ld["author"]["url"].getStr == "https://example.org/blog/about/"
    check ld["publisher"]["url"].getStr == "https://example.org/blog/about/"
    check readFile(output / "blog/atom.xml").contains("<uri>https://example.org/blog/about/</uri>")

  test "the sitemap lists indexable pages with lastmod and never drafts or future posts":
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let (root, output) = built(drafts = true)
    defer: removeDir(root)
    let urls = parseXml(output / "sitemap.xml")[output / "sitemap.xml"]["urls"]
    var lastmods = initTable[string, string]()
    for pair in urls: lastmods[pair[0].getStr] = pair[1].getStr
    check lastmods.len == urls.len
    # updated, not the post date; a listing page carries its newest update.
    check lastmods["https://example.org/posts/second/"] == "2020-06-01"
    check lastmods["https://example.org/posts/first/"] == "2020-01-01"
    check lastmods["https://example.org/2020/"] == "2020-06-01"
    check lastmods["https://example.org/about/"] == ""
    check "https://example.org/posts/work-in-progress/" notin lastmods
    check "https://example.org/posts/future/" notin lastmods
    # A listing that lists only previews is a preview too: the 2099 archive
    # holds only the future post, and the fourth index page only the
    # undated draft. Neither page exists in a production build.
    check "https://example.org/2099/" notin lastmods
    check "https://example.org/posts/page/4/" notin lastmods
    # Listing lastmod values come from published posts only: the nim tag
    # also lists the 2099 post, and the first index page lists it first.
    check lastmods["https://example.org/tags/nim/"] == "2021-05-05"
    check lastmods["https://example.org/posts/"] == "2021-05-05"
    # Positive control: every one of those pages was built.
    for page in ["posts/work-in-progress", "posts/future", "2099", "posts/page/4"]:
      check fileExists(output / page / "index.html")
    # 8 indexable content pages (the draft and the future post are not) and
    # 9 listings: 3 index pages, 2 tags, 2 categories and 2 years.
    check lastmods.len == 17
    check readFile(output / "robots.txt") == "User-agent: *\nAllow: /\nSitemap: https://example.org/sitemap.xml\n"
    # A site's own robots.txt replaces the generated one.
    writeFile(root / "static/robots.txt", "User-agent: *\nDisallow: /\n")
    discard runSite(compileSite(root), root, output)
    check readFile(output / "robots.txt") == "User-agent: *\nDisallow: /\n"
