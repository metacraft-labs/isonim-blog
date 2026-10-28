## A site under a base path, end to end. The generic fixture site, with the
## shipped default theme (for its stylesheets) and `base_path = "/blog"`, is
## built by its real compiled layout program, and the output is read back by
## independent parsers: Python's standard `html.parser` for pages and
## `xml.etree.ElementTree` for feeds and the sitemap, not the code that wrote
## them. No test doubles.
##
## The rule under test is that the output directory is the base path's root,
## as with Hugo's `baseURL`, Jekyll's `baseurl` and Eleventy's `pathPrefix`:
## every URL the build writes carries the base path, no file is written under
## it, and each such URL names a file of the output once the origin and the
## base path are taken off. `robots.txt` is generated only for a site at the
## root of its host, because crawlers read it nowhere else (RFC 9309 §2.3).
import std/[unittest, json, strutils, tables, sets, uri]
import isonim_blog
import isonim_blog/html_checks
import ./site_helpers

const
  origin = "https://example.org"
  base = "/blog"

const xmlReader = """
import json, sys, xml.etree.ElementTree as ET
from html.parser import HTMLParser
class Refs(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.found = []
    def handle_starttag(self, tag, attrs):
        for name, value in attrs:
            if name in ("href", "src", "poster") and value is not None:
                self.found.append(value)
            if name == "srcset" and value:
                self.found.extend(part.split()[0] for part in value.split(",") if part.strip())
    handle_startendtag = handle_starttag
out = {}
for path in sys.argv[1:]:
    urls = []
    for node in ET.parse(path).getroot().iter():
        tag = node.tag.split("}")[-1]
        if node.get("href") is not None:
            urls.append(node.get("href"))
        if tag in ("link", "loc", "uri", "guid", "id") and node.text and node.text.strip():
            urls.append(node.text.strip())
        if tag in ("encoded", "content", "summary", "description") and node.text:
            refs = Refs()
            refs.feed(node.text)
            urls.extend(refs.found)
    out[path] = urls
print(json.dumps(out))
"""

proc fileFor(public, url: string): string =
  ## The output file a site URL names, or "" when the URL is not under the
  ## base path or names no file. `url` is absolute, or root-relative.
  var path = url
  if path.startsWith(origin & "/"): path = path[origin.len .. ^1]
  if not (path == base or path.startsWith(base & "/")): return ""
  path = path[base.len .. ^1]
  for mark in ['#', '?']:
    let at = path.find(mark)
    if at >= 0: path.setLen(at)
  path = decodeUrl(path, decodePlus = false)
  if path.len == 0 or path.endsWith("/"): path.add "index.html"
  let file = public / path[1 .. ^1]
  if fileExists(file): file else: ""

proc onSite(url: string): bool =
  ## A URL of this site: root-relative, or on its origin.
  (url.startsWith("/") and not url.startsWith("//")) or url.startsWith(origin & "/") or url == origin

proc pageUrl(public, file: string): string =
  ## The public URL path of a built page.
  var rel = relativePath(file, public).replace('\\', '/')
  if rel.endsWith("index.html"): rel.setLen(rel.len - "index.html".len)
  base & "/" & rel

proc jsonLdUrls(node: JsonNode; found: var seq[tuple[kind, url: string]]) =
  ## Every URL-valued property of a JSON-LD document, at any depth.
  case node.kind
  of JObject:
    for key, value in node:
      if key in ["url", "mainEntityOfPage", "image"] and value.kind == JString:
        found.add ("json-ld " & key, value.getStr)
      else: jsonLdUrls(value, found)
  of JArray:
    for value in node: jsonLdUrls(value, found)
  else: discard

proc builtUnderBasePath(): tuple[root, public: string] =
  result.root = fixtureCopy()
  let root = result.root
  writeFile(root / "site.toml", "base_path = \"" & base & "/\"\n" &
    "theme = \"isonim-blog-theme-minimal\"\n" & readFile(root / "site.toml"))
  # An old URL that moved, and an OpenGraph image from static/.
  copyFile(root / "posts/2020-03-03-bundle/photo.png", root / "static/cover.png")
  writeFile(root / "posts/2020-01-01-first.md", readFile(root / "posts/2020-01-01-first.md")
    .replace("title: First note", "title: First note\nredirect_from: [/2019/first.html]"))
  writeFile(root / "pages/about.md", readFile(root / "pages/about.md")
    .replace("title: About", "title: About\nog_image: /cover.png"))
  result.public = root / "public"
  discard runSite(compileSite(root), root, result.public, @["--now", "@1704067200"])

