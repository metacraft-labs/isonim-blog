## Blog output policy checks complete script elements, including inert data.
## The framework's executable-script scanner intentionally has a wider data
## exemption; blog pages allow only JSON-LD plus explicitly declared scripts.
import std/[htmlparser, xmltree, strutils]
export xmltree

proc scriptElements*(html: string): seq[XmlNode] =
  let document = parseHtml(html)
  var pending = @[document]
  while pending.len > 0:
    let node = pending.pop()
    if node.kind != xnElement: continue
    if node.tag.toLowerAscii == "script": result.add node
    for child in node: pending.add child
