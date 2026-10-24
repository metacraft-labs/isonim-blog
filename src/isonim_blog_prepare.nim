## Code preparation entry point for declared Repro and Nix build stages.
import std/[os, json]
import isonim_blog/[program, model]
when isMainModule:
  try:
    let args = commandLineParams()
    if args.len == 3 and args[0] == "--bundle":
      discard generateBundle(args[1], parseFile(args[2]))
      quit(0)
    if args.len notin [2, 3]: fail("usage: isonim-blog-prepare SITE OUTPUT [THEME]")
    discard prepareProgram(args[0], args[1], if args.len == 3: args[2] else: "")
  except CatchableError as cause:
    stderr.writeLine(cause.msg)
    quit(1)
