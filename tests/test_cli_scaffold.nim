## `new site`, `new post`, `new page` and `publish-draft` end to end: the real
## command dispatcher, the real filesystem, the real Nim compiler (through
## `build`), and real Nix, git, just and nixfmt. No test doubles.
##
## The last case builds the generated flake with `nix build` in the Nix
## sandbox. Its `isonim-blog` input is overridden with a plain copy of this
## checkout (`path:`), so the build uses the code under test, uncommitted
## changes included, and needs no network for the framework. That case needs
## a Nix daemon, so this suite runs under `nix develop` (`just test`), not in
## the package's own sandboxed check phase.
import std/[unittest, json, algorithm, sequtils]
import isonim_blog
import ./site_helpers

proc cli(args: varargs[string]): CliResult = runCli(@args)

proc inDir[T](directory: string; body: proc(): T): T =
  let previous = getCurrentDir()
  setCurrentDir(directory)
  try: result = body()
  finally: setCurrentDir(previous)

proc sortedFiles(root: string): seq[string] =
  for file in walkDirRec(root, relative = true): result.add file.replace('\\', '/')
  result.sort()

# The builds below run without SOURCE_DATE_EPOCH, as a build outside a dev
# shell does; posts are judged against the wall clock either way.
let savedEpoch = getEnv("SOURCE_DATE_EPOCH")
delEnv("SOURCE_DATE_EPOCH")
let savedRevision = getEnv("ISONIM_BLOG_REVISION")
# `new site` pins the commit the CLI was built from, which the packaged CLI
# knows; this in-process CLI is given one. The flake case below overrides the
# input with a copy of this checkout, so the commit need not exist.
const testRevision = "0123456789abcdef0123456789abcdef01234567"
putEnv("ISONIM_BLOG_REVISION", testRevision)

