## Authoring commands: `new site`, `new post`, `new page` and
## `publish-draft`. They write the files a site author would otherwise write
## by hand and never overwrite an existing file.
##
## Only these commands read the wall clock ("today", in the site's time
## zone). Builds never do (see `inputs.buildEpoch`).
import std/[os, strutils, json, times]
import ./[model, inputs]

type
  DeployTarget* = enum
    ## `new site --deploy <target>`.
    dtNone, dtCloudflarePages
  NewSiteOptions* = object
    theme*: string          ## written as `theme` in site.toml when not empty
    deploy*: DeployTarget
    isonimBlogRef*: string
      ## The flake reference the generated flake.nix names; empty selects
      ## `defaultIsonimBlogRef()`, the commit this CLI was built from.
  NewPostOptions* = object
    draft*, bundle*: bool
    date*: string           ## YYYY-MM-DD; empty means today

const
  isonimBlogRepository* = "github:metacraft-labs/isonim-blog"
  productionBranch* = "main"
    ## The production branch the deploy recipe assumes. Cloudflare Pages
    ## records one per project; the generated Justfile names it once.

proc defaultIsonimBlogRef*(): string =
  ## The generated site pins the isonim-blog commit this CLI was built from,
  ## so the site builds with the framework that generated it. The packaged
  ## CLI knows that commit (`ISONIM_BLOG_REVISION`). A CLI that does not, or
  ## one built from uncommitted changes (`<commit>-dirty`), cannot name a
  ## revision the site could build against, so `new site` refuses rather than
  ## write an unpinned reference that resolves to whatever the repository's
  ## default branch holds.
  let revision = getEnv("ISONIM_BLOG_REVISION")
  if revision.len == 40 and revision.allCharsInSet(HexDigits):
    return isonimBlogRepository & "/" & revision.toLowerAscii
  fail("new site pins the isonim-blog commit this CLI was built from, and this CLI " &
    "does not know one (ISONIM_BLOG_REVISION is " &
    (if revision.len == 0: "not set" else: "\"" & revision & "\", not a commit") &
    "). Run the packaged CLI (nix run github:metacraft-labs/isonim-blog/<commit>), " &
    "or set ISONIM_BLOG_REVISION to a published isonim-blog commit.")

proc nixString(value: string): string =
  ## A Nix double-quoted string: `\`, `"` and the interpolation opener `${`
  ## escaped (https://nix.dev/manual/nix/latest/language/string-literals).
  result = "\""
  var i = 0
  while i < value.len:
    case value[i]
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\r': result.add "\\r"
    of '\t': result.add "\\t"
    of '$':
      if i + 1 < value.len and value[i + 1] == '{': result.add "\\$"
      else: result.add '$'
    else: result.add value[i]
    inc i
  result.add "\""

proc tomlString(value: string): string =
  ## A TOML basic string. JSON string escapes (\", \\, \n, \uXXXX) are all
  ## valid TOML basic-string escapes.
  $(%value)

proc yamlString*(value: string): string =
  ## A double-quoted front matter scalar (the YAML subset of
  ## isonim/content/frontmatter): backslash and quote escaped, control
  ## characters as \uXXXX.
  result = "\""
  for c in value:
    case c
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    of '\r': result.add "\\r"
    of '\0'..'\x08', '\x0b', '\x0c', '\x0e'..'\x1f', '\x7f':
      result.add "\\u" & toHex(ord(c), 4)
    else: result.add c
  result.add "\""

proc writeNew(root, rel, content: string; created: var seq[string]) =
  ## Create one file; an existing file is never replaced.
  let path = root / rel
  if fileExists(path) or dirExists(path) or symlinkExists(path):
    fail(rel & " already exists")
  createDir(parentDir(path))
  writeFile(path, content)
  created.add rel

proc siteTitle(directory: string): string =
  ## "my-blog" -> "My Blog".
  for word in extractFilename(directory).split({'-', '_', ' ', '.'}):
    if word.len == 0: continue
    if result.len > 0: result.add ' '
    result.add word[0].toUpperAscii & word[1..^1]
  if result.len == 0: result = "My Blog"

proc projectName(directory: string): string =
  ## A Cloudflare Pages project name: lower-case letters, digits and dashes.
  try: slugify(extractFilename(directory))
  except BlogError: "site"

proc packageName(project: string): string =
  ## A Nim identifier for the generated repro.nim package.
  result = project.replace('-', '_')
  if result.len == 0 or result[0] notin {'a'..'z'}: result = "site_" & result