suite "base path":
  test "the output root is the base path's root, and every URL the build writes names an output file":
    let (root, public) = builtUnderBasePath()
    defer: removeDir(root)
    # Layout: pages, feeds, the sitemap, assets, image variants, OpenGraph
    # cards and static files sit at the output root; nothing is nested under
    # the base path.
    check not dirExists(public / "blog")
    for file in ["index.html", "posts/first/index.html", "about/index.html", "tags/nim/index.html",
        "feed.xml", "atom.xml", "tags/nim/atom.xml", "sitemap.xml", "asset-manifest.json",
        "verification.txt", "cover.png", "build.json", "_headers", "_redirects"]:
      check fileExists(public / file)
    check dirExists(public / "assets/og")
    # Crawlers never read a robots.txt below the host's root.
    check not fileExists(public / "robots.txt")

    # Every page: links, stylesheets, images and their variants, feed
    # discovery, canonical and OpenGraph URLs, and JSON-LD.
    var pages, checked = 0
    var missing: seq[string]
    var kinds = initHashSet[string]()
    for file in walkDirRec(public):
      if not file.endsWith(".html"): continue
      inc pages
      let page = pageUrl(public, file)
      var urls: seq[tuple[kind, url: string]]
      for element in htmlElements(file, "a", "link", "img", "source", "meta", "script"):
        let tag = element["<tag>"]
        for name in ["href", "src"]:
          if element.hasKey(name): urls.add (tag & " " & name, element[name])
        if element.hasKey("srcset"):
          for candidate in element["srcset"].split(','):
            if candidate.strip().len > 0: urls.add (tag & " srcset", candidate.strip().splitWhitespace()[0])
        if tag == "meta" and element.getOrDefault("property") in ["og:image", "og:url"] or
            element.getOrDefault("name") == "twitter:image":
          urls.add ("meta " & element.getOrDefault("property", element.getOrDefault("name")),
            element["content"])
      for script in scriptElements(readFile(file)):
        if script.attr("type") != "application/ld+json": continue
        jsonLdUrls(parseJson(script.innerText), urls)
      for (kind, raw) in urls:
        if raw.startsWith("#") or raw.startsWith("data:") or raw.startsWith("mailto:"): continue
        # Page-relative references resolve against the page's public URL.
        let url = if onSite(raw) or raw.contains("://"): raw
          else: $combine(parseUri(origin & page), parseUri(raw))
        if not onSite(url): continue
        inc checked
        kinds.incl kind
        if fileFor(public, url).len == 0: missing.add page & ": " & kind & " " & raw
    check missing == newSeq[string]()
    check pages >= 15
    check checked >= 200
    for kind in ["a href", "link href", "img src", "source srcset", "meta og:image", "meta og:url",
        "meta twitter:image", "json-ld url"]:
      check kind in kinds
    # The stylesheets and the static OpenGraph image are among them.
    let about = readFile(public / "about/index.html")
    check about.contains("content=\"" & origin & base & "/cover.png\"")
    check about.contains("href=\"" & base & "/assets/theme-tokens.")

    # Feeds and the sitemap: links, ids, self links and the content's URLs.
    var feedFiles: seq[string]
    for file in ["feed.xml", "atom.xml", "tags/nim/atom.xml", "sitemap.xml"]: feedFiles.add public / file
    let feeds = parseJson(runPython(@["-c", xmlReader] & feedFiles))
    var feedUrls = 0
    var feedMissing: seq[string]
    for file, urls in feeds:
      for value in urls:
        let url = value.getStr
        if url.startsWith("tag:") or url.startsWith("urn:"): continue
        if not url.startsWith(origin): continue
        inc feedUrls
        if fileFor(public, url).len == 0: feedMissing.add file & ": " & url
    check feedMissing == newSeq[string]()
    check feedUrls >= 40
    check readFile(public / "sitemap.xml").contains("<loc>" & origin & base & "/</loc>")
    check readFile(public / "feed.xml").contains("<link>" & origin & base & "/</link>")

    # Host files are read from the output root: a redirect's source is the
    # old path there, its target the page's URL with the base path.
    check ("/2019/first.html " & base & "/posts/first/ 301") in readFile(public / "_redirects").splitLines()
    check fileFor(public, base & "/posts/first/").len > 0
    check readFile(public / "_headers").contains("/*\n  Content-Security-Policy: ")

  test "check finds no broken link in a site under a base path":
    let root = fixtureCopy()
    defer: removeDir(root)
    writeFile(root / "site.toml", "base_path = \"" & base & "\"\n" &
      "theme = \"isonim-blog-theme-minimal\"\n" & readFile(root / "site.toml"))
    let report = checkSite(root)
    var errors: seq[string]
    for finding in report.findings:
      if finding.severity == svError: errors.add finding.location & ": " & finding.message
    check errors == newSeq[string]()
    # It really followed the links: pages, feeds and internal links.
    check report.pages >= 15
    check report.feeds >= 3
    check report.internalLinks >= 100
    check not fileExists(root / "build/isonim-blog/check/robots.txt")

  test "a site at the root of its host gets robots.txt, and output paths are its URLs":
    let root = fixtureCopy()
    defer: removeDir(root)
    let public = root / "public"
    discard runSite(compileSite(root), root, public, @["--now", "@1704067200"])
    check readFile(public / "robots.txt") ==
      "User-agent: *\nAllow: /\nSitemap: " & origin & "/sitemap.xml\n"
    check fileExists(public / "posts/first/index.html")
    check fileExists(public / "sitemap.xml")

  test "outputRoute takes the base path off a site URL":
    check outputRoute("", "/posts/x/") == "/posts/x/"
    check outputRoute("/blog", "/blog/") == "/"
    check outputRoute("/blog", "/blog") == "/"
    check outputRoute("/blog", "/blog/posts/x/") == "/posts/x/"
    check outputRoute("/blog", "/blog/feed.xml") == "/feed.xml"
    check outputRoute("/a/b", "/a/b/c/") == "/c/"
    # Whole segments only: /blogger is not under /blog.
    for outside in ["/blogger/", "/", "/posts/x/"]:
      expect BlogError: discard outputRoute("/blog", outside)
