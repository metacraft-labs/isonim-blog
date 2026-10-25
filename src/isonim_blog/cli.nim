## Pure command dispatch shared by the executable and library consumers.
import ./version
import ./model
when not defined(js):
  import std/[os, strutils]
  import ./[inputs, program, scaffold, serve, site_check]

type CliResult* = object
  ## Output and status returned without writing streams or exiting the process.
  output*: string
  error*: string
  exitCode*: int

const helpText* = """Usage: isonim-blog [--help | --version]
  or:  isonim-blog new site <dir> [--theme <name|path>] [--deploy cloudflare-pages]
  or:  isonim-blog new post "<title>" [--draft] [--date YYYY-MM-DD] [--bundle]
  or:  isonim-blog new page <path>
  or:  isonim-blog publish-draft <slug>
  or:  isonim-blog serve [--drafts] [--future] [--port 4000] [--lan]
  or:  isonim-blog build [--drafts] [--future] [--out public] [--url <origin>] [--incremental]
  or:  isonim-blog check [--external]
  or:  isonim-blog theme eject <file>

Static blogs with IsoNim. Run every command except `new site` in the site's
directory (the one holding site.toml).

  new site        create a site: site.toml, a sample post, flake.nix, repro.nim,
                  Justfile and .gitignore; --deploy adds the Cloudflare Pages recipe;
                  the theme is isonim-blog-theme-minimal unless --theme names another
  new post        create posts/<date>-<slug>.md (drafts/<slug>.md with --draft,
                  a directory with index.md with --bundle)
  new page        create pages/<path>.md
  publish-draft   move a draft to posts/, dated today
  serve           build, serve public/ on loopback (--lan: every interface),
                  rebuild on every change and reload open pages
  build           build the site into public/; --incremental rewrites only
                  changed files (what serve uses)
  check           build as production does and check internal links and
                  anchors, front matter, alt text, scripts and feeds;
                  --external also requests every external link
  theme eject     copy a file of the site's theme (layouts/, includes/,
                  assets/ or og.svg.nim) into the site, where it overrides
                  the theme's; delete the copy to return to the theme's
"""

when not defined(js):
  proc valueAfter(args: openArray[string]; i: var int): string =
    let flag = args[i]
    inc i
    if i >= args.len: fail("missing value for " & flag)
    args[i]

  proc runBuild(args: openArray[string]): string =
    var options: BuildOptions
    var i = 1
    while i < args.len:
      case args[i]
      of "--drafts": options.drafts = true
      of "--future": options.future = true
      of "--incremental": options.incremental = true
      of "--out": options.outDir = valueAfter(args, i)
      of "--url": options.url = valueAfter(args, i)
      else: fail("unsupported build argument: " & args[i])
      inc i
    buildSite(getCurrentDir(), options)

  proc runNew(args: openArray[string]): string =
    if args.len < 2: fail("new needs site, post or page")
    case args[1]
    of "site":
      var options: NewSiteOptions
      var directory = ""
      var i = 2
      while i < args.len:
        case args[i]
        of "--theme": options.theme = valueAfter(args, i)
        of "--deploy":
          let target = valueAfter(args, i)
          if target != "cloudflare-pages": fail("unsupported deploy target: " & target & " (supported: cloudflare-pages)")
          options.deploy = dtCloudflarePages
        else:
          if args[i].startsWith("-") or directory.len > 0: fail("unsupported new site argument: " & args[i])
          directory = args[i]
        inc i
      if directory.len == 0: fail("new site needs a directory")
      let created = newSite(directory, options)
      result = "Created " & directory & ":\n"
      for path in created: result.add "  " & path & "\n"
      result.add "Next: cd " & directory & " && nix develop, then isonim-blog serve\n"
    of "post":
      var options: NewPostOptions
      var title = ""
      var titled = false
      var i = 2
      while i < args.len:
        case args[i]
        of "--draft": options.draft = true
        of "--bundle": options.bundle = true
        of "--date": options.date = valueAfter(args, i)
        else:
          if args[i].startsWith("--") or titled: fail("unsupported new post argument: " & args[i])
          title = args[i]
          titled = true
        inc i
      if not titled: fail("new post needs a title")
      result = "Created " & newPost(getCurrentDir(), title, options) & "\n"
    of "page":
      if args.len != 3: fail("usage: isonim-blog new page <path>")
      result = "Created " & newPage(getCurrentDir(), args[2]) & "\n"
    else: fail("new needs site, post or page, not " & args[1])

  proc runServe(args: openArray[string]) =
    var options: ServeOptions
    var i = 1
    while i < args.len:
      case args[i]
      of "--drafts": options.drafts = true
      of "--future": options.future = true
      of "--lan": options.lan = true
      of "--port":
        let value = valueAfter(args, i)
        try: options.port = parseInt(value)
        except ValueError: fail("--port needs a number: " & value)
        if options.port notin 1..65535: fail("--port must be 1-65535: " & value)
      else: fail("unsupported serve argument: " & args[i])
      inc i
    serveSite(getCurrentDir(), options)

  proc runCheck(args: openArray[string]): CliResult =
    var options: CheckOptions
    for arg in args[1..^1]:
      if arg == "--external": options.external = true
      else: fail("unsupported check argument: " & arg)
    let report = checkSite(getCurrentDir(), options)
    result.output = formatReport(report)
    if report.errors > 0: result.exitCode = 1

proc runCli*(args: openArray[string]): CliResult =
  ## Evaluate one invocation. Unknown or extra arguments are errors. `serve`
  ## runs until the process is stopped.
  if args.len == 0 or (args.len == 1 and args[0] in ["--help", "-h"]):
    result.output = helpText
    return
  if args.len == 1 and args[0] == "--version":
    result.output = "isonim-blog " & isonimBlogVersion & "\n"
    return
  if args[0] notin ["build", "new", "publish-draft", "serve", "check", "theme"]:
    result.error = "Unsupported arguments. Run isonim-blog --help for available options.\n"
    result.exitCode = 1
    return
  try:
    when defined(js): fail("site commands require the native CLI")
    else:
      case args[0]
      of "build": result.output = runBuild(args)
      of "new": result.output = runNew(args)
      of "publish-draft":
        if args.len != 2: fail("usage: isonim-blog publish-draft <slug>")
        result.output = "Published " & publishDraft(getCurrentDir(), args[1]) & "\n"
      of "serve": runServe(args)
      of "check": result = runCheck(args)
      of "theme":
        if args.len != 3 or args[1] != "eject": fail("usage: isonim-blog theme eject <file>")
        let rel = ejectThemeFile(getCurrentDir(), args[2])
        result.output = "Ejected " & rel & ": the site's copy now overrides the theme's; " &
          "delete it to use the theme's again\n"
  except CatchableError as cause:
    result.error = cause.msg & "\n"
    result.exitCode = 1
