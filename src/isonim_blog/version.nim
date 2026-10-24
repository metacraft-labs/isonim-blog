## Package version, read from the single authoritative Nimble manifest.
import std/strutils

const isonimBlogVersion* = block:
  var value = ""
  for line in staticRead("../../isonim_blog.nimble").splitLines():
    if line.startsWith("version = "):
      value = line.split('=')[1].strip().strip(chars = {'"'})
  doAssert value.len > 0, "isonim_blog.nimble must declare the package version"
  value
