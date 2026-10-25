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
