# Building a site

`isonim-blog build` turns a directory of Markdown, data and IsoNim layouts into
a static site in `public/`. This page describes what it reads, how it maps
files to URLs, how layouts work, and how to build the same site reproducibly
with Nix. A complete small site lives in [`examples/basic/`](../../examples/basic).

## Directory layout

```
my-blog/
├── site.toml             # site configuration
├── posts/                # YYYY-MM-DD-slug.md, or YYYY-MM-DD-slug/index.md with files beside it
├── drafts/               # slug.md, no date; built only with --drafts
├── pages/                # about.md -> /about/, index.md -> /
├── collections/<name>/   # a collection declared in site.toml
├── layouts/              # layout modules (*.nim)
├── includes/             # partial modules (*.nim) that layouts import
├── data/                 # *.toml and *.json, available as site.data
├── assets/               # fingerprinted files referenced by content and layouts
└── static/               # copied verbatim to the output root (_headers, favicon.ico, ...)
```

Only `site.toml` and these directories are read. Anything else in the
repository (a README, documentation, design archives, tests) is never read or
published, so nothing needs excluding. Symbolic links inside the input
directories are refused rather than followed.

- A post's date comes from its file name; front matter may override it. A
  post without a date is an error.
- A post bundle is a dated directory with an `index.md`. Its other files are
  published as fingerprinted assets, and links to them from the post are
  rewritten.
- Drafts are built only with `--drafts`. Draft pages carry
  `<meta name="robots" content="noindex">`, and layouts can show a banner
  through `page.draft`.
- A post dated after the build date is left out unless `--future` is given.
  The build date is `SOURCE_DATE_EPOCH` when it is set; otherwise it is the
  newest modification time among the content files, never the clock, so
  rebuilding the same files gives the same result.
- Drafts and future-dated posts included by `--drafts` or `--future` appear
  in listings, but never in feeds or the sitemap.

## `site.toml`

```toml
title = "Field Notes"                 # required
description = "A small technical notebook"
url = "https://example.org"           # canonical origin; required to build
base_path = ""                        # for a site served under a sub-path
language = "en"
timezone = "UTC"                      # an IANA zone; decides the build date
permalink = "/posts/:slug/"           # default for posts
theme = "themes/plain"                # optional: a theme directory, relative to the site
paginate = 10                         # posts per index page
author = { name = "Example Author", url = "/about/" }

[collections.notes]
output = true
permalink = "/notes/:slug/"

[taxonomies]                          # "" as a permalink turns a listing off
tags = { permalink = "/tags/:name/" }
categories = { permalink = "/categories/:name/" }

[archives]
index = "/posts/"                     # the paginated post index
year = "/:year/"
month = ""                            # off by default; e.g. "/:year/:month/"

[feeds]                               # "" as a path turns a feed off
rss = "/feed.xml"
atom = "/atom.xml"
per_tag = true                        # an Atom feed per tag page
full_content = true                   # false: the excerpt only

[output]
scripts = "none"                      # "none" (default) or "islands"
analytics = { provider = "none" }     # "none", "custom" (snippet = "...") or "beacon" (src = "...")
```

