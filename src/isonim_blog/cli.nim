## Pure command dispatch shared by the executable and library consumers.
## Only help and version are available during the repository bootstrap.
import ./version

type CliResult* = object
  ## Output and status returned without writing streams or exiting the process.
  output*: string
  error*: string
  exitCode*: int

const helpText* = """Usage: isonim-blog [--help | --version]

Static blogs with IsoNim.
This bootstrap provides help and version reporting only.
Site generation commands are not available yet.
"""

proc runCli*(args: openArray[string]): CliResult =
  ## Evaluate one invocation. Unknown or extra arguments are errors.
  if args.len == 0 or (args.len == 1 and args[0] in ["--help", "-h"]):
    result.output = helpText
  elif args.len == 1 and args[0] == "--version":
    result.output = "isonim-blog " & isonimBlogVersion & "\n"
  else:
    result.error = "Unsupported arguments. Run isonim-blog --help for available options.\n"
    result.exitCode = 1
