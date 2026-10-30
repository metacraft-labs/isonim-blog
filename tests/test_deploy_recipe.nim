## The Cloudflare Pages recipe that `new site --deploy cloudflare-pages`
## generates, run for real: the generated Justfile under the real `just`,
## `bash`, `git` and `nix` (the production artifact is a real sandboxed
## `nix build` of the generated flake), and the generated workflow under the
## real `actionlint`.
##
## Test double, and why: `wrangler` is a stub placed first on PATH that
## records its argv and exits 0. The recipe must never reach Cloudflare from a
## test (that needs an account and credentials, and would deploy), and what
## the recipe decides is exactly the argv it hands wrangler, or that it hands
## none. The stub also records what it can read on stdin, so the test sees
## that production deploys never leave wrangler a question to answer. No
## Cloudflare account is touched.
##
## The published/* tag is pushed for real, with the real git, to a bare
## repository in the test's temporary directory standing in for the site's
## hosted remote (a local path is an ordinary git remote), so nothing leaves
## the machine.
##
## The site's flake.lock pins the framework input to a copy of this checkout,
## so the artifact is built from the code under test with no network. Like
## the scaffold suite, this needs a Nix daemon and runs under `nix develop`.
import std/[unittest, sequtils, algorithm]
import isonim_blog
import isonim_blog/runtime
import ./site_helpers

proc stubWrangler(directory: string): tuple[bin, log, input: string] =
  ## `wrangler` that appends one line per call: its arguments, tab-separated;
  ## and appends what it reads on stdin to `input`.
  result.bin = directory / "stub-bin"
  result.log = directory / "wrangler-calls.log"
  result.input = directory / "wrangler-stdin.log"
  createDir(result.bin)
  writeFile(result.bin / "wrangler", "#!" & tool("bash") & "\n" &
    "IFS=$'\\t'; printf '%s\\n' \"$*\" >> " & quoteShell(result.log) & "\n" &
    "cat >> " & quoteShell(result.input) & "\n")
  setFilePermissions(result.bin / "wrangler", {fpUserRead, fpUserWrite, fpUserExec})

proc calls(log: string): seq[seq[string]] =
  if not fileExists(log): return
  for line in readFile(log).splitLines():
    if line.len > 0: result.add line.split('\t')

proc tags(site: string): seq[string] =
  for line in runProcess(tool("git"), ["-C", site, "tag", "--list", "published/*"]).output.splitLines():
    if line.len > 0: result.add line