The file is parsed with Python's standard `tomllib`, so the whole TOML 1.0
language is accepted. Unknown top-level keys are kept in `site.extra`, and
unknown keys inside the tables above stay in those tables (`site.config.feeds`,
`site.config.archives`, `site.config.output`, a collection's `extra`), so a
layout can read settings this version does not interpret. The values shown are
the defaults for `[taxonomies]`, `[archives]` and `[feeds]`. TOML values with no JSON equivalent arrive as
tagged objects: `{"$toml": "datetime" | "date" | "time", "value": "<ISO 8601>"}`,
`{"$toml": "integer", "value": "<digits>"}` for integers beyond 2^53, and
`{"$toml": "float", "value": "nan" | "inf" | "-inf"}`. A table that itself has
a `$toml` key is wrapped as `{"$toml": "table", "value": {...}}`.

## Front matter

Front matter is a YAML subset between `---` lines.

| Key                                                                   | Meaning                                                                                     |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| `title`, `description`                                                | Title and meta description; a missing description, or one over 160 characters, is a warning |
| `date`, `updated`                                                     | `YYYY-MM-DD`; override the file-name date; `updated` becomes the sitemap `lastmod`          |
| `slug`, `permalink`                                                   | Override the URL                                                                            |
| `layout`                                                              | Layout name (default `post` for posts, `page` otherwise)                                    |
| `tags`, `categories`                                                  | Lists; when `data/tags.toml` exists, every tag must be declared there                       |
| `draft`                                                               | `true` keeps a file under `posts/` out of builds without `--drafts`                         |
| `image`, `image_alt`                                                  | Hero image; the alt text is required when an image is set                                   |
| `series`, `series_order`                                              | Series navigation: posts sharing `series`, read in `series_order`, then date and slug       |
| `og_image`, `excerpt`, `toc`, `noindex`, `canonical`, `redirect_from` | Further page settings                                                                       |
| anything else                                                         | Kept unchanged in `page.extra`                                                              |

## Permalinks

Placeholders: `:year`, `:month`, `:day`, `:slug`, `:title`, `:categories`,
`:collection` and `:name`. A permalink ending in `/` is written as
`index.html` inside that directory (`/posts/hello/` becomes
`posts/hello/index.html`); one ending in `.html` is written as that file.
Two sources that resolve to the same output file, compared without regard to
case, are an error naming both files.

## Layouts and includes

A layout is a Nim module in `layouts/` exporting

```nim
proc layout*(page: Page; site: Site; content: string): string
```

written with IsoNim's `ui:` DSL. It may declare `const parent = "base"`, and
its output is then passed as `content` to the `base` layout, as in Jekyll.
Includes are ordinary modules in `includes/` that layouts import. Layouts
receive `site.posts`, `site.tags`, `site.categories` and `site.collections`
(every declared collection, by name) ordered by date (newest first), then
slug, and `site.data` with every data file.

A post also carries `page.previous` (the older post) and `page.next` (the
newer one), and, in a series, `page.seriesPosts` in reading order. The
`isonim_blog/listing` module renders these for a layout:
`postNavigationHtml(page)`, `seriesNavigationHtml(page)`,
`postListHtml(posts)` and `paginationHtml(page)`.

Content is data and layouts are code. `build` generates a small program from
the layouts and includes of the site and its theme, compiles it once, and runs
it over the content. The compiled program is reused while its sources are
unchanged: the cache key covers every layout and include, the IsoNim and
isonim-blog sources it is compiled against, the compiler version and the
compiler command, but no content. Editing Markdown therefore never recompiles.

A theme directory supplies `layouts/`, `includes/` and `assets/`. The site's
file wins over the theme's file of the same path.

## Archives and pagination

Every build generates listing pages from the posts, each rendered through a
layout of its own name:

| Page                     | URL (default)                      | Layout     | `page.term`  |
| ------------------------ | ---------------------------------- | ---------- | ------------ |
| Post index, page 1       | `/posts/`                          | `index`    | empty        |
| Post index, page _n_ > 1 | `/posts/page/<n>/`                 | `index`    | empty        |
| One per tag              | `/tags/<tag>/`                     | `tag`      | the tag      |
| One per category         | `/categories/<category>/`          | `category` | the category |
| One per year             | `/<year>/`                         | `archive`  | `2020`       |
| One per month (opt-in)   | `/<year>/<month>/` when configured | `archive`  | `2020-02`    |

`page.listing` holds the posts the page lists, newest first, then by slug;
`page.kind` says which kind of listing it is. Index pages also carry
`page.pageNumber`, `page.pageCount`, `page.previousPageUrl` (newer posts) and
`page.nextPageUrl` (older posts), `paginate` posts to a page. Term URLs use
the term's slug (`Web UI` becomes `web-ui`), and a tag's page title is the
`title` given for it in `data/tags.toml` when there is one. A site without one
of these layouts gets a plain built-in list. A generated page whose URL is also
claimed by a content page, or two terms with the same slug, are an error naming
both. Pointing `index` at `/` makes the post index the home page (remove
`pages/index.md` first).

## Feeds, sitemap and structured data

- **Feeds.** `feed.xml` (RSS 2.0) and `atom.xml` (Atom) carry every published
  post with its full content, and each tag page has its own Atom feed next to
  it (`/tags/<tag>/atom.xml`), titled with the tag's `title` from
  `data/tags.toml` when it has one. Every URL in a feed is absolute, including the
  links and images inside post content. Every page links the feeds with
  `<link rel="alternate">`, and a tag page also links its own.
- **Sitemap.** `sitemap.xml` lists every page except drafts, `noindex` pages
  and future-dated posts, with `lastmod` from `updated` (or the date); a
  listing page's `lastmod` is the newest among its published posts. A listing
  that lists only drafts or future posts (in a `--drafts` or `--future`
  preview) is left out too. `robots.txt` points
  to it, unless the site provides its own `static/robots.txt`.
- **JSON-LD.** A post carries a schema.org `BlogPosting` with the site author
  as a `Person` (a root-relative author `url` is a path under `base_path`);
  the site root carries a `WebSite`; other pages carry a
  `WebPage` that is part of the `WebSite`.

All three need absolute URLs, so a build without `url` (in `site.toml` or
from `--url`) fails.

## Zero JavaScript by default

With `scripts = "none"`, a built page contains no `<script>` element other
than `application/ld+json` and the configured analytics snippet. A layout
that emits any other script element, including an inert data block, fails the
build. Each page's Content-Security-Policy in the generated `_headers` names
only the scripts the page loads.

With `scripts = "islands"`, a layout may declare interactive islands:

```nim
const islands* = [Island(module: "includes/counter", selector: "#counter")]
```

Each island module exports `proc mount*(element: Element)` on the JavaScript
backend, with `Element` from `isonim/web/dom_api`, and typically calls IsoNim's
`hydrate` there. All declared islands are compiled with `nim js` into one
fingerprinted bundle, loaded with `defer`.

## `isonim-blog build`

```sh
isonim-blog build [--drafts] [--future] [--out public] [--url <origin>]
```

Run it in the site's directory. It prints whether the site program was
compiled or reused, then a summary, and exits with status 0 or 1. `--url`
replaces the canonical origin, for preview deployments. Compiled programs and
their caches live under `build/isonim-blog/`. The output directory is written
completely before it replaces the previous one, so a failed build leaves the
last good output in place. It may not overlap the input directories.

Every build writes `build.json`: the generator, the source revision (a commit
when the builder knows one, otherwise a content hash of every file the build
could read), the isonim-blog and theme revisions, `sourceDateEpoch` and a
hash of the output, so a deployed site can be matched to its sources.

## Reproducible builds with Nix

The flake exports `lib.<system>.buildSite`:

```nix
isonim-blog.lib.${system}.buildSite {
  src = self;               # needs lastModified; a flake input or self has it
  theme = null;             # a theme directory; default: theme in site.toml
  drafts = false;
  url = null;               # overrides url from site.toml
}
```

It builds the site in the Nix sandbox, with no network and only `site.toml`
and the declared directories copied in, and with `SOURCE_DATE_EPOCH` taken
from `src.lastModified`. Nothing in the output depends on the clock and every
listing is sorted, so `nix build --rebuild` reproduces it byte for byte. It
wraps IsoNim's `buildStaticSite`, which compiles the site program against the
pinned IsoNim.