const flakeTemplate = """{
  description = @TITLE@;

  inputs = {
    # The framework, pinned by flake.lock (`nix flake update isonim-blog`
    # moves it). nixpkgs and flake-parts follow the framework's own pins, so
    # the site builds against exactly what isonim-blog was tested with.
    isonim-blog.url = @ISONIM_BLOG@;
    nixpkgs.follows = "isonim-blog/nixpkgs";
    flake-parts.follows = "isonim-blog/flake-parts";
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      isonim-blog,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      perSystem =
        { pkgs, system, ... }:
        {
          # The production site: built in the Nix sandbox, byte-reproducible,
          # with SOURCE_DATE_EPOCH taken from the commit.
          packages.default = isonim-blog.lib.${system}.buildSite { src = self; };
          devShells.default = pkgs.mkShell {
            packages = [
              isonim-blog.packages.${system}.default
              pkgs.just
              pkgs.git
@EXTRA@            ];
          };
        };
    };
}
"""

const justfileTemplate = """# Recipes for this isonim-blog site. Run them in the flake's dev shell
# (`nix develop`), which provides the pinned isonim-blog, just and git@WRANGLER_NOTE@.

set shell := ["bash", "-euo", "pipefail", "-c"]
@DEPLOY_VARIABLES@
default:
    @just --list

# Build, serve on loopback with live reload, drafts included
serve *args:
    isonim-blog serve --drafts {{ args }}

# Build the site into public/
build *args:
    isonim-blog build {{ args }}

# Check links, anchors, front matter, alt text, scripts and feeds
check *args:
    isonim-blog check {{ args }}
@DEPLOY_RECIPES@"""

const deployVariables = """
# The Cloudflare Pages project and the production branch it was created with
# (`wrangler pages project list` shows both).
project := @PROJECT@
production_branch := @BRANCH@

# Extra `nix build` arguments, for example `--override-input isonim-blog <path>`.
nix_flags := ""
"""

const deployRecipes = """
# Build the production site in the Nix sandbox and copy it out of the store:
# result is a read-only store symlink, wrangler is given a writable copy
artifact:
    nix build {{ nix_flags }} --out-link result .#default
    rm -rf public
    cp -rL result public
    chmod -R u+w public

# Deploy a preview of the committed site; refuses the production branch
deploy-preview branch=`git rev-parse --abbrev-ref HEAD`:
    #!/usr/bin/env bash
    set -euo pipefail
    branch={{ quote(branch) }}
    if [ -z "$branch" ] || [ "$branch" = HEAD ]; then
      echo "deploy-preview: name a branch (a detached HEAD has none)" >&2
      exit 1
    fi
    if [ "$branch" = {{ quote(production_branch) }} ]; then
      echo "deploy-preview: refusing the production branch $branch; production is deployed only by just publish" >&2
      exit 1
    fi
    just nix_flags={{ quote(nix_flags) }} artifact
    wrangler pages deploy public --project-name={{ quote(project) }} --branch="$branch" --commit-hash="$(git rev-parse HEAD)"

# Build production, list what goes live, require a typed confirmation, deploy
# to the production branch and tag the commit published/<time>
publish:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -n "$(git status --porcelain)" ]; then
      echo "publish: commit or stash your changes first; the deployment is tagged with the commit" >&2
      exit 1
    fi
    just nix_flags={{ quote(nix_flags) }} artifact
    last="$(git tag --list 'published/*' --sort=-refname | head -n 1)"
    if [ -z "$last" ]; then
      echo "Going live (first publish):"
      changes="$(git ls-files -- 'posts/*.md' | awk '{ printf "  %-8s %s\n", "new", $0 }')"
    else
      echo "Going live (posts changed since $last):"
      changes="$(git diff --name-status --no-renames "$last" HEAD -- 'posts/*.md' |
        awk -F '\t' '{ printf "  %-8s %s\n", ($1 == "A") ? "new" : ($1 == "D") ? "removed" : "changed", $2 }')"
    fi
    echo "${changes:-  (no post changes)}"
    expected={{ quote("publish " + project) }}
    read -r -p "Type '$expected' to deploy to production: " answer || answer=""
    if [ "$answer" != "$expected" ]; then
      echo "publish: not confirmed; nothing was deployed" >&2
      exit 1
    fi
    wrangler pages deploy public --project-name={{ quote(project) }} --branch={{ quote(production_branch) }} --commit-hash="$(git rev-parse HEAD)"
    tag="published/$(date -u +%Y%m%dT%H%M%SZ)"
    git tag -a "$tag" -m "Published to Cloudflare Pages project "{{ quote(project) }}
    echo "Tagged $tag. Share it with: git push origin $tag"
"""

