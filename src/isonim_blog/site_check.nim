## `isonim-blog check`: build the site the way production does and verify
## the result.
##
## * Front matter: every problem `build` only warns about (a missing or long
##   description) is an error here; invalid front matter fails the build.
## * Internal links and anchors: every `href`, `src`, `srcset`, `poster` and
##   `og:image`/`og:url`/`twitter:image` reference of every built page that
##   stays on the site must name a built file, and a `#fragment` must name an
##   `id` (or `<a name>`) of the target page. The check reads the built HTML,
##   so links written by layouts and includes are covered as well as Markdown
##   links.
## * Alt text: every `<img>` has a non-empty `alt`.
## * Scripts: every page that carries a script element other than JSON-LD
##   is listed with the reason (the declared islands bundle, analytics); any
##   other script is an error.
## * Feeds: every RSS 2.0 and Atom feed the pages link is well-formed XML
##   with the required elements, absolute links and valid dates.
## * With `--external`, every `http(s)` link to another origin is requested
##   (curl, injected as ISONIM_BLOG_CURL) and must answer below 400.
##
## HTML is tokenized by Python's standard `html.parser` (the pinned Python
## the build already uses), which decodes attribute values exactly as HTML
## specifies; Nim's `std/htmlparser` rewrites whitespace inside attribute
## values (`srcset="a 1x, b 2x"`), which would hide broken candidates.
import std/[os, strutils, tables, sets, algorithm, uri, times, json, tempfiles, xmltree, xmlparser]
import ./[model, inputs, program]
import isonim/static/feeds

type
  Severity* = enum
    svInfo = "info", svWarning = "warning", svError = "error"
  Finding* = object
    severity*: Severity
    location*: string   ## a built file relative to the output, or a source
    message*: string
  CheckOptions* = object
    external*: bool
  CheckReport* = object
    findings*: seq[Finding]
    pages*, feeds*, internalLinks*, externalLinks*: int
  StartTag* = object
    ## One start tag as an HTML parser reports it: lower-case name, decoded
    ## attribute values (the first of duplicated attributes, as browsers do).
    name*: string
    attributes*: Table[string, string]

proc errors*(report: CheckReport): int =
  for finding in report.findings:
    if finding.severity == svError: inc result

proc add(report: var CheckReport; severity: Severity; location, message: string) =
  let finding = Finding(severity: severity, location: location, message: message)
  if finding notin report.findings: report.findings.add finding

proc formatReport*(report: CheckReport): string =
  ## One line per finding, then a summary line.
  for finding in report.findings:
    result.add $finding.severity & ": " & finding.location & ": " & finding.message & "\n"
  result.add "Checked " & $report.pages & " pages, " & $report.feeds & " feeds, " &
    $report.internalLinks & " internal and " & $report.externalLinks &
    " external links: " & $report.errors & " errors\n"

proc attr*(tag: StartTag; name: string): string = tag.attributes.getOrDefault(name)

# -- HTML tokenizing (Python's html.parser) ----------------------------------

const tagReader = """
import json, os, sys
from html.parser import HTMLParser
class Reader(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.found = []
    def handle_starttag(self, tag, attrs):
        values = {}
        for name, value in attrs:
            values.setdefault(name, "" if value is None else value)
        self.found.append([tag, values])
    handle_startendtag = handle_starttag
def tags(text):
    reader = Reader()
    reader.feed(text)
    reader.close()
    return reader.found
mode, source = sys.argv[1], sys.argv[2]
if mode == "tree":
    result = {}
    for directory, dirs, files in os.walk(source):
        dirs.sort()
        for name in sorted(files):
            if name.endswith(".html"):
                path = os.path.join(directory, name)
                with open(path, encoding="utf-8") as page:
                    result[os.path.relpath(path, source).replace(os.sep, "/")] = tags(page.read())
else:
    with open(source, encoding="utf-8") as documents:
        result = [tags(text) for text in json.load(documents)]
print(json.dumps(result, ensure_ascii=False))
"""

