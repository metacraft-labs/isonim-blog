## `isonim-blog serve` end to end: this checkout's CLI, compiled by the test
## and run as a real server process on a free loopback port over a copy of the
## generic fixture site, driven by real file edits. The test talks to it as a
## browser does: HTTP requests for pages and an RFC 6455 WebSocket for live
## reload (the client below performs the real handshake and reads real
## frames). No test doubles.
import std/[unittest, net, base64, httpclient, times, monotimes, random, streams]
import isonim_blog
import isonim/static/buildinfo
import isonim/server/static_dist_dev_server
import ./site_helpers

proc freePort(): int =
  ## A port the kernel just handed out; the server binds it right after.
  let socket = newSocket()
  socket.bindAddr(Port(0), "127.0.0.1")
  result = socket.getLocalAddr()[1].int
  socket.close()

proc get(port: int; path: string): tuple[status: int, body: string] =
  let client = newHttpClient(timeout = 10_000)
  defer: client.close()
  let response = client.request("http://127.0.0.1:" & $port & path)
  (response.code.int, response.body)

type LiveReload = object
  socket: Socket

proc connectLiveReload(port: int): LiveReload =
  ## Open the page's live-reload WebSocket and check the server's handshake
  ## answer (RFC 6455 §4.2.2: Sec-WebSocket-Accept from the client key).
  var raw = newString(16)
  for c in raw.mitems: c = char(rand(255))
  let key = base64.encode(raw)
  result.socket = newSocket()
  result.socket.connect("127.0.0.1", Port(port), timeout = 10_000)
  result.socket.send("GET /__isonim_livereload HTTP/1.1\r\nHost: 127.0.0.1:" & $port &
    "\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: " & key &
    "\r\nSec-WebSocket-Version: 13\r\n\r\n")
  var response = ""
  while not response.endsWith("\r\n\r\n"):
    response.add result.socket.recv(1, timeout = 10_000)
  doAssert response.startsWith("HTTP/1.1 101"), response
  doAssert ("Sec-WebSocket-Accept: " & wsAcceptKey(key)) in response, response

proc nextMessage(live: LiveReload; timeoutMs: int): string =
  ## The next text frame's payload, or "" when none arrives in time.
  try:
    let header = live.socket.recv(2, timeout = timeoutMs)
    if header.len < 2: return ""
    doAssert header[0] == chr(0x81), "expected one unmasked text frame"
    let length = header[1].ord
    doAssert length < 126, "unexpectedly long frame"
    live.socket.recv(length, timeout = 10_000)
  except TimeoutError: ""

proc waitFor(condition: proc(): bool; seconds: int): bool =
  let deadline = getMonoTime() + initDuration(seconds = seconds)
  while getMonoTime() < deadline:
    if condition(): return true
    sleep(200)
  false