suite "the Cloudflare Pages recipe":
  let work = createTempDir("isonim-blog-deploy-", "")
  let site = work / "travel-notes"
  # `new site` pins the commit the CLI was built from (the packaged CLI knows
  # it); the site's flake.lock then overrides it with a copy of this checkout.
  putEnv("ISONIM_BLOG_REVISION", "0123456789abcdef0123456789abcdef01234567")
  let generated = runCli(["new", "site", site, "--deploy", "cloudflare-pages"])
  let stub = stubWrangler(work)
  let env = @[("PATH", stub.bin & PathSep & getEnv("PATH"))] & @gitIdentity

  proc just(args: openArray[string]; input = ""): ProcessResult =
    runProcess(tool("just"), args, cwd = site, input = input, extraEnv = env,
      removeEnv = ["SOURCE_DATE_EPOCH"])

  test "new site --deploy generates the headers, redirects, recipes and a preview-only workflow":
    check generated.exitCode == 0
    for path in ["static/_headers", "static/_redirects", ".github/workflows/preview.yml"]:
      check fileExists(site / path)
      check generated.output.contains("  " & path & "\n")
    let headers = readFile(site / "static/_headers")
    # HSTS for this host only: includeSubDomains (and preload, which needs
    # it) would commit every sibling subdomain to HTTPS for a year.
    check headers.contains("\n  Strict-Transport-Security: max-age=31536000\n")
    let rules = headers.splitLines().filterIt(not it.startsWith("#")).join("\n")
    check "includeSubDomains" notin rules
    check "preload" notin rules
    for header in ["Strict-Transport-Security: max-age=31536000", "X-Content-Type-Options: nosniff",
        "Referrer-Policy: strict-origin-when-cross-origin", "Permissions-Policy: ",
        "/assets/*\n  Cache-Control: public, max-age=31536000, immutable"]:
      check headers.contains(header)
    check not headers.contains("  Content-Security-Policy:")  # the build adds it
    check readFile(site / "flake.nix").contains("pkgs.wrangler")
    check runProcess(tool("nixfmt"), ["--check", site / "flake.nix"]).code == 0
    let summary = just(["--summary"])
    check summary.code == 0
    check summary.output.splitWhitespace().sorted() ==
      @["artifact", "build", "check", "default", "deploy-preview", "publish", "serve"]
    let lint = runProcess(tool("actionlint"), [site / ".github/workflows/preview.yml"])
    check lint.code == 0
    if lint.code != 0: echo lint.output

  test "the generated workflow contains no production deploy":
    # Comments may name production; the checks are about what runs.
    let workflow = readFile(site / ".github/workflows/preview.yml").splitLines().filterIt(
      not it.strip().startsWith("#")).join("\n") & "\n"
    # It runs only for pushes to branches other than production (never for
    # tags such as published/*), and its only deploy is deploy-preview, which
    # refuses the production branch itself (next test).
    check workflow.contains("on:\n  push:\n    branches-ignore:\n      - main\n")
    check not workflow.contains("pull_request")
    check not workflow.contains("tags:")
    let deploys = workflow.splitLines().filterIt("just " in it or "wrangler " in it)
    check deploys == @["        run: nix develop --command just deploy-preview \"$BRANCH\""]
    check not workflow.contains("publish")
    check not workflow.contains("--branch")

  test "the build writes the security headers, one CSP rule and redirect_from rules":
    writeFile(site / "posts/2020-01-01-moved.md", "---\ntitle: Moved\ndescription: An old post\n" &
      "redirect_from: [/2019/old-post.html, /old/moved/]\n---\nBody.\n")
    let blogCli = compileCli(work)
    let built = runProcess(blogCli, ["build"], cwd = site, removeEnv = ["SOURCE_DATE_EPOCH"])
    check built.code == 0
    let headers = readFile(site / "public/_headers")
    check headers.startsWith(readFile(site / "static/_headers"))
    check headers.count("Content-Security-Policy:") == 1
    check headers.contains("/*\n  Content-Security-Policy: default-src 'none'; script-src 'none'; style-src 'self';")
    check headers.contains("; form-action 'self'; frame-ancestors 'none'\n")
    check "unsafe-inline" notin headers
    check ruleCount(headers) == 3
    # Pages with different policies keep one rule each.
    check headersFor([("/a/", "p"), ("/b/", "p")]) == "/*\n  Content-Security-Policy: p\n"
    check headersFor([("/a/", "p"), ("/b/", "q")]) ==
      "/a/\n  Content-Security-Policy: p\n/b/\n  Content-Security-Policy: q\n"
    check headersFor(newSeq[tuple[url, policy: string]]()) == ""
    check ruleCount("# c\n/*\n  X: y\n\n/a\n  ! X\n") == 2
    let redirects = readFile(site / "public/_redirects")
    check redirects.startsWith(readFile(site / "static/_redirects"))
    check redirects.endsWith("/2019/old-post.html /posts/moved/ 301\n/old/moved/ /posts/moved/ 301\n")
    # A source claimed twice, or a page's own URL, is an error naming both.
    writeFile(site / "posts/2020-01-02-also.md", "---\ntitle: Also\ndescription: Another\n" &
      "redirect_from: [/old/moved/]\n---\nBody.\n")
    let twice = runProcess(blogCli, ["build"], cwd = site, removeEnv = ["SOURCE_DATE_EPOCH"])
    check twice.code != 0
    check twice.output.contains("redirect_from /old/moved/ is claimed by posts/2020-01-02-also.md and posts/2020-01-01-moved.md")
    writeFile(site / "posts/2020-01-02-also.md", "---\ntitle: Also\ndescription: Another\n" &
      "redirect_from: [/posts/moved]\n---\nBody.\n")
    let shadowing = runProcess(blogCli, ["build"], cwd = site, removeEnv = ["SOURCE_DATE_EPOCH"])
    check shadowing.code != 0
    check shadowing.output.contains("redirect_from /posts/moved is the URL of posts/2020-01-01-moved.md")
    removeFile(site / "posts/2020-01-02-also.md")
    removeFile(site / "posts/2020-01-01-moved.md")

  test "deploy-preview refuses the production branch and deploys any other":
    # The site's own flake.lock pins the framework to the code under test.
    gitCommitAll(site, "Start the site")
    let framework = frameworkCopy(work)
    check runProcess(tool("nix"), ["flake", "lock", "--override-input", "isonim-blog",
      "path:" & framework], cwd = site).code == 0
    gitCommitAll(site, "Lock isonim-blog")
    let head = runProcess(tool("git"), ["-C", site, "rev-parse", "HEAD"]).output.strip()

    let refused = just(["deploy-preview", "main"])
    check refused.code != 0
    check refused.output.contains("refusing the production branch main")
    check calls(stub.log).len == 0
    check not dirExists(site / "result")  # refused before building anything
    # The current branch is the default, and it is main here.
    let implicit = just(["deploy-preview"])
    check implicit.code != 0
    check implicit.output.contains("refusing the production branch main")
    check calls(stub.log).len == 0

    # Positive control: another branch builds the artifact and deploys it.
    let preview = just(["deploy-preview", "feature/new-layout"])
    check preview.code == 0
    if preview.code != 0: echo preview.output
    check calls(stub.log) == @[@["pages", "deploy", "public", "--project-name=travel-notes",
      "--branch=feature/new-layout", "--commit-hash=" & head]]
    # wrangler gets a writable copy, not the store symlink.
    check not symlinkExists(site / "public")
    check symlinkExists(site / "result")
    check readFile(site / "public/index.html") == readFile(expandSymlink(site / "result") / "index.html")
    check fpUserWrite in getFilePermissions(site / "public/index.html")
    check tags(site).len == 0

  test "publish lists what goes live, asks for the typed confirmation or --yes, deploys, tags and pushes the tag":
    writeFile(site / "log.txt", "")
    removeFile(stub.log)
    if fileExists(stub.input): removeFile(stub.input)
    # A dirty tree is refused before anything else.
    let dirty = just(["publish"], input = "publish travel-notes\n")
    check dirty.code != 0
    check dirty.output.contains("commit or stash")
    removeFile(site / "log.txt")
    let unknown = just(["publish", "--force"], input = "publish travel-notes\n")
    check unknown.code != 0
    check unknown.output.contains("publish: unknown argument --force (the only option is --yes)")
    # The tag is pushed, so a repository without the remote is refused
    # before anything is built or deployed.
    let noRemote = just(["publish", "--yes"])
    check noRemote.code != 0
    check noRemote.output.contains("the tag is pushed to the git remote origin, which this repository does not have")
    check not noRemote.output.contains("Going live")
    check calls(stub.log).len == 0
    check tags(site).len == 0
    # The site's hosted repository: a bare repository beside it.
    let remote = work / "hosted.git"
    check runProcess(tool("git"), ["init", "--quiet", "--bare", remote]).code == 0
    check runProcess(tool("git"), ["-C", site, "remote", "add", "origin", remote]).code == 0
    for answer in ["", "yes\n", "publish\n", "publish travel-notes-x\n"]:
      let declined = just(["publish"], input = answer)
      check declined.code != 0
      check declined.output.contains("not confirmed; nothing was deployed")
      check declined.output.contains("Going live (first publish):")
      check declined.output.contains("new      posts/")
      check declined.output.contains("-hello-world.md")
    check calls(stub.log).len == 0
    check tags(site).len == 0
    check tags(remote).len == 0

    let head = runProcess(tool("git"), ["-C", site, "rev-parse", "HEAD"]).output.strip()
    # A line typed after the confirmation is still waiting on stdin; wrangler
    # must not be able to read it as the answer to a question of its own.
    let published = just(["publish"], input = "publish travel-notes\ny\n")
    check published.code == 0
    if published.code != 0: echo published.output
    check calls(stub.log) == @[@["pages", "deploy", "public", "--project-name=travel-notes",
      "--branch=main", "--commit-hash=" & head]]
    check fileExists(stub.input)
    check readFile(stub.input) == ""
    let made = tags(site)
    check made.len == 1
    check runProcess(tool("git"), ["-C", site, "rev-parse", made[0] & "^{commit}"]).output.strip() == head
    check published.output.contains("Tagged " & made[0] & " and pushed it to origin.")
    # The annotated tag reached the hosted repository, naming the deployed commit.
    check tags(remote) == made
    check runProcess(tool("git"), ["-C", remote, "rev-parse", made[0] & "^{commit}"]).output.strip() == head

    # The next publish lists only what changed since that tag.
    writeFile(site / "posts/2021-01-01-second.md", "---\ntitle: Second\ndescription: Another\n---\nMore.\n")
    gitCommitAll(site, "Second post")
    let next = just(["publish"], input = "no\n")
    check next.code != 0
    check next.output.contains("Going live (posts changed since " & made[0] & "):")
    check next.output.contains("new      posts/2021-01-01-second.md")
    check not next.output.contains("hello-world")
    check calls(stub.log).len == 1

    # --yes stands in for the typed confirmation, for scripted publishing.
    sleep(1100)  # tags are named to the second
    let second = runProcess(tool("git"), ["-C", site, "rev-parse", "HEAD"]).output.strip()
    let confirmed = just(["publish", "--yes"])
    check confirmed.code == 0
    if confirmed.code != 0: echo confirmed.output
    check confirmed.output.contains("new      posts/2021-01-01-second.md")
    check confirmed.output.contains("Confirmed by --yes.")
    check not confirmed.output.contains("Type 'publish")
    check calls(stub.log).len == 2
    check calls(stub.log)[^1] == @["pages", "deploy", "public", "--project-name=travel-notes",
      "--branch=main", "--commit-hash=" & second]
    check tags(site).len == 2
    check tags(remote) == tags(site)

    # A push that fails after the deployment says what happened and how to
    # finish; the deployment and the local tag stand.
    sleep(1100)
    check runProcess(tool("git"), ["-C", site, "remote", "set-url", "origin", work / "gone.git"]).code == 0
    let unpushed = just(["publish", "--yes"])
    check unpushed.code != 0
    check calls(stub.log).len == 3
    let newest = tags(site)
    check newest.len == 3
    check unpushed.output.contains("publish: deployed and tagged " & newest[^1] &
      ", but pushing the tag to origin failed; push it with: git push origin " & newest[^1])
    check tags(remote).len == 2
    removeDir(work)