const workflowTemplate = """# Deploys a Cloudflare Pages preview of every pushed branch except the
# production branch. It never deploys production: `just publish` is a
# deliberate local step. Needs the repository secrets CLOUDFLARE_API_TOKEN
# (Account, Cloudflare Pages: Edit) and CLOUDFLARE_ACCOUNT_ID.
name: Preview

on:
  push:
    branches-ignore:
      - @BRANCH@

permissions:
  contents: read

concurrency:
  group: preview-${{ github.ref }}
  cancel-in-progress: true

jobs:
  preview:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v31
      - name: Build and deploy the preview with the flake's wrangler
        env:
          CLOUDFLARE_API_TOKEN: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          CLOUDFLARE_ACCOUNT_ID: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
          BRANCH: ${{ github.ref_name }}
        run: nix develop --command just deploy-preview "$BRANCH"
"""

const headersTemplate = """# Response headers for Cloudflare Pages (Netlify reads the same file).
# `isonim-blog build` appends the Content-Security-Policy that follows from
# the site's script policy, so do not set one here. HTML keeps the host's
# default caching (revalidated on every request); fingerprinted assets never
# change, so they are cached for a year. A header set by two matching rules
# is sent once with both values, so set each header in one rule only.
/*
  Strict-Transport-Security: max-age=31536000; includeSubDomains
  X-Content-Type-Options: nosniff
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()
/assets/*
  Cache-Control: public, max-age=31536000, immutable
"""

const redirectsTemplate = """# Redirects for Cloudflare Pages (Netlify reads the same file), one rule a
# line: <from> <to> [status]. `isonim-blog build` appends a 301 rule for
# every `redirect_from` entry in front matter.
"""

const reproTemplate = """## Reprobuild project for this site. `repro allow` activates the flake's dev
## shell (the pinned isonim-blog, just and git) on entering the directory;
## `repro tasks` lists the commands below and `repro run <task>` runs one.
import repro_project_dsl
import repro_dsl_stdlib/foreign_env

package @PACKAGE@:
  defaultToolProvisioning "path"

  devEnv:
    useFlakeDevShell()
    task "serve", command = "isonim-blog serve --drafts",
      description = "Build, serve on loopback with live reload, drafts included"
    task "build", command = "isonim-blog build",
      description = "Build the site into public/"
    task "check", command = "isonim-blog check",
      description = "Check links, anchors, front matter, alt text, scripts and feeds"
"""

const gitignoreTemplate = """/public/
/build/
/result
/result-*
/.direnv/
/.repro/
"""

proc todayIn*(timezone: string): string =
  ## The current civil date in `timezone`, for the authoring commands.
  civilDate(epochTime().int64, timezone)

proc samplePost(title: string): string =
  "---\ntitle: " & yamlString("Hello, world") & "\n" &
    "description: " & yamlString("The first post on " & title) & "\n" &
    "tags: [welcome]\n---\n\n" &
    "This is the first post. Edit it in `posts/`, or start another with\n" &
    "`isonim-blog new post \"A title\"`.\n\n<!--more-->\n\n" &
    "Run `isonim-blog serve` to preview the site with live reload, and\n" &
    "`isonim-blog check` before publishing.\n"

