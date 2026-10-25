## Real compiler/filesystem integration helpers, without test doubles.
import std/[os, strutils, tempfiles, json, tables]
import isonim_blog/[program, inputs]
export os, strutils, tempfiles, tables, program, inputs
const repoRoot* = currentSourcePath().parentDir.parentDir

# config.nims records the dependency trees this test binary was compiled
# against. Site programs compiled by the tests (directly or through the
# `build` command) use the same trees and this checkout's own src/, never a
# snapshot taken when the shell was entered.
const isonimBlogIsonimSrc {.strdefine.} = ""
const isonimBlogNimEverywhereSrc {.strdefine.} = ""
doAssert isonimBlogIsonimSrc.len > 0 and isonimBlogNimEverywhereSrc.len > 0,
  "config.nims must define the selected dependency trees"
putEnv("ISONIM_BLOG_SRC", repoRoot)
putEnv("ISONIM_BLOG_ISONIM_SRC", isonimBlogIsonimSrc)
putEnv("ISONIM_BLOG_NIM_EVERYWHERE_SRC", isonimBlogNimEverywhereSrc)

proc fixtureCopy*(): string =
  result = createTempDir("isonim-blog-test-", "")
  copyDir(repoRoot / "examples/basic", result)

proc compileSite*(root: string): string =
  let prepared = root / "build/program"
  let source = prepareProgram(root, prepared)
  result = root / "build/site-program"
  var args = @["c", "--hints:off", "--out:" & result, "--nimcache:" & root / "build/nimcache"]
  for path in sourcePaths(): args.add "--path:" & path
  args.add source
  discard runTool(findExe("nim"), args)

proc runSite*(binary, root, output: string; args: seq[string] = @[]): string =
  runTool(binary, @[output, "--root", root] & args)

const htmlReader = """
import json, sys
from html.parser import HTMLParser
class Reader(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.found = []
    def handle_starttag(self, tag, attrs):
        if tag in sys.argv[2:]:
            item = {name: (value if value is not None else "") for name, value in attrs}
            item["<tag>"] = tag
            self.found.append(item)
    handle_startendtag = handle_starttag
reader = Reader()
with open(sys.argv[1], encoding="utf-8") as page:
    reader.feed(page.read())
print(json.dumps(reader.found))
"""

proc htmlElements*(file: string; tags: varargs[string]): seq[Table[string, string]] =
  ## The start tags named `tags` in a built page, in document order, with
  ## their attributes decoded: read by Python's standard `html.parser`, an
  ## independent HTML tokenizer, not by the code that wrote the page.
  for item in parseJson(runPython(@["-c", htmlReader, file] & @tags)):
    var element = initTable[string, string]()
    for key, value in item: element[key] = value.getStr
    result.add element

# -- Processes, the CLI and Nix (used by the CLI, serve and deploy suites) --

import std/[osproc, streams, strtabs]
export osproc, strtabs

type ProcessResult* = object
  output*: string  ## stdout and stderr, interleaved
  code*: int

proc runProcess*(executable: string; args: openArray[string]; cwd = "";
    input = ""; extraEnv: openArray[(string, string)] = [];
    removeEnv: openArray[string] = []): ProcessResult =
  ## Run a real process (no shell) with this process's environment plus
  ## `extraEnv`, minus `removeEnv`, feeding `input` on stdin.
  let env = newStringTable(modeCaseSensitive)
  for key, value in envPairs(): env[key] = value
  for key in removeEnv:
    if env.hasKey(key): env.del(key)
  for (key, value) in extraEnv: env[key] = value
  let process = startProcess(executable, workingDir = cwd, args = args, env = env,
    options = {poStdErrToStdOut, poUsePath})
  try:
    process.inputStream.write(input)
    process.inputStream.close()
    result.output = process.outputStream.readAll()
    result.code = process.waitForExit()
  finally: process.close()

proc tool*(name: string): string =
  ## A tool the dev shell (or the package's build environment) provides.
  result = findExe(name)
  doAssert result.len > 0, name & " is required on PATH; enter nix develop"

proc compileCli*(directory: string): string =
  ## This checkout's CLI, compiled with the dependency trees config.nims
  ## selects (the same ones this test binary was compiled against).
  result = directory / "isonim-blog"
  let compiled = runProcess(tool("nim"), ["c", "--hints:off", "-d:release",
    "--out:" & result, "--nimcache:" & repoRoot / "build/nimcache/test-cli",
    repoRoot / "src/isonim_blog_cli.nim"])
  doAssert compiled.code == 0, compiled.output

proc frameworkCopy*(directory: string): string =
  ## This checkout's files (tracked, plus new files git does not ignore) as a
  ## plain directory, for `--override-input isonim-blog path:<copy>`: the
  ## generated flake then builds against the code under test, uncommitted
  ## changes included, and Nix needs no network to fetch the framework.
  result = directory / "framework-copy"
  let listed = runProcess(tool("git"), ["-C", repoRoot, "ls-files", "-z",
    "--cached", "--others", "--exclude-standard"])
  doAssert listed.code == 0, listed.output
  for rel in listed.output.split('\0'):
    if rel.len == 0 or not fileExists(repoRoot / rel): continue
    createDir(parentDir(result / rel))
    copyFileWithPermissions(repoRoot / rel, result / rel)

const gitIdentity* = [("GIT_AUTHOR_NAME", "Test Author"), ("GIT_AUTHOR_EMAIL", "author@example.org"),
  ("GIT_COMMITTER_NAME", "Test Author"), ("GIT_COMMITTER_EMAIL", "author@example.org"),
  ("GIT_CONFIG_GLOBAL", "/dev/null"), ("GIT_CONFIG_NOSYSTEM", "1")]
  ## A fixed git identity and no user or system git configuration (signing,
  ## hooks, default branch), so tests never depend on the host.

proc gitCommitAll*(root, message: string) =
  ## Commit everything in `root` (initialising the repository if needed)
  ## with a fixed identity, so tests never depend on the user's git config.
  let git = tool("git")
  let identity = gitIdentity
  if not dirExists(root / ".git"):
    doAssert runProcess(git, ["init", "--quiet", "--initial-branch=main", root], extraEnv = identity).code == 0
  doAssert runProcess(git, ["-C", root, "add", "--all"], extraEnv = identity).code == 0
  let committed = runProcess(git, ["-C", root, "-c", "commit.gpgsign=false", "commit",
    "--quiet", "--allow-empty", "-m", message], extraEnv = identity)
  doAssert committed.code == 0, committed.output