proc toTags(node: JsonNode): seq[StartTag] =
  for item in node:
    var tag = StartTag(name: item[0].getStr, attributes: initTable[string, string]())
    for key, value in item[1]: tag.attributes[key] = value.getStr
    result.add tag

proc treeStartTags*(root: string): OrderedTable[string, seq[StartTag]] =
  ## The start tags of every `.html` file under `root`, by relative path.
  result = initOrderedTable[string, seq[StartTag]]()
  let decoded = parseJson(runPython(["-c", tagReader, "tree", root]))
  var paths: seq[string]
  for path in decoded.keys: paths.add path
  paths.sort()
  for path in paths: result[path] = toTags(decoded[path])

proc startTags*(documents: openArray[string]): seq[seq[StartTag]] =
  ## The start tags of each HTML document (fragment) in `documents`.
  if documents.len == 0: return
  let (file, path) = createTempFile("isonim-blog-check-", ".json")
  try:
    file.write($(%documents))
    file.close()
    for item in parseJson(runPython(["-c", tagReader, "documents", path])): result.add toTags(item)
  finally: removeFile(path)

proc srcsetUrls(value: string): seq[string] =
  ## The URLs of a `srcset`: comma-separated candidates, each a URL and an
  ## optional width or density descriptor.
  for candidate in value.split(','):
    let parts = candidate.strip().splitWhitespace()
    if parts.len > 0: result.add parts[0]

proc references*(tag: StartTag): seq[string] =
  ## Every URL a start tag refers to.
  for name in ["href", "src", "poster"]:
    if tag.attr(name).len > 0: result.add tag.attr(name)
  if tag.attr("srcset").len > 0: result.add srcsetUrls(tag.attr("srcset"))
  if tag.name == "meta" and (tag.attr("property") in ["og:image", "og:url"] or
      tag.attr("name") == "twitter:image") and tag.attr("content").len > 0:
    result.add tag.attr("content")

# -- Built output ------------------------------------------------------------

type
  OutputTree = object
    root, origin: string  ## the output directory; the site origin (no slash)
    anchors: Table[string, HashSet[string]]  ## ids of every page, by file

proc pageUrl(rel: string): string =
  ## The URL path of a built file: clean URLs drop `index.html`.
  if rel == "index.html": "/"
  elif rel.endsWith("/index.html"): "/" & rel[0 ..< rel.len - "index.html".len]
  else: "/" & rel

proc targetFile(tree: OutputTree; path: string): string =
  ## The built file a URL path names, or "" (clean URLs as hosts serve them).
  if path.len == 0 or path[0] != '/' or ".." in path.split('/'): return ""
  let rel = path[1..^1]
  if rel.len == 0 or rel.endsWith("/"):
    if fileExists(tree.root / rel / "index.html"): return rel & "index.html"
    return ""
  if fileExists(tree.root / rel): return rel
  if fileExists(tree.root / rel / "index.html"): return rel & "/index.html"
  ""

proc hasScheme(reference: string): bool =
  for i, c in reference:
    if c == ':': return i > 0
    if c notin {'a'..'z', 'A'..'Z', '0'..'9', '+', '-', '.'}: return false
  false

type
  Reference = object
    external: string        ## an http(s) URL on another origin
    path, fragment: string  ## a site path (decoded) and fragment, when internal
    internal: bool

