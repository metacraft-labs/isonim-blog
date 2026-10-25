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
    "python >=3.11"
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
    var testRuns = @[nativeRun, javascriptRun]
    var testBuilds = @[native.action, javascript]
    for name in ["test_model_pure", "test_site_model", "test_zero_js_default", "test_cli_build",
        "test_taxonomies", "test_feeds", "test_static_images", "test_static_ogimage",
        "test_check", "test_serve_reload", "test_cli_scaffold", "test_deploy_recipe",
        "test_theme_format", "test_theme_override", "test_theme_kit"]:
      let compiled = buildNimUnittest.build(
        source = "tests/" & name & ".nim", binary = "build/tests/" & name,
        nimcache = "build/nimcache/" & name, warningsOff = false,
        actionId = "isonim-blog." & name & "-build")
      testBuilds.add compiled.action
      testRuns.add compiled.testBinary.run(actionId = "isonim-blog." & name & "-run", registerImplicitName = false)
    let modelJs = nim.js(source = "tests/test_model_pure.nim",
      output = "build/tests/test_model_pure.js", actionId = "isonim-blog.model-js-build")
    testBuilds.add modelJs
    testRuns.add node(args = @["build/tests/test_model_pure.js"], after = @[modelJs],
      extraInputs = @["build/tests/test_model_pure.js"], actionId = "isonim-blog.model-js-run")
    # The theme format (manifest, defaults, tokens) is backend-independent too.
    let themeJs = nim.js(source = "tests/test_theme_format.nim",
      output = "build/tests/test_theme_format.js", actionId = "isonim-blog.theme-format-js-build")
    testBuilds.add themeJs
    testRuns.add node(args = @["build/tests/test_theme_format.js"], after = @[themeJs],
      extraInputs = @["build/tests/test_theme_format.js"], actionId = "isonim-blog.theme-format-js-run")

    # The example site as three edges with different inputs: preparation
    # reads only layouts/ and includes/, the compile reads the prepared
    # program and the library sources, and the export reads the content.
    # So a content-only edit re-runs the export and is a cache hit for the
    # compile. The prepare and export tools are built by this graph, so they
    # run as literal-argv execute edges that depend on their producing edge,
    # not as provisioned external tools.
    let prepareBinary = nim.c(source = "src/isonim_blog_prepare.nim",
      output = "build/bin/isonim-blog-prepare", nimcache = "build/nimcache/prepare",
      actionId = "isonim-blog.prepare-build")
    let prepared = buildAction("isonim-blog.site-prepare",
      inlineExecCall(@["build/bin/isonim-blog-prepare", "examples/basic", "build/site-basic"]),
      deps = @[prepareBinary.id],
      inputs = @["build/bin/isonim-blog-prepare"],
      outputs = @["build/site-basic/site_program.nim"])
    let siteProgram = nim.c(source = "build/site-basic/site_program.nim",
      output = "build/bin/site-basic", nimcache = "build/nimcache/site-basic",
      after = @[prepared],
      actionId = "isonim-blog.site-compile")
    let siteOutput = buildAction("isonim-blog.site-export",
      inlineExecCall(@["build/bin/site-basic", "build/example-basic", "--root", "examples/basic"]),
      deps = @[siteProgram.id],
      inputs = @["build/bin/site-basic"],
      outputs = @["build/example-basic/build.json"],
      # A fixed build time keeps the export independent of file mtimes, and a
      # fixed hash seed removes CPython's startup entropy read (TOML decoding
      # and time zones run in Python) instead of waiving it.
      env = @[("SOURCE_DATE_EPOCH", "1704067200"), ("PYTHONHASHSEED", "0")])
    discard collect("example-basic", @[siteOutput])
    discard collect("site-compile", @[siteProgram])
    discard collect("test", testRuns)
    discard collect("test-builds", testBuilds)
