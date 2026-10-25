## `isonim-blog serve`: build, serve `public/`, watch and live-reload.
##
## The server, the poll watcher, the WebSocket live-reload channel and the
## error overlay are IsoNim's shared `isonim/server/static_dist_dev_server`.
## Its rebuild command is this CLI's own `build --incremental`, so:
##
## * a content edit runs the already-compiled site program (the compile
##   cache key covers layouts and includes only), and only output files whose
##   bytes changed are rewritten: the edited pages, and the listings, feeds and
##   sitemap the edit reaches;
## * a layout, include or OpenGraph template edit changes the key, so the
##   program is recompiled before the export;
## * a failing build (a broken layout, invalid front matter) keeps the last
##   good output on disk and the server shows its error as an overlay on every
##   page until a later build succeeds.
import std/[os, asyncdispatch]
import isonim/server/static_dist_dev_server
import ./[model, inputs, program]

type
  ServeOptions* = object
    drafts*, future*: bool
    port*: int          ## 0 selects the default, 4000
    lan*: bool          ## bind every interface instead of loopback only
    executable*: string
      ## The isonim-blog executable that rebuilds; empty selects the running
      ## executable (the CLI).

const defaultServePort* = 4000

proc serveHost*(options: ServeOptions): string =
  ## Loopback unless `--lan` opts in.
  if options.lan: "0.0.0.0" else: "127.0.0.1"

proc servePort*(options: ServeOptions): int =
  if options.port == 0: defaultServePort else: options.port

proc rebuildCommand*(options: ServeOptions): seq[string] =
  ## The argv the dev server runs, in the site directory, on every change.
  let executable = if options.executable.len > 0: options.executable else: getAppFilename()
  result = @[executable, "build", "--incremental"]
  if options.drafts: result.add "--drafts"
  if options.future: result.add "--future"

proc watchRoots*(root: string; theme = ""): seq[string] =
  ## Everything a build may read: site.toml, og.svg.nim, the declared
  ## directories and the theme's code and assets. The output and build
  ## caches are never watched. Collections are covered by `collections/`.
  for name in ["site.toml", "og.svg.nim"]: result.add root / name
  for dir in ["posts", "drafts", "pages", "collections", "layouts", "includes",
      "data", "assets", "static"]:
    result.add root / dir
  if theme.len > 0:
    for dir in ["layouts", "includes", "assets"]: result.add theme / dir
    result.add theme / "og.svg.nim"

proc newSiteDevServer*(root: string; options: ServeOptions): StaticDistDevServer =
  ## The configured server for the site at `root`, without starting it.
  newStaticDistDevServer(rebuildCommand = rebuildCommand(options),
    distDir = root / "public",
    watchRoots = watchRoots(root, resolveTheme(root)),
    watchExts = @[],  # every file: static/ may hold _headers or favicon.ico
    siteName = readSiteConfig(root).title)

proc serveSite*(root: string; options = ServeOptions()) =
  ## Run the dev server until the process is stopped. The rebuild command
  ## runs in the current directory, so it changes to `root` first.
  let root = absolutePath(root)
  let server = newSiteDevServer(root, options)
  setCurrentDir(root)
  stdout.writeLine "Serving " & server.siteName & " at http://" &
    (if options.lan: "0.0.0.0" else: "127.0.0.1") & ":" & $servePort(options) &
    "/ (live reload on" & (if options.drafts: ", drafts" else: "") &
    (if options.future: ", future posts" else: "") & "; Ctrl-C stops)"
  stdout.flushFile()
  waitFor server.serve(servePort(options), serveHost(options))