proc classify(tree: OutputTree; page, value: string): Reference =
  ## Where a reference written on `page` (a URL path) points.
  let reference = value.strip()
  if reference.len == 0: return
  var absolute = reference
  if reference.startsWith("//"): absolute = "https:" & reference
  elif not hasScheme(reference): absolute = resolveUrl(tree.origin & page, reference)
  let lower = absolute.toLowerAscii
  if not (lower.startsWith("http://") or lower.startsWith("https://")): return  # mailto:, data:, ...
  let prefix = tree.origin.toLowerAscii
  if not (lower == prefix or lower.startsWith(prefix & "/") or lower.startsWith(prefix & "#") or
      lower.startsWith(prefix & "?")):
    return Reference(external: absolute)
  var rest = absolute[tree.origin.len .. ^1]
  var fragment = ""
  let hash = rest.find('#')
  if hash >= 0:
    fragment = decodeUrl(rest[hash + 1 .. ^1], decodePlus = false)
    rest.setLen(hash)
  let question = rest.find('?')
  if question >= 0: rest.setLen(question)
  if rest.len == 0: rest = "/"
  Reference(internal: true, path: decodeUrl(rest, decodePlus = false), fragment: fragment)

# -- Feeds -------------------------------------------------------------------

proc rfc822Valid*(value: string): bool =
  ## RFC 822 dates as RSS 2.0 uses them: `Wed, 05 May 2021 00:00:00 +0000`.
  let parts = value.splitWhitespace()
  if parts.len != 6: return false
  try: discard parse(parts[0..4].join(" "), "ddd, dd MMM yyyy HH:mm:ss", utc())
  except TimeParseError: return false
  let zone = parts[5]
  zone in ["GMT", "UT", "Z"] or
    (zone.len == 5 and zone[0] in {'+', '-'} and zone[1..4].allCharsInSet(Digits))

proc rfc3339Valid*(value: string): bool =
  ## RFC 3339 timestamps (Atom): `2021-05-05T00:00:00Z`, with an optional
  ## fraction and a `Z` or `+hh:mm` offset.
  if value.len < 20: return false
  try: discard parse(value[0..18], "yyyy-MM-dd'T'HH:mm:ss", utc())
  except TimeParseError: return false
  var rest = value[19..^1]
  if rest.startsWith("."):
    var i = 1
    while i < rest.len and rest[i] in Digits: inc i
    if i == 1: return false
    rest = rest[i..^1]
  rest == "Z" or (rest.len == 6 and rest[0] in {'+', '-'} and rest[3] == ':' and
    rest[1..2].allCharsInSet(Digits) and rest[4..5].allCharsInSet(Digits))

proc absoluteHttp(value: string): bool =
  let lower = value.strip().toLowerAscii
  (lower.startsWith("https://") or lower.startsWith("http://")) and lower.len > 8

proc child(node: XmlNode; tag: string): XmlNode =
  for item in node:
    if item.kind == xnElement and item.tag == tag: return item

proc textOf(node: XmlNode): string =
  ## Character data, CDATA sections included.
  case node.kind
  of xnText, xnCData, xnEntity: result = node.text
  of xnElement:
    for item in node: result.add textOf(item)
  else: discard

proc childText(node: XmlNode; tag: string): string =
  let item = node.child(tag)
  if item != nil: textOf(item).strip() else: ""

