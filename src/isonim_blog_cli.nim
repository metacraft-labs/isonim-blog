## Native executable; argument handling remains available through the library.
import std/os
import isonim_blog

when isMainModule:
  let response = runCli(commandLineParams())
  stdout.write(response.output)
  stderr.write(response.error)
  quit(response.exitCode)
