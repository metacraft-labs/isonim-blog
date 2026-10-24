## Build and test graph. config.nims owns source selection for all compilers.
import repro_project_dsl
import repro_dsl_stdlib/foreign_env
import ct_test_nim_unittest

package isonim_blog:
  defaultToolProvisioning "path"
  uses:
    "nim >=2.0"
    when defined(macosx):
      "clang >=16"
    else:
      "gcc >=12"
    "node >=20"
    "isonim"
    "nim-everywhere"

  devEnv:
    useFlakeDevShell()

  library isonim_blog

  build:
    let cli = nim.c(
      source = "src/isonim_blog_cli.nim",
      output = "build/bin/isonim-blog",
      nimcache = "build/nimcache/cli",
      actionId = "isonim-blog.cli")
    defaultBuildAction(cli)

    let native = buildNimUnittest.build(
      source = "tests/test_plumbing.nim",
      binary = "build/tests/test_plumbing",
      nimcache = "build/nimcache/test-c",
      warningsOff = false,
      actionId = "isonim-blog.test-c-build")
    let nativeRun = native.testBinary.run(
      actionId = "isonim-blog.test-c-run", registerImplicitName = false)
    let javascript = nim.js(
      source = "tests/test_plumbing.nim",
      output = "build/tests/test_plumbing.js",
      # The JS tool has no nimcache argument; config.nims sets its local cache.
      actionId = "isonim-blog.test-js-build")
    let javascriptRun = node(
      args = @["build/tests/test_plumbing.js"],
      after = @[javascript], extraInputs = @["build/tests/test_plumbing.js"],
      actionId = "isonim-blog.test-js-run")
    discard collect("test", @[nativeRun, javascriptRun])
    discard collect("test-builds", @[native.action, javascript])