proc checkFeed*(content: string): seq[string] =
  ## Problems with an RSS 2.0 or Atom feed document; empty when valid.
  var document: XmlNode
  try: document = parseXml(content)
  except CatchableError as cause: return @["not well-formed XML: " & cause.msg]
  # HTML carried in items or entries, checked together at the end: relative
  # references resolve against the reader, not the site.
  var bodies: seq[tuple[label, html: string]]
  case document.tag
  of "rss":
    if document.attr("version") != "2.0": result.add "rss version must be 2.0"
    let channel = document.child("channel")
    if channel == nil: return result & @["missing channel"]
    for tag in ["title", "link", "description"]:
      if channel.childText(tag).len == 0: result.add "channel has no " & tag
    if channel.childText("link").len > 0 and not absoluteHttp(channel.childText("link")):
      result.add "channel link is not absolute: " & channel.childText("link")
    for item in channel:
      if item.kind != xnElement or item.tag != "item": continue
      let link = item.childText("link")
      let label = if link.len > 0: link else: item.childText("title")
      if item.childText("title").len == 0 and item.childText("description").len == 0:
        result.add "item without title or description"
      if not absoluteHttp(link): result.add "item link is not absolute: " & label
      if item.childText("guid").len == 0: result.add "item has no guid: " & label
      let date = item.childText("pubDate")
      if not rfc822Valid(date): result.add "invalid pubDate " & date & ": " & label
      for tag in ["content:encoded", "description"]:
        if item.childText(tag).len > 0: bodies.add (label, item.childText(tag))
  of "feed":
    if document.attr("xmlns") != "http://www.w3.org/2005/Atom":
      result.add "feed is not in the Atom namespace"
    for tag in ["id", "title", "updated"]:
      if document.childText(tag).len == 0: result.add "feed has no " & tag
    if document.childText("updated").len > 0 and not rfc3339Valid(document.childText("updated")):
      result.add "invalid feed updated " & document.childText("updated")
    let feedAuthor = document.child("author") != nil and document.child("author").childText("name").len > 0
    for entry in document:
      if entry.kind != xnElement or entry.tag != "entry": continue
      let label = entry.childText("id")
      for tag in ["id", "title", "updated"]:
        if entry.childText(tag).len == 0: result.add "entry has no " & tag & ": " & label
      if entry.childText("updated").len > 0 and not rfc3339Valid(entry.childText("updated")):
        result.add "invalid entry updated " & entry.childText("updated") & ": " & label
      let link = entry.child("link")
      if link == nil or not absoluteHttp(link.attr("href")):
        result.add "entry link is not absolute: " & label
      if not feedAuthor and (entry.child("author") == nil or entry.child("author").childText("name").len == 0):
        result.add "entry has no author and the feed has none: " & label
      for tag in ["content", "summary"]:
        let body = entry.child(tag)
        if body != nil and body.attr("type") == "html": bodies.add (label, textOf(body))
  else: return @["not an RSS 2.0 or Atom document (root " & document.tag & ")"]
  var documents: seq[string]
  for body in bodies: documents.add body.html
  let parsed = startTags(documents)
  for i, tags in parsed:
    for tag in tags:
      for value in references(tag):
        if not (hasScheme(value) or value.startsWith("#")) or value.startsWith("//"):
          result.add "relative reference in content: " & value & " (" & bodies[i].label & ")"

# -- The checks --------------------------------------------------------------

