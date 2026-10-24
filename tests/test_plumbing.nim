## Real dependency and command plumbing on both C and JS. No test doubles:
## dependency APIs execute from the selected sibling or locked source trees.
import std/[strutils, unittest]
import isonim_blog
import isonim/ssr/escape
import nim_everywhere/platform

suite "bootstrap plumbing":
  test "both dependencies execute through the configured source paths":
    # JS Map keys use the native string representation (cstring), while
    # native builds use Nim strings through the same platform conversion.
    var labels = newHashMap[NativeString, string]()
    labels[toNative("title")] = escapeHtml("A <small> & useful blog")
    check labels[toNative("title")] == "A &lt;small&gt; &amp; useful blog"

  test "help describes only the available commands":
    let response = runCli(["--help"])
    check response.exitCode == 0
    check response.error == ""
    check response.output.contains("--version")
    check response.output.contains("Site generation commands are not available yet.")
    check runCli(newSeq[string]()).output == response.output

  test "version comes from the package manifest":
    let response = runCli(["--version"])
    check isonimBlogVersion == "0.1.0"
    check response.output == "isonim-blog 0.1.0\n"
    check response.exitCode == 0

  test "unsupported and extra arguments fail without pretending to build":
    for args in [@["build"], @["--version", "extra"], @["--unknown"]]:
      let response = runCli(args)
      check response.exitCode == 1
      check response.output == ""
      check response.error.len > 0
