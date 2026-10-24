## Real compiler/filesystem integration helpers, without test doubles.
import std/[os, strutils, tempfiles]
import isonim_blog/[program, inputs]
export os, strutils, tempfiles, program, inputs
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
