# Deploying to Cloudflare Pages

`isonim-blog new site <dir> --deploy cloudflare-pages` adds a recipe that
publishes the site to [Cloudflare Pages](https://developers.cloudflare.com/pages/)
with Direct Upload: the site is built by Nix and uploaded with `wrangler`.
The recipe contains no credentials, and production is only ever deployed by
a deliberate local command.

## What is generated

| File                            | Purpose                                                                                                                                                                                                                                                                                                                                                                                      |
| ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `static/_headers`               | `Strict-Transport-Security`, `X-Content-Type-Options`, `Referrer-Policy` and `Permissions-Policy` for every path, and a year of immutable caching for the fingerprinted files under `/assets/`. HTML keeps Pages' default caching, which revalidates on every request. The build appends the Content-Security-Policy that follows from the site's script policy and its remote image origins |
| `static/_redirects`             | Your own redirects; the build appends one 301 rule per `redirect_from` entry                                                                                                                                                                                                                                                                                                                 |
| `Justfile`                      | `artifact`, `deploy-preview` and `publish`, besides `serve`, `build` and `check`                                                                                                                                                                                                                                                                                                             |
| `flake.nix`                     | The dev shell also provides the `wrangler` pinned by `flake.lock`                                                                                                                                                                                                                                                                                                                            |
| `.github/workflows/preview.yml` | A preview deployment for every pushed branch except the production branch                                                                                                                                                                                                                                                                                                                    |

[`_headers`](https://developers.cloudflare.com/pages/configuration/headers/)
and [`_redirects`](https://developers.cloudflare.com/pages/configuration/redirects/)
are read by Pages (and by Netlify). Pages applies at most 100 header rules and
2,000 static plus 100 dynamic redirect rules; the build warns when a site
exceeds them. When two rules
match a path, Pages sends a header set by both once, with both values joined,
so set each header in one rule only, and do not add a Content-Security-Policy
yourself.

Pages serves a project at the root of its own hostname, and the rules in
both files name paths from the root of `public/`. A site with a `base_path`
keeps that layout (see
[Serving under a sub-path](building-a-site.md#serving-under-a-sub-path)), so
serving it below another host needs a proxy that forwards the base path to
the project with the prefix removed.

The `Justfile` names the Pages project (`project`, from the directory name)
and its production branch (`production_branch`, `main`). Change them to match
the project, and create the project with that production branch
(`wrangler pages project create <project> --production-branch main`).

## The recipes

Run them in the dev shell (`nix develop`), where `wrangler` is the pinned one.

- `just artifact` builds `packages.default` in the Nix sandbox and copies it
  to a writable `public/` (`cp -rL result public && chmod -R u+w public`):
  `result` is a symbolic link into the read-only Nix store.
- `just deploy-preview [branch]` deploys a preview of the committed site
  under the branch's name, the current branch by default. It refuses the
  production branch (and a detached HEAD) before building anything.
- `just publish` deploys production. It refuses a working tree with
  uncommitted changes, builds the artifact, lists the posts that are new,
  changed or removed since the last `published/*` tag (every post on the
  first publish), and asks you to type `publish <project>`. Anything else
  deploys nothing. After the deployment it tags the commit
  `published/<UTC time>`; push the tag to share it.

## The preview workflow

`.github/workflows/preview.yml` runs on pushes to every branch except the
production branch (and not on tags). It installs Nix and runs
`just deploy-preview` in the dev shell, so it can never deploy production.
It needs two repository secrets: `CLOUDFLARE_API_TOKEN` (an API token with
the Account permission "Cloudflare Pages: Edit") and `CLOUDFLARE_ACCOUNT_ID`.