proc newSite*(directory: string; options = NewSiteOptions(); today = ""): seq[string] =
  ## Create a site in `directory`, which must not exist or be empty. Returns
  ## the created files relative to it, in creation order.
  if fileExists(directory) or symlinkExists(directory):
    fail(directory & " exists and is not a directory")
  if dirExists(directory):
    for _ in walkDir(directory): fail(directory & " is not empty")
  # Resolved first: a refusal must leave no directory behind.
  let reference = if options.isonimBlogRef.len > 0: options.isonimBlogRef else: defaultIsonimBlogRef()
  let root = absolutePath(directory)
  let title = siteTitle(root)
  let project = projectName(root)
  var config = "# Site configuration; see isonim-blog's docs/users/building-a-site.md.\n" &
    "title = " & tomlString(title) & "\n" &
    "description = " & tomlString("A new blog built with isonim-blog") & "\n" &
    "# The canonical origin: feeds, the sitemap and OpenGraph use it.\n" &
    "url = \"https://example.org\"\n" &
    "language = \"en\"\n" &
    "timezone = \"UTC\"\n"
  if options.theme.len > 0: config.add "theme = " & tomlString(options.theme) & "\n"
  config.add "\n[archives]\n" &
    "# The paginated post list is the home page; set index = \"/posts/\" to give\n" &
    "# the home page to pages/index.md instead.\n" &
    "index = \"/\"\n"
  createDir(root)
  var created: seq[string]
  writeNew(root, "site.toml", config, created)
  let date = if today.len > 0: validDate(today) else: todayIn("UTC")
  writeNew(root, "posts" / date & "-hello-world.md", samplePost(title), created)
  let deploying = options.deploy == dtCloudflarePages
  writeNew(root, "flake.nix", flakeTemplate.multiReplace(
    ("@TITLE@", nixString(title & " — a blog built with isonim-blog")),
    ("@ISONIM_BLOG@", nixString(reference)),
    ("@EXTRA@", if deploying: "              pkgs.wrangler\n" else: "")), created)
  writeNew(root, "repro.nim", reproTemplate.replace("@PACKAGE@", packageName(project)), created)
  writeNew(root, "Justfile", justfileTemplate.multiReplace(
    ("@WRANGLER_NOTE@", if deploying: ",\n# and the pinned wrangler" else: ""),
    ("@DEPLOY_VARIABLES@", if deploying: deployVariables.multiReplace(
      ("@PROJECT@", $(%project)), ("@BRANCH@", $(%productionBranch))) else: ""),
    ("@DEPLOY_RECIPES@", if deploying: deployRecipes else: "")), created)
  writeNew(root, ".gitignore", gitignoreTemplate, created)
  if deploying:
    writeNew(root, "static/_headers", headersTemplate, created)
    writeNew(root, "static/_redirects", redirectsTemplate, created)
    writeNew(root, ".github/workflows/preview.yml",
      workflowTemplate.replace("@BRANCH@", productionBranch), created)
  result = created

proc postExists(root, base: string): string =
  ## The existing file or bundle named `base` (without extension), if any.
  for candidate in [base & ".md", base]:
    if fileExists(root / candidate) or dirExists(root / candidate) or symlinkExists(root / candidate):
      return candidate

proc newPost*(root, title: string; options = NewPostOptions(); today = ""): string =
  ## Create a post (or a draft) titled `title`; returns its path relative to
  ## `root`. The slug comes from the title.
  if title.strip.len == 0: fail("a post needs a title")
  let slug = slugify(title)
  var front = "---\ntitle: " & yamlString(title) & "\n"
  var base: string
  if options.draft:
    base = "drafts" / slug
    if options.date.len > 0: front.add "date: " & validDate(options.date) & "\n"
  else:
    let date =
      if options.date.len > 0: validDate(options.date)
      elif today.len > 0: validDate(today)
      else: todayIn(readSiteConfig(root).timezone)
    base = "posts" / date & "-" & slug
  let existing = postExists(root, base)
  if existing.len > 0: fail(existing & " already exists")
  front.add "description: \"\"\n---\n\n"
  let rel = if options.bundle: base / "index.md" else: base & ".md"
  var created: seq[string]
  writeNew(root, rel, front, created)
  rel

proc newPage*(root, path: string): string =
  ## Create `pages/<path>.md`; `path` is a URL path such as `about` or
  ## `projects/tools` (`index` is the home page).
  var clean = path.strip(chars = {'/'})
  if clean.endsWith(".md"): clean.setLen(clean.len - 3)
  if clean.len == 0: fail("a page needs a path")
  var title = ""
  for part in clean.split('/'):
    if part.len == 0 or part in [".", ".."] or
        not part.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.'}):
      fail("a page path uses letters, digits, '-', '_' and '.' between slashes: " & path)
    title = part
  title = siteTitle(title)
  let rel = "pages" / clean & ".md"
  var created: seq[string]
  writeNew(root, rel, "---\ntitle: " & yamlString(title) & "\ndescription: \"\"\n---\n\n", created)
  rel

proc publishDraft*(root, slug: string; today = ""): string =
  ## Move `drafts/<slug>.md` (or the bundle `drafts/<slug>/`) to
  ## `posts/<today>-<slug>`; returns the new path relative to `root`.
  if slug.len == 0 or slug.contains({'/', '\\', '\0'..' '}) or slug in [".", ".."]:
    fail("invalid draft slug: " & slug)
  let source = postExists(root, "drafts" / slug)
  if source.len == 0: fail("no draft drafts/" & slug & ".md or drafts/" & slug & "/")
  let date = if today.len > 0: validDate(today) else: todayIn(readSiteConfig(root).timezone)
  let base = "posts" / date & "-" & slug
  let existing = postExists(root, base)
  if existing.len > 0: fail(existing & " already exists")
  createDir(root / "posts")
  if source.endsWith(".md"):
    result = base & ".md"
    moveFile(root / source, root / result)
  else:
    result = base
    moveDir(root / source, root / result)