suite "new site":
  test "new site then build succeeds on a fresh directory":
    let work = createTempDir("isonim-blog-scaffold-", "")
    defer: removeDir(work)
    let site = work / "field-notes"
    let before = todayIn("UTC")
    let created = cli("new", "site", site)
    let after = todayIn("UTC")
    check created.exitCode == 0
    check created.error == ""
    let samplePost = sortedFiles(site / "posts")
    check samplePost.len == 1
    check samplePost[0] in [before & "-hello-world.md", after & "-hello-world.md"]
    # Exactly the files of the layout, and no deploy recipe without --deploy.
    check sortedFiles(site) == sorted(@[".gitignore", "Justfile", "flake.nix", "repro.nim",
      "site.toml", "posts/" & samplePost[0]])
    for path in sortedFiles(site): check created.output.contains("  " & path & "\n")
    let config = readSiteConfig(site)
    check config.title == "Field Notes"
    check config.url == "https://example.org"
    # The post list is the home page by the default, which a pages/index.md
    # would move to /posts/; the scaffold sets no [archives] table.
    check config.indexPermalink == "/"
    check config.indexYields
    check "\n[archives]" notin readFile(site / "site.toml")
    # The default theme, by its package name.
    check config.theme == "isonim-blog-theme-minimal"
    # The flake pins the commit the CLI was built from.
    let flake = readFile(site / "flake.nix")
    check flake.contains("isonim-blog.url = \"github:metacraft-labs/isonim-blog/" & testRevision & "\";")
    check flake.contains("isonim-blog.lib.${system}.buildSite { src = self; }")
    check not flake.contains("wrangler")
    check runProcess(tool("nixfmt"), ["--check", site / "flake.nix"]).code == 0
    let recipes = runProcess(tool("just"), ["--justfile", site / "Justfile", "--summary"])
    check recipes.code == 0
    check recipes.output.splitWhitespace().sorted() == @["build", "check", "default", "serve"]
    let repro = readFile(site / "repro.nim")
    check repro.contains("package field_notes:")
    check repro.contains("useFlakeDevShell()")
    for task in ["serve", "build", "check"]: check repro.contains("task \"" & task & "\"")

    let built = inDir(site, proc(): CliResult = cli("build"))
    check built.exitCode == 0
    check built.error == ""
    # The placeholder url builds, with a warning that names it.
    check built.output.contains("warning: url https://example.org is a placeholder")
    let home = readFile(site / "public/index.html")
    check home.contains("Hello, world")
    check home.contains("/posts/hello-world/")
    check readFile(site / "public/posts/hello-world/index.html").contains("This is the first post.")
    # Rendered by the minimal theme, with its stylesheets.
    check home.contains("<a class=\"skip-link\" href=\"#content\">")
    check home.contains("/assets/minimal.")
    check home.contains("/assets/theme-tokens.")
    # The generated .gitignore keeps the output and the build cache out of git.
    gitCommitAll(site, "Start")
    let status = runProcess(tool("git"), ["-C", site, "status", "--porcelain", "--ignored"])
    check status.code == 0
    check status.output.contains("!! build/")
    check status.output.contains("!! public/")
    check status.output.splitLines().filterIt(it.len > 0 and not it.startsWith("!!")).len == 0

    # A second new site never touches an existing, non-empty directory.
    let before2 = readFile(site / "site.toml")
    let again = cli("new", "site", site)
    check again.exitCode == 1
    check again.error.contains("is not empty")
    check readFile(site / "site.toml") == before2
    check cli("new", "site", site & "-x", "--deploy", "netlify").exitCode == 1
    check not dirExists(site & "-x")

  test "the CLI's commit is pinned in the generated flake, an unknown one is refused; --theme reaches site.toml":
    let work = createTempDir("isonim-blog-scaffold-", "")
    defer:
      putEnv("ISONIM_BLOG_REVISION", testRevision)
      removeDir(work)
    let revision = "89abcdef0123456789ABCDEF0123456789abcdef"
    putEnv("ISONIM_BLOG_REVISION", revision)
    check cli("new", "site", work / "pinned", "--theme", "themes/plain").exitCode == 0
    check readFile(work / "pinned/flake.nix").contains(
      "isonim-blog.url = \"github:metacraft-labs/isonim-blog/" & revision.toLowerAscii & "\";")
    check readSiteToml(work / "pinned")["theme"].getStr == "themes/plain"
    # A dirty, malformed or missing revision names no commit the site could
    # build against: new site refuses, saying how to fix it, and creates nothing.
    for value in [revision & "-dirty", "unknown", revision[0 .. 38], ""]:
      if value.len > 0: putEnv("ISONIM_BLOG_REVISION", value)
      else: delEnv("ISONIM_BLOG_REVISION")
      let refused = cli("new", "site", work / "unpinned", "--deploy", "cloudflare-pages")
      check refused.exitCode == 1
      check refused.error.contains("does not know one")
      check refused.error.contains("set ISONIM_BLOG_REVISION to a published isonim-blog commit")
      check not dirExists(work / "unpinned")

