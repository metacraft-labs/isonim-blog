## `isonim-blog check` end to end: real builds of the generic fixture (the
## real Nim compiler and filesystem), real HTML and XML parsing, and, for
## `--external`, real HTTP requests made by the injected curl.
##
## The external-link case serves its "internet" from a real HTTP server
## (Python's standard `http.server`) on a loopback port, because a test must
## not depend on, or send requests to, third-party sites; the server answers
## 200 for a file it has and 404 for one it does not, exactly as a remote site
## would. No other stand-ins.
import std/[unittest, sequtils, algorithm, json, net, httpclient, monotimes, times]
from std/unicode import runeLen
import isonim_blog
import ./site_helpers

proc messages(report: CheckReport; severity: Severity): seq[string] =
  for finding in report.findings:
    if finding.severity == severity: result.add finding.location & ": " & finding.message

proc inSite(root: string; args: varargs[string]): CliResult =
  let previous = getCurrentDir()
  setCurrentDir(root)
  defer: setCurrentDir(previous)
  runCli(@["check"] & @args)

putEnv("SOURCE_DATE_EPOCH", "1704067200")

suite "check":
  test "the generic fixture passes, and every kind of problem is reported":
    let root = fixtureCopy()
    defer: removeDir(root)
    # Positive control: a clean site has no errors, and the check really
    # looked at its pages, feeds and links.
    let clean = checkSite(root)
    check clean.messages(svError).len == 0
    check clean.messages(svError) == newSeq[string]()
    check clean.pages >= 15
    check clean.feeds >= 4   # RSS, Atom and per-tag Atom feeds
    check clean.internalLinks >= 100
    let passed = inSite(root)
    check passed.exitCode == 0
    check passed.output.endsWith(" external links: 0 errors\n")

    # A broken link, a missing anchor, a valid anchor, a link to a layout's
    # own markup and a missing description, all in one new post. The
    # missing description is a warning: the meta description falls back.
    writeFile(root / "posts/2020-04-04-links.md", "---\ntitle: Links\n---\n\n" &
      "Intro.\n\n## A heading\n\n[gone](/nowhere/) [bad anchor](/posts/first/#no-such-heading) " &
      "[good anchor](#a-heading) [content link](2020-01-01-first.md) [static](/verification.txt) " &
      "[mail](mailto:someone@example.org)\n")
    let report = checkSite(root)
    check report.messages(svError).sorted() == @[
      "posts/links/index.html: broken link /nowhere/",
      "posts/links/index.html: missing anchor #no-such-heading in /posts/first/ (/posts/first/#no-such-heading)"]
    check report.messages(svWarning).filterIt("description" in it) ==
      @["posts/2020-04-04-links.md: description is missing; the meta description uses the excerpt"]
    let failed = inSite(root)
    check failed.exitCode == 1
    check failed.output.contains("error: posts/links/index.html: broken link /nowhere/\n")
    check failed.output.endsWith(" external links: 2 errors\n")
    check inSite(root, "--everything").exitCode == 1

    # A build failure is reported, not hidden.
    writeFile(root / "posts/2020-04-04-links.md", "---\ntitle: [unclosed\n---\n")
    let broken = checkSite(root)
    check broken.messages(svError).len == 1
    check broken.messages(svError)[0].contains("2020-04-04-links.md")

  test "a missing description falls back to the excerpt, then the site's; check only warns":
    let root = fixtureCopy()
    defer: removeDir(root)
    # The excerpt is the part before <!--more-->; its markup and character
    # references become text.
    writeFile(root / "posts/2020-04-04-fallback.md", "---\ntitle: Fallback\ndescription: \"\"\n---\n\n" &
      "Fish & [chips](/about/), with `vinegar`.\n\nA second paragraph.\n\n<!--more-->\n\nThe rest.\n")
    # A long excerpt is cut at a word boundary.
    var words: seq[string]
    for i in 1 .. 60: words.add "word" & $i
    writeFile(root / "posts/2020-04-05-long-excerpt.md", "---\ntitle: Long excerpt\n---\n\n" &
      words.join(" ") & "\n")
    # No excerpt at all: the site's description.
    writeFile(root / "pages/empty.md", "---\ntitle: Empty\n---\n")
    let longDescription = repeat("é", 161)
    writeFile(root / "pages/wordy.md", "---\ntitle: Wordy\ndescription: \"" & longDescription &
      "\"\n---\n\nBody.\n")
    let report = checkSite(root)
    check report.messages(svError) == newSeq[string]()
    check report.messages(svWarning).filterIt("description" in it).sorted() == @[
      "pages/empty.md: description is missing; the meta description uses the site's description",
      "pages/wordy.md: front matter: description is 161 characters long; search results usually " &
        "show about 160, so the rest may be cut off",
      "posts/2020-04-04-fallback.md: description is missing; the meta description uses the excerpt",
      "posts/2020-04-05-long-excerpt.md: description is missing; the meta description uses the excerpt"]
    let passed = inSite(root)
    check passed.exitCode == 0
    check passed.output.contains("warning: posts/2020-04-04-fallback.md: description is missing; " &
      "the meta description uses the excerpt\n")
    let output = root / "build/isonim-blog/check"
    proc descriptions(page: string): seq[string] =
      ## The description meta elements of a built page: name=description,
      ## og:description and twitter:description, in that order.
      var found: array[3, string]
      for tag in htmlElements(output / page, "meta"):
        case tag.getOrDefault("name", tag.getOrDefault("property"))
        of "description": found[0] = tag["content"]
        of "og:description": found[1] = tag["content"]
        of "twitter:description": found[2] = tag["content"]
        else: discard
      @found
    proc jsonLdDescription(page: string): string =
      let html = readFile(output / page)
      let start = html.find('>', html.find("<script type=\"application/ld+json\">")) + 1
      let data = parseJson(html[start ..< html.find("</script>", start)])
      for node in (if data.hasKey("@graph"): data["@graph"].getElems else: @[data]):
        if node.hasKey("description") and node{"@type"}.getStr != "WebSite": return node["description"].getStr
    # Both paragraphs before <!--more-->, separated by a space.
    const fallback = "Fish & chips, with vinegar. A second paragraph."
    check descriptions("posts/fallback/index.html") == @[fallback, fallback, fallback]
    check jsonLdDescription("posts/fallback/index.html") == fallback
    let cut = descriptions("posts/long-excerpt/index.html")[0]
    check cut.runeLen <= maxDescriptionRunes
    check cut.endsWith("…")
    check (words.join(" ") & " ").startsWith(cut[0 ..< cut.len - "…".len] & " ")
    check descriptions("empty/index.html") == @["A small technical notebook",
      "A small technical notebook", "A small technical notebook"]
    # A page's own description is used as written, even when long.
    check descriptions("wordy/index.html")[0] == longDescription
    # Positive control: a post with its own description keeps it.
    check descriptions("posts/first/index.html")[0] == loadSite(root).pages.filterIt(
      it.source == "posts/2020-01-01-first.md")[0].description

  test "pages that carry scripts are listed with the reason":
    let root = createTempDir("isonim-blog-check-islands-", "")
    defer: removeDir(root)
    copyDir(repoRoot / "tests/fixtures/islands-site", root)
    let report = checkSite(root)
    check report.messages(svError).len == 0
    let scripts = report.messages(svInfo).filterIt("declared islands bundle" in it)
    check scripts.len > 0
    check scripts[0].startsWith("index.html: loads /assets/islands.")

  test "the output checks see what a build would refuse: alt text and undeclared scripts":
    # Hand-written output, since the build itself refuses both problems.
    let output = createTempDir("isonim-blog-check-output-", "")
    defer: removeDir(output)
    writeFile(output / "index.html", "<!doctype html><html><body>" &
      "<img src=\"/a.png\"><img src=\"/a.png\" alt=\" \"><img src=\"/a.png\" alt=\"A\">" &
      # alt="" marks a decorative image, so it is not reported (its own
      # source, so a report could not hide behind /a.png's).
      "<img src=\"/d.png\" alt=\"\"><img src=\"/d.png\" alt>" &
      "<script src=\"/tracker.js\"></script><script src=\"/beacon.js\"></script>" &
      "<script type=\"application/ld+json\">{}</script>" &
      "<a href=\"https://example.org/a.png\">self</a><a href=\"https://other.example/x\">x</a>" &
      "<a href=\"//cdn.example/y\">y</a><img alt=\"s\" srcset=\"/a.png 1x, /missing.png 2x\">" &
      "</body></html>")
    for name in ["a.png", "d.png", "tracker.js", "beacon.js"]: writeFile(output / name, "")
    var report: CheckReport
    var external: seq[string]
    checkOutput(output, "https://example.org", %*{"provider": "beacon", "src": "/beacon.js"},
      report, external)
    check report.messages(svError).sorted() == @[
      "index.html: broken link /missing.png",
      "index.html: image whose alt text is only whitespace: /a.png",
      "index.html: image without an alt attribute: /a.png",
      "index.html: undeclared script /tracker.js"]
    check report.messages(svInfo) == @["index.html: loads /beacon.js: the configured analytics beacon"]
    check external == @["https://cdn.example/y", "https://other.example/x"]

  test "feeds are checked for structure, absolute links and dates":
    let root = fixtureCopy()
    defer: removeDir(root)
    let built = buildSite(root, BuildOptions())
    check built.len > 0
    let rss = readFile(root / "public/feed.xml")
    let atom = readFile(root / "public/atom.xml")
    check checkFeed(rss).len == 0
    check checkFeed(atom).len == 0
    check checkFeed("<rss version=\"2.0\"><channel>").len == 1
    check checkFeed("<html/>") == @["not an RSS 2.0 or Atom document (root html)"]
    let firstPubDate = rss.find("<pubDate>")
    let badDate = rss[0 ..< firstPubDate] & "<pubDate>Yesterday" & rss[rss.find("</pubDate>", firstPubDate) .. ^1]
    check checkFeed(badDate).anyIt(it.startsWith("invalid pubDate Yesterday"))
    check checkFeed(rss.replace("<guid isPermaLink=\"true\">https://example.org/posts/first/</guid>", "")) ==
      @["item has no guid: https://example.org/posts/first/"]
    check checkFeed(rss.replace("<link>https://example.org/posts/first/</link>", "<link>/posts/first/</link>"))
      .anyIt(it.startsWith("item link is not absolute"))
    check checkFeed(atom.replace("href=&quot;https://example.org/assets/posts/2020-03-03-bundle/", "href=&quot;/assets/posts/2020-03-03-bundle/"))
      .anyIt(it.startsWith("relative reference in content"))
    check checkFeed(atom.replace("<updated>2021-05-05T00:00:00Z</updated>", "<updated>May 2021</updated>"))
      .anyIt(it.startsWith("invalid feed updated"))
    check rfc822Valid("Wed, 05 May 2021 00:00:00 +0000")
    check rfc822Valid("Wed, 05 May 2021 00:00:00 GMT")
    check not rfc822Valid("2021-05-05")
    check rfc3339Valid("2021-05-05T00:00:00.25+02:00")
    check not rfc3339Valid("2021-05-05 00:00:00Z")

  test "--external requests every external link":
    let root = fixtureCopy()
    let served = createTempDir("isonim-blog-check-served-", "")
    defer:
      removeDir(root)
      removeDir(served)
    writeFile(served / "ok.html", "<!doctype html><title>ok</title>")
    let socket = newSocket()
    socket.bindAddr(Port(0), "127.0.0.1")
    let port = socket.getLocalAddr()[1].int
    socket.close()
    let server = startProcess(tool("python3"), workingDir = served,
      args = ["-m", "http.server", "--bind", "127.0.0.1", $port], options = {poStdErrToStdOut})
    defer:
      server.terminate()
      discard server.waitForExit()
      server.close()
    let deadline = getMonoTime() + initDuration(seconds = 30)
    var up = false
    while not up and getMonoTime() < deadline:
      try:
        let client = newHttpClient(timeout = 1000)
        up = client.request("http://127.0.0.1:" & $port & "/ok.html").code.int == 200
        client.close()
      except CatchableError: sleep(100)
    check up
    let origin = "http://127.0.0.1:" & $port
    writeFile(root / "posts/2020-04-04-out.md", "---\ntitle: Out\ndescription: Outbound links\n---\n\n" &
      "[up](" & origin & "/ok.html) [down](" & origin & "/missing.html)\n")
    let offline = checkSite(root)
    check offline.messages(svError).len == 0
    check offline.externalLinks == 2
    let online = checkSite(root, CheckOptions(external: true))
    check online.messages(svError) == @[origin & "/missing.html: external link: HTTP 404"]
    check inSite(root, "--external").exitCode == 1

    # [check] skip_external: a URL prefix (written in another case) and a
    # host name are not requested. Both name pages the server does not
    # have, so a request would be reported as HTTP 404.
    let config = readFile(root / "site.toml")
    writeFile(root / "site.toml", config & "\n[check]\nskip_external = [" &
      $(%("HTTP://127.0.0.1:" & $port & "/Skipped/")) & ", \"localhost\"]\n")
    let hostOrigin = "http://localhost:" & $port
    writeFile(root / "posts/2020-04-04-out.md", "---\ntitle: Out\ndescription: Outbound links\n---\n\n" &
      "[up](" & origin & "/ok.html) [down](" & origin & "/missing.html) " &
      "[prefix](" & origin & "/Skipped/gone.html) [host](" & hostOrigin & "/gone.html) " &
      "[case](" & origin & "/skipped/gone.html)\n")
    let skipping = checkSite(root, CheckOptions(external: true))
    # The prefix keeps the case of its path: /skipped/ is not /Skipped/.
    check skipping.messages(svError).sorted() == @[origin & "/missing.html: external link: HTTP 404",
      origin & "/skipped/gone.html: external link: HTTP 404"]
    check skipping.messages(svInfo).filterIt("not requested" in it).sorted() == @[
      origin & "/Skipped/gone.html: external link not requested (check.skip_external)",
      hostOrigin & "/gone.html: external link not requested (check.skip_external)"]
    check skipping.externalLinks == 5
    let skipped = inSite(root, "--external")
    check skipped.output.contains("info: " & hostOrigin & "/gone.html: external link not requested")
    # Positive control: without the list the same links are requested.
    writeFile(root / "site.toml", config)
    let requested = checkSite(root, CheckOptions(external: true))
    check requested.messages(svError).sorted() == @[origin & "/Skipped/gone.html: external link: HTTP 404",
      origin & "/missing.html: external link: HTTP 404",
      origin & "/skipped/gone.html: external link: HTTP 404",
      hostOrigin & "/gone.html: external link: HTTP 404"]
    # An invalid entry fails the check's build, naming the setting.
    writeFile(root / "site.toml", config & "\n[check]\nskip_external = [\"example.com/path\"]\n")
    let invalid = checkSite(root, CheckOptions(external: true))
    check invalid.messages(svError).len == 1
    check invalid.messages(svError)[0].contains("check.skip_external: example.com/path is neither a host name")
