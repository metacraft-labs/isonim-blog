## Pure command dispatch shared by the executable and library consumers.
import ./version
import ./model
when not defined(js):
  import std/os
  import ./program

type CliResult* = object
  ## Output and status returned without writing streams or exiting the process.
  output*: string
  error*: string
  exitCode*: int

const helpText* = """Usage: isonim-blog [--help | --version]
  or:  isonim-blog build [--drafts] [--future] [--out public] [--url <origin>]

Static blogs with IsoNim.
Build the current site.toml and its explicit content directories.
"""

proc runCli*(args: openArray[string]): CliResult =
  ## Evaluate one invocation. Unknown or extra arguments are errors.
  if args.len == 0 or (args.len == 1 and args[0] in ["--help", "-h"]):
    result.output = helpText
  elif args.len == 1 and args[0] == "--version":
    result.output = "isonim-blog " & isonimBlogVersion & "\n"
  elif args.len > 0 and args[0] == "build":
    try:
      var options: BuildOptions
      var i = 1
      while i < args.len:
        case args[i]
        of "--drafts": options.drafts = true
        of "--future": options.future = true
        of "--out", "--url":
          let flag = args[i]
          inc i
          if i >= args.len: fail("missing value for " & flag)
          if flag == "--out": options.outDir = args[i]
          else: options.url = args[i]
        else: fail("unsupported build argument: " & args[i])
        inc i
      when defined(js): fail("site building requires the native CLI")
      else: result.output = buildSite(getCurrentDir(), options)
    except CatchableError as cause:
      result.error = cause.msg & "\n"
      result.exitCode = 1
  else:
    result.error = "Unsupported arguments. Run isonim-blog --help for available options.\n"
    result.exitCode = 1