suite "new post, new page and publish-draft":
  test "new post and new post --draft create the right files":
    let work = createTempDir("isonim-blog-scaffold-", "")
    defer: removeDir(work)
    let site = work / "notes"
    check cli("new", "site", site).exitCode == 0
    let today = todayIn("UTC")
    discard inDir(site, proc(): bool =
      let title = "Second: a \"quoted\" title \\ with a backslash"
      let dated = cli("new", "post", title, "--date", "2024-02-29")
      check dated.exitCode == 0
      check dated.output == "Created posts/2024-02-29-second-a-quoted-title-with-a-backslash.md\n"
      let parsed = readFrontMatter(readFile("posts/2024-02-29-second-a-quoted-title-with-a-backslash.md"))
      check parsed.front.getStr("title") == title
      check parsed.front.getStr("description") == ""

      check cli("new", "post", "Notes", "--draft").output == "Created drafts/notes.md\n"
      check readFrontMatter(readFile("drafts/notes.md")).front.getStr("title") == "Notes"
      check cli("new", "post", "Gallery", "--bundle").output ==
        "Created posts/" & today & "-gallery/index.md\n"
      check cli("new", "post", "Sketch", "--draft", "--bundle").output == "Created drafts/sketch/index.md\n"
      check cli("new", "post", "Undated", "--draft", "--date", "2023-01-02").exitCode == 0
      check readFrontMatter(readFile("drafts/undated.md")).front.getStr("date") == "2023-01-02"

      # Nothing is overwritten, in either form of the same post.
      let existing = readFile("drafts/notes.md")
      let again = cli("new", "post", "Notes", "--draft")
      check again.exitCode == 1
      check again.error.contains("drafts/notes.md already exists")
      check readFile("drafts/notes.md") == existing
      let other = cli("new", "post", "Gallery")
      check other.exitCode == 1
      check other.error.contains("already exists")
      check not fileExists("posts/" & today & "-gallery.md")
      for args in [@["new", "post", "x", "--date", "2023-02-30"], @["new", "post"],
          @["new", "post", "!!!"], @["new", "post", "a", "b"], @["new", "post", "a", "--colour"]]:
        let refused = cli(args)
        check refused.exitCode == 1
        check refused.error.len > 0

      check cli("new", "page", "about").output == "Created pages/about.md\n"
      check cli("new", "page", "/projects/tools/").output == "Created pages/projects/tools.md\n"
      check readFrontMatter(readFile("pages/projects/tools.md")).front.getStr("title") == "Tools"
      check cli("new", "page", "../escape").exitCode == 1
      check cli("new", "page", "about").exitCode == 1

      # The files are what the build reads: drafts only with --drafts.
      check cli("build").exitCode == 0
      check fileExists("public/posts/second-a-quoted-title-with-a-backslash/index.html")
      check fileExists("public/posts/gallery/index.html")
      check fileExists("public/about/index.html")
      check fileExists("public/projects/tools/index.html")
      check not dirExists("public/posts/notes")
      let preview = cli("build", "--drafts", "--out", "preview")
      check preview.exitCode == 0
      check readFile("preview/posts/notes/index.html").contains("name=\"robots\" content=\"noindex\"")
      check fileExists("preview/posts/sketch/index.html")

      # publish-draft dates the draft today and moves files and bundles alike.
      check cli("publish-draft", "notes").output == "Published posts/" & today & "-notes.md\n"
      check not fileExists("drafts/notes.md")
      check readFile("posts/" & today & "-notes.md") == existing
      check cli("publish-draft", "sketch").output == "Published posts/" & today & "-sketch\n"
      check fileExists("posts/" & today & "-sketch/index.md")
      check not dirExists("drafts/sketch")
      check cli("publish-draft", "missing").exitCode == 1
      check cli("publish-draft", "../notes").exitCode == 1
      check cli("build").exitCode == 0
      check fileExists("public/posts/notes/index.html")
      check fileExists("public/posts/sketch/index.html")
      true)

suite "the generated flake":
  test "the generated flake builds the site in the sandbox":
    let work = createTempDir("isonim-blog-flake-", "")
    defer: removeDir(work)
    let site = work / "sandboxed"
    check cli("new", "site", site).exitCode == 0
    # Lock the framework input to the copy and commit the lock, as a site
    # commits its flake.lock. (A build with an uncommitted lock change, such as
    # `--override-input` alone, gives the flake no revision to record.)
    gitCommitAll(site, "Start the site")
    let framework = frameworkCopy(work)
    let locked = runProcess(tool("nix"), ["flake", "lock", "--override-input", "isonim-blog",
      "path:" & framework], cwd = site)
    check locked.code == 0
    gitCommitAll(site, "Lock isonim-blog")
    let commit = runProcess(tool("git"), ["-C", site, "rev-parse", "HEAD"]).output.strip()
    let built = runProcess(tool("nix"), ["build", "--no-link", "--print-out-paths",
      site & "#default"])
    check built.code == 0
    if built.code != 0: echo built.output
    let output = built.output.strip().splitLines()[^1]
    check output.startsWith("/nix/store/")
    check readFile(output / "index.html").contains("Hello, world")
    check fileExists(output / "posts/hello-world/index.html")
    # The flake resolved the default theme by its package name.
    check readFile(output / "index.html").contains("<a class=\"skip-link\" href=\"#content\">")
    let manifest = parseFile(output / "asset-manifest.json")
    check readFile(output / manifest["assets/minimal.css"].getStr) ==
      readFile(repoRoot / "themes/minimal/assets/minimal.css")
    let info = parseFile(output / "build.json")
    check info["sourceRevision"].getStr == commit
    check info["outputHash"].getStr.startsWith("sha256-")

if savedEpoch.len > 0: putEnv("SOURCE_DATE_EPOCH", savedEpoch)
if savedRevision.len > 0: putEnv("ISONIM_BLOG_REVISION", savedRevision)
