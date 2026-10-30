# Writing and previewing

The `isonim-blog` commands for starting a site, writing posts, previewing
them with live reload and checking a site before it is published. Building is
described in [Building a site](building-a-site.md), deploying in
[Deploying to Cloudflare Pages](deploying-to-cloudflare-pages.md).

Run every command except `new site` in the site's directory, the one that
holds `site.toml`.

## `new site`

```sh
isonim-blog new site <dir> [--theme <name|path>] [--deploy cloudflare-pages]
```

Creates `<dir>` (which must not exist, or be empty) with:

| File                           | Contents                                                                                                                                                                                                                                                                                                         |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `site.toml`                    | The title (from the directory name) and a placeholder `url` to replace with the site's origin (builds warn until then). With no `[archives] index`, the paginated post list is the home page; a `pages/index.md` moves it to `/posts/`                                                                           |
| `posts/<today>-hello-world.md` | A sample post                                                                                                                                                                                                                                                                                                    |
| `flake.nix`                    | `packages.default`, the site built in the Nix sandbox with `buildSite`, and a dev shell with `isonim-blog`, `just` and `git`. Its `isonim-blog` input pins the commit the CLI was built from, so the site builds with the framework that generated it. `nixpkgs` and `flake-parts` follow isonim-blog's own pins |
| `repro.nim`                    | A Reprobuild project: `repro allow` activates the flake's dev shell, and `repro tasks` lists `serve`, `build` and `check`                                                                                                                                                                                        |
| `Justfile`                     | `serve`, `build` and `check` recipes                                                                                                                                                                                                                                                                             |
| `.gitignore`                   | `public/`, `build/`, `result` and the dev-shell caches                                                                                                                                                                                                                                                           |

`site.toml` names the theme `isonim-blog-theme-minimal`, the theme isonim-blog
ships; `--theme <value>` writes another package name or a theme directory
instead (see [Themes](themes.md)). `--deploy cloudflare-pages` adds the
deployment recipe.

`new site` needs to know which isonim-blog commit to pin. The packaged CLI
(`nix run github:metacraft-labs/isonim-blog/<commit>`, or the one in a site's
dev shell) knows the commit it was built from. A CLI built some other way, or
from uncommitted changes, does not, and `new site` refuses until
`ISONIM_BLOG_REVISION` names a published isonim-blog commit.

Commit `flake.lock` together with the site: `nix build` records the commit in
`build.json` only when the lock file is committed.

## `new post`, `new page` and `publish-draft`

```sh
isonim-blog new post "<title>" [--draft] [--date YYYY-MM-DD] [--bundle]
isonim-blog new page <path>
isonim-blog publish-draft <slug>
```

`new post` derives the slug from the title and creates
`posts/<date>-<slug>.md`, dated today in the site's time zone unless `--date`
is given. `--draft` creates `drafts/<slug>.md` instead (with `--date`, the date
goes into the front matter), and `--bundle` creates a directory with an
`index.md`, for posts with their own images. The front matter holds the title
and an empty `description` to fill in.

`new page about` creates `pages/about.md` (served at `/about/`);
`new page projects/tools` creates `pages/projects/tools.md`.

`publish-draft <slug>` moves `drafts/<slug>.md`, or the bundle
`drafts/<slug>/`, to `posts/<today>-<slug>`. It is a file move, not a
deployment.

None of these commands overwrites a file. They read the clock for "today";
a build reads it only when no `--now` is given, to decide which posts are
future.

## `serve`

```sh
isonim-blog serve [--drafts] [--future] [--port 4000] [--lan] [--now <time>]
```

Builds the site, serves `public/` at `http://127.0.0.1:4000/` (at
`http://127.0.0.1:4000/blog/` for a site with `base_path = "/blog"`, as the
deployed site serves it; other paths answer 404) and rebuilds on
every change to `site.toml`, `og.svg.nim`, the content and code directories,
and the theme. Open pages reload by themselves.

- `site.toml` need not name a `url`: without one, the site is built for the
  server's own origin, `http://localhost:<port>`, so a fresh checkout serves
  without editing the configuration. A `url` there is kept.
- `--now` previews the site as a build at that time would publish it (see
  `isonim-blog build`); `--future` shows every future-dated post.

- Editing content (posts, pages, data, assets, static files) runs the
  already-compiled site program again; nothing is compiled. Only the output
  files whose bytes changed are rewritten: the edited pages and the listings,
  feeds and sitemap the edit reaches.
- Editing a layout, an include or the OpenGraph template recompiles the site
  program first.
- When a build fails, for instance on a layout that does not compile, every
  page shows the error instead, and the last good output stays in `public/`.
  The pages reload as soon as a later build succeeds.

The server listens on loopback only. `--lan` makes it listen on every
interface, to preview on another device. The live-reload script is added to
pages as they are served; the files in `public/` never contain it.

## `check`

```sh
isonim-blog check [--external]
```

Builds the site as production does (no drafts, no future posts) into
`build/isonim-blog/check/` and checks the result:

- **Internal links and anchors.** Every link, image, `srcset` candidate and
  OpenGraph URL that stays on the site must name a built file, and every
  `#fragment` must name an element `id` on the target page. Links written by
  layouts are checked as well as links in Markdown.
- **Front matter.** A missing description, for which the meta description
  falls back to the excerpt or the site's description, and one longer than
  160 characters are warnings, as in `build`
  (see [Descriptions](building-a-site.md#descriptions)). A new post's empty
  `description` therefore passes `check`.
- **Alt text.** Every image has an `alt` attribute: alt text, or `alt=""`
  for a decorative image. A missing attribute, or alt text of only spaces, is
  an error.
- **Scripts.** Every page that carries a script other than JSON-LD is listed
  with the reason: the declared islands bundle or the configured analytics.
- **Feeds.** Every RSS and Atom feed the pages link is well-formed, has the
  required elements, absolute links and valid dates.

`--external` also requests every link to another site and reports those that
fail or answer with an HTTP status of 400 or more. It needs network access.
Some sites refuse or rate-limit automated requests; list them in `site.toml`
so that `check` does not request them:

```toml
[check]
skip_external = ["twitter.com", "https://www.linkedin.com/in/"]
```

An entry is either a host name, which also covers its subdomains
(`twitter.com` covers `mobile.twitter.com`), or an `http://` or `https://`
URL prefix (scheme and host compared without case, the path as written).
Anything else, and any other key in `[check]`, fails the check, so a typo
cannot silently request a site again. Each skipped link is listed as
`info: <url>: external link not requested`.

`check` prints one line per finding and a summary, and exits with status 1
when it found an error.