proc checkOutput*(output, origin: string; analytics: JsonNode; report: var CheckReport;
                  externalUrls: var seq[string]) =
  ## Check every built page under `output` for a site served at `origin`,
  ## whose `[output] analytics` table is `analytics`.
  let provider = if analytics.isNil: "none" else: analytics.stringValue("provider", "none")
  let beacon = if provider == "beacon": analytics.stringValue("src") else: ""
  var tree = OutputTree(root: output, origin: origin.strip(leading = false, chars = {'/'}))
  let pages = treeStartTags(output)
  for rel, tags in pages:
    var ids = initHashSet[string]()
    for tag in tags:
      if tag.attr("id").len > 0: ids.incl tag.attr("id")
      if tag.name == "a" and tag.attr("name").len > 0: ids.incl tag.attr("name")
    tree.anchors[rel] = ids
  var external = initHashSet[string]()
  var feedFiles = initOrderedTable[string, string]()  # file -> first linking page
  for rel, tags in pages:
    inc report.pages
    let page = pageUrl(rel)
    for tag in tags:
      if tag.name == "img" and tag.attr("alt").strip().len == 0:
        report.add(svError, rel, "image without alt text: " & tag.attr("src"))
      if tag.name == "script" and tag.attr("type").toLowerAscii != "application/ld+json":
        let src = tag.attr("src")
        if src.len == 0 and provider == "custom":
          report.add(svInfo, rel, "carries an inline script: the configured analytics snippet")
        elif src.len > 0 and src == beacon:
          report.add(svInfo, rel, "loads " & src & ": the configured analytics beacon")
        elif "/assets/islands." in src and src.endsWith(".js"):
          report.add(svInfo, rel, "loads " & src & ": the declared islands bundle (output.scripts = \"islands\")")
        else:
          report.add(svError, rel, "undeclared script " & (if src.len > 0: src else: "(inline)"))
      if tag.name == "link" and "alternate" in tag.attr("rel").toLowerAscii.splitWhitespace() and
          tag.attr("type").toLowerAscii in ["application/rss+xml", "application/atom+xml"]:
        let target = classify(tree, page, tag.attr("href"))
        if target.internal:
          let found = targetFile(tree, target.path)
          if found.len > 0 and not feedFiles.hasKey(found): feedFiles[found] = rel
      for value in references(tag):
        let target = classify(tree, page, value)
        if target.external.len > 0:
          external.incl target.external
          continue
        if not target.internal: continue
        inc report.internalLinks
        let found = targetFile(tree, target.path)
        if found.len == 0:
          report.add(svError, rel, "broken link " & value)
        elif target.fragment.len > 0 and found.endsWith(".html") and
            target.fragment notin tree.anchors.getOrDefault(found):
          report.add(svError, rel, "missing anchor #" & target.fragment & " in " &
            pageUrl(found) & " (" & value & ")")
  for file, page in feedFiles:
    inc report.feeds
    for problem in checkFeed(readFile(output / file)):
      report.add(svError, file, problem)
  externalUrls = @[]
  for url in external: externalUrls.add url
  externalUrls.sort()
  report.externalLinks = externalUrls.len

proc curlPath(): string =
  result = getEnv("ISONIM_BLOG_CURL")
  if result.len == 0 or not fileExists(result):
    fail("checking external links needs curl: ISONIM_BLOG_CURL is not set (enter nix develop or use the packaged CLI)")

proc externalStatus*(url: string): string =
  ## "" when `url` answers below 400 (HEAD, or GET when HEAD is refused),
  ## otherwise the status or the transfer error.
  let curl = curlPath()
  proc request(head: bool): string =
    var args = @["--silent", "--show-error", "--location", "--max-time", "20",
      "--user-agent", "isonim-blog-check", "--output", "/dev/null", "--write-out", "%{http_code}"]
    if head: args.add "--head"
    args.add "--"
    args.add url
    runTool(curl, args).strip()
  try:
    var code = request(head = true)
    if code in ["405", "403", "501"] or code.len == 0: code = request(head = false)
    if code.len == 3 and code[0] in {'1', '2', '3'}: "" else: "HTTP " & code
  except BlogError as cause: cause.msg.strip().splitLines()[^1].strip()

proc checkSite*(root: string; options = CheckOptions()): CheckReport =
  ## Load, build (as production does: no drafts, no future posts) and check
  ## the site at `root`. The build goes to `build/isonim-blog/check/`.
  let root = absolutePath(root)
  var site: Site
  try: site = loadSite(root)
  except CatchableError as cause:
    result.add(svError, "site", cause.msg)
    return
  for warning in site.warnings:
    let colon = warning.find(':')
    result.add(svError, warning[0 ..< max(colon, 0)], "front matter: " & warning[colon + 1 .. ^1].strip())
  let output = root / "build" / "isonim-blog" / "check"
  var log: string
  try: log = buildSite(root, BuildOptions(outDir: output))
  except CatchableError as cause:
    result.add(svError, "build", cause.msg.strip())
    return
  for line in log.splitLines():
    if line.startsWith("warning: ") and line[9..^1] notin site.warnings:
      result.add(svWarning, "build", line[9..^1])
  var externalUrls: seq[string]
  checkOutput(output, site.config.url, site.config.analytics, result, externalUrls)
  if options.external:
    for url in externalUrls:
      let problem = externalStatus(url)
      if problem.len > 0: result.add(svError, url, "external link: " & problem)