suite "serve":
  test "a post edit reloads once without a recompile; a layout edit recompiles; a broken layout shows the overlay and recovers":
    randomize()
    let work = createTempDir("isonim-blog-serve-", "")
    let site = work / "site"
    copyDir(repoRoot / "examples/basic", site)
    let cli = compileCli(work)
    let port = freePort()
    let env = newStringTable(modeCaseSensitive)
    for key, value in envPairs(): env[key] = value
    env["SOURCE_DATE_EPOCH"] = "1704067200"
    let server = startProcess(cli, workingDir = site, args = ["serve", "--port", $port],
      env = env, options = {poStdErrToStdOut})
    defer:
      server.terminate()
      discard server.waitForExit()
      server.close()
      removeDir(work)
    # The first build compiles the site program; the server answers meanwhile.
    check waitFor(proc(): bool =
      try: get(port, "/posts/first/").status == 200 except CatchableError: false, 300)
    let program = site / "build/isonim-blog/bin/site-program"
    let programHash = sha256Hex(readFile(program))
    let programTime = getLastModificationTime(program)
    let first = get(port, "/posts/first/")
    check first.body.contains("/__isonim_livereload")  # the injected client
    check not readFile(site / "public/posts/first/index.html").contains("__isonim_livereload")
    let aboutTime = getLastModificationTime(site / "public/about/index.html")
    let feed = readFile(site / "public/feed.xml")
    let live = connectLiveReload(port)
    check live.nextMessage(500) == ""  # nothing before an edit

    # Content: one reload, new bytes, the same compiled program.
    writeFile(site / "posts/2020-01-01-first.md",
      readFile(site / "posts/2020-01-01-first.md") & "\nA freshly served sentence.\n")
    check live.nextMessage(120_000) == "reload"
    check live.nextMessage(2_000) == ""  # exactly one reload for one edit
    let edited = get(port, "/posts/first/")
    check edited.status == 200
    check edited.body != first.body
    check edited.body.contains("A freshly served sentence.")
    check sha256Hex(readFile(program)) == programHash
    check getLastModificationTime(program) == programTime
    # Only the output the edit reaches is rewritten: the full-content feed
    # changes, a page that shows no post content keeps its file untouched.
    check readFile(site / "public/feed.xml") != feed
    check readFile(site / "public/feed.xml").contains("A freshly served sentence.")
    check getLastModificationTime(site / "public/about/index.html") == aboutTime

    # A layout: recompiled and reloaded.
    let layout = readFile(site / "layouts/post.nim")
    writeFile(site / "layouts/post.nim", layout.replace("      raw neighbours",
      "      raw neighbours\n      p(class = \"layout-marker\"): text \"Layout edited\""))
    check live.nextMessage(300_000) == "reload"
    check live.nextMessage(2_000) == ""
    let relaid = get(port, "/posts/first/")
    check relaid.body.contains("Layout edited")
    check relaid.body.contains("A freshly served sentence.")
    check sha256Hex(readFile(program)) != programHash
    let goodProgram = sha256Hex(readFile(program))

    # A broken layout: the overlay, with the compiler's message, on every page;
    # the last good output stays on disk.
    let published = readFile(site / "public/posts/first/index.html")
    writeFile(site / "layouts/post.nim", "this is not Nim\n")
    check live.nextMessage(300_000) == "reload"
    let broken = get(port, "/posts/first/")
    check broken.body.contains("Static export failed")
    check broken.body.contains("post.nim")
    check broken.body.contains("/__isonim_livereload")  # it reloads on recovery
    check get(port, "/about/").body.contains("Static export failed")
    check readFile(site / "public/posts/first/index.html") == published

    # Fixing it recovers without a restart.
    writeFile(site / "layouts/post.nim", layout.replace("      raw neighbours",
      "      raw neighbours\n      p(class = \"layout-marker\"): text \"Layout edited\""))
    check live.nextMessage(300_000) == "reload"
    let recovered = get(port, "/posts/first/")
    check not recovered.body.contains("Static export failed")
    check recovered.body.contains("Layout edited")
    check sha256Hex(readFile(program)) == goodProgram
    live.socket.close()

  test "under a base path, serve mounts public/ at the base path and every asset loads":
    let work = createTempDir("isonim-blog-serve-base-", "")
    let site = work / "site"
    copyDir(repoRoot / "examples/basic", site)
    # No url: serve builds for its own origin, with the base path in every URL.
    writeFile(site / "site.toml", "base_path = \"/blog\"\ntheme = \"isonim-blog-theme-minimal\"\n" &
      readFile(site / "site.toml").replace("url = \"https://example.org\"\n", ""))
    let cli = compileCli(work)
    let port = freePort()
    let server = startProcess(cli, workingDir = site,
      args = ["serve", "--port", $port, "--now", "@1704067200"], options = {poStdErrToStdOut})
    var stopped = false
    proc stop(): string =
      if not stopped:
        stopped = true
        server.terminate()
        discard server.waitForExit()
        result = server.outputStream.readAll()
        server.close()
    defer:
      discard stop()
      removeDir(work)
    check waitFor(proc(): bool =
      try: get(port, "/blog/posts/first/").status == 200 except CatchableError: false, 300)
    # The files sit at public/'s root and are served only under the base path.
    check fileExists(site / "public/posts/first/index.html")
    check not dirExists(site / "public/blog")
    check get(port, "/blog/").status == 200
    check get(port, "/blog").status == 200
    check get(port, "/posts/first/").status == 404
    check get(port, "/blogger/posts/first/").status == 404
    # Every root-relative reference of the served pages loads from the server:
    # stylesheets, images and their variants, feeds, other pages.
    var requested = 0
    for path in ["/blog/", "/blog/posts/bundle/", "/blog/about/", "/blog/tags/nim/"]:
      let page = get(port, path)
      check page.status == 200
      check page.body.contains("/__isonim_livereload")
      var references: seq[string]
      for marker in ["href=\"", "src=\"", "srcset=\""]:
        var at = page.body.find(marker)
        while at >= 0:
          let start = at + marker.len
          let value = page.body[start ..< page.body.find('"', start)]
          for candidate in value.split(','):
            let url = candidate.strip().splitWhitespace()
            if url.len > 0: references.add url[0]
          at = page.body.find(marker, start)
      for reference in references:
        var url = reference
        if url.startsWith("http://localhost:" & $port):
          url = url["http://localhost:".len + ($port).len .. ^1]
        if not url.startsWith("/") or url.startsWith("//") or url.startsWith("/__isonim"): continue
        check url.startsWith("/blog/")
        let fetched = get(port, url.split('#')[0])
        if fetched.status != 200: echo "not served: ", path, " -> ", url
        check fetched.status == 200
        inc requested
    check requested >= 30
    # The canonical link names the served origin and the base path.
    check get(port, "/blog/posts/first/").body.contains(
      "<link rel=\"canonical\" href=\"http://localhost:" & $port & "/blog/posts/first/\"")
    check stop().contains("at http://127.0.0.1:" & $port & "/blog/ (live reload on")

  test "serve binds loopback unless --lan, and rejects bad arguments":
    check serveHost(ServeOptions()) == "127.0.0.1"
    check serveHost(ServeOptions(lan: true)) == "0.0.0.0"
    check servePort(ServeOptions()) == 4000
    check rebuildCommand(ServeOptions(executable: "/x/isonim-blog", drafts: true)) ==
      @["/x/isonim-blog", "build", "--incremental", "--drafts"]
    let roots = watchRoots("/site", "/theme")
    check "/site/site.toml" in roots
    check "/site/posts" in roots
    check "/theme/layouts" in roots
    check "/site/public" notin roots
    check "/site/build" notin roots
    for args in [@["serve", "--port"], @["serve", "--port", "x"], @["serve", "--port", "70000"],
        @["serve", "--open"]]:
      let response = runCli(args)
      check response.exitCode == 1
      check response.error.len > 0

  test "serve needs no url: it builds for its own origin unless site.toml names one":
    let site = fixtureCopy()
    defer: removeDir(site)
    putEnv("SOURCE_DATE_EPOCH", "1704067200")
    defer: delEnv("SOURCE_DATE_EPOCH")
    let options = ServeOptions(executable: "/x/isonim-blog", port: 4123, now: "@1704067200")
    # With site.toml's url, the build uses it.
    check siteRebuildCommand(site, options) ==
      @["/x/isonim-blog", "build", "--incremental", "--now", "@1704067200"]
    # Without it, `build` refuses, and serve's rebuild names its own origin.
    writeFile(site / "site.toml", readFile(site / "site.toml").replace("url = \"https://example.org\"\n", ""))
    check "url =" notin readFile(site / "site.toml").replace("url = \"/about/\"", "")
    let command = siteRebuildCommand(site, options)
    check command == @["/x/isonim-blog", "build", "--incremental", "--now", "@1704067200",
      "--url", "http://localhost:4123"]
    check siteRebuildCommand(site, ServeOptions(executable: "/x/isonim-blog"))[^1] == "http://localhost:4000"
    let previous = getCurrentDir()
    setCurrentDir(site)
    defer: setCurrentDir(previous)
    let refused = runCli(["build"])
    check refused.exitCode == 1
    check refused.error.contains("url is required")
    # The serve rebuild itself, run by the real dispatcher.
    let built = runCli(command[1 .. ^1])
    check built.exitCode == 0
    check readFile(site / "public/posts/first/index.html").contains(
      "<link rel=\"canonical\" href=\"http://localhost:4123/posts/first/\"")
    check not built.output.contains("is a placeholder")
    let badNow = runCli(["serve", "--now", "soon"])
    check badNow.exitCode == 1
    check badNow.error.contains("--now")
    check runCli(["serve", "--now", "20261028"]).error.contains("write '@20261028'")
