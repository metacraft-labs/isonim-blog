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
├── static/               # copied verbatim to the output root (_headers, favicon.ico, ...)
└── og.svg.nim            # optional: the OpenGraph image template
```

Only `site.toml`, `og.svg.nim` and these directories are read. Anything else in the
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
- A post dated after "now" is left out unless `--future` is given. "Now" is
  the build clock: `--now` when it is given (an RFC 3339 date-time with an
  offset, such as `2026-11-01T00:00:00Z`, or seconds since the Unix epoch
  after an `@`, such as `@1793491200`), otherwise the current time. A bare
  number is refused: `--now 20261028` looks like a date but would mean a
  moment in 1970, so write `--now @20261028` if you mean seconds. The clock
  must lie between 1970-01-01T00:00:00Z and 9999-12-30T23:59:59Z. A post is future when
  its date is after the date of "now" in `site.toml`'s `timezone`. The build
  summary names the clock it used. The Nix build (below) uses the source's
  commit time instead, so its output does not depend on when it runs.
- A future-dated post is published by the first build after its date, so a
  scheduled post needs a scheduled build (see
  [Scheduled posts](#scheduled-posts)).
- `SOURCE_DATE_EPOCH` (https://reproducible-builds.org/specs/source-date-epoch/)
  dates only what the build writes: `sourceDateEpoch` in `build.json` and the
  date of a feed with no entries. It never decides which posts are published,
  so the 1980-01-01 that a Nix dev shell sets hides nothing. Without it, the
  build clock dates the output too.
- Drafts and future-dated posts included by `--drafts` or `--future` appear
  in listings, but never in feeds or the sitemap.

## `site.toml`

```toml
title = "Field Notes"                 # required
description = "A small technical notebook"
url = "https://notes.example.net"     # canonical origin; required to build (see below)
base_path = ""                        # for a site served under a sub-path (see below)
language = "en"
timezone = "UTC"                      # an IANA zone; decides the build date
permalink = "/posts/:slug/"           # default for posts
theme = "isonim-blog-theme-minimal"   # optional: a theme package, or a directory relative to the site
paginate = 10                         # posts per index page
author = { name = "Example Author", url = "/about/" }

[collections.notes]
output = true
permalink = "/notes/:slug/"

[taxonomies]                          # "" as a permalink turns a listing off
tags = { permalink = "/tags/:name/" }
categories = { permalink = "/categories/:name/" }

[archives]
index = "/"                           # the paginated post index (see below)
year = "/:year/"
month = ""                            # off by default; e.g. "/:year/:month/"

[feeds]                               # "" as a path turns a feed off
rss = "/feed.xml"
atom = "/atom.xml"
per_tag = true                        # an Atom feed per tag page
full_content = true                   # false: the excerpt only

[images]
widths = [480, 960, 1600]             # variant widths, in pixels
formats = ["avif", "webp"]            # variant formats: "avif" and/or "webp"
max_source_bytes = 2_000_000          # a larger image is an error

[output]
scripts = "none"                      # "none" (default) or "islands"
analytics = { provider = "none" }     # "none", "custom" (snippet = "...") or "beacon" (src = "...")
```

The file is parsed with Python's standard `tomllib`, so the whole TOML 1.0
language is accepted. Unknown top-level keys are kept in `site.extra`, and
unknown keys inside the tables above stay in those tables (`site.config.feeds`,
`site.config.archives`, `site.config.output`, a collection's `extra`), so a
layout can read settings this version does not interpret. The values shown are
the defaults for `[taxonomies]`, `[archives]`, `[feeds]` and `[images]`. TOML values with no JSON equivalent arrive as
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

A theme supplies `layouts/`, `includes/`, `assets/`, `og.svg.nim`, design
tokens and default configuration; see [Themes](themes.md). The site's file
wins over the theme's file of the same path, and `isonim-blog theme eject
<file>` copies a theme file into the site.

## Archives and pagination

Every build generates listing pages from the posts, each rendered through a
layout of its own name:

| Page                     | URL (default)                        | Layout     | `page.term`  |
| ------------------------ | ------------------------------------ | ---------- | ------------ |
| Post index, page 1       | `/` (or `/posts/`, see below)        | `index`    | empty        |
| Post index, page _n_ > 1 | `/page/<n>/` (or `/posts/page/<n>/`) | `index`    | empty        |
| One per tag              | `/tags/<tag>/`                       | `tag`      | the tag      |
| One per category         | `/categories/<category>/`            | `category` | the category |
| One per year             | `/<year>/`                           | `archive`  | `2020`       |
| One per month (opt-in)   | `/<year>/<month>/` when configured   | `archive`  | `2020-02`    |

`page.listing` holds the posts the page lists, newest first, then by slug;
`page.kind` says which kind of listing it is. Index pages also carry
`page.pageNumber`, `page.pageCount`, `page.previousPageUrl` (newer posts) and
`page.nextPageUrl` (older posts), `paginate` posts to a page. Term URLs use
the term's slug (`Web UI` becomes `web-ui`), and a tag's page title is the
`title` given for it in `data/tags.toml` when there is one. A site without one
of these layouts gets a plain built-in list. A generated page whose URL is also
claimed by a content page, or two terms with the same slug, are an error naming
both.

Where the post index lives: when `[archives] index` is not set, the paginated
post list is the home page (`/`, or the `base_path` when one is set), as in
Jekyll. A content page whose URL is the home page, normally `pages/index.md`,
takes the home page instead, and the post list moves to `/posts/` (page _n_ at
`/posts/page/<n>/`). An `index` set in `site.toml` never moves: a content page
at that URL is an error naming both. `index = ""` turns the post index off.

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
  preview) is left out too. A site at the root of its host also gets a
  `robots.txt` that points to it, unless the site provides its own
  `static/robots.txt`; a site under a `base_path` gets none (see
  [Serving under a sub-path](#serving-under-a-sub-path)).
- **JSON-LD.** A post carries a schema.org `BlogPosting` with the site author
  as a `Person` (a root-relative author `url` is a path under `base_path`);
  the site root carries a `WebSite`; other pages carry a
  `WebPage` that is part of the `WebSite`.

All three need absolute URLs, so a build without `url` (in `site.toml` or
from `--url`) fails. `isonim-blog serve` is the exception: without a `url` it
builds for its own origin, `http://localhost:<port>`. A `url` on a domain
reserved for examples (`example.com`, `example.net`, `example.org` and their
subdomains, or any name under `.example`), such as the placeholder that
`new site` writes, builds with a warning naming it: canonical links, feeds and
the sitemap would point there. Replace it with the origin the site is deployed
at.

## Serving under a sub-path

Set `base_path` when the site is served below the root of its host, for
example at `https://example.net/blog/` (`base_path = "/blog"`; a trailing
slash is ignored). The model is the one Hugo (`baseURL` with a path), Jekyll
(`baseurl`), Eleventy (`pathPrefix`), Astro (`base`) and Zola use: **the
output directory is the base path's root.**

- Every URL the build writes carries the base path: links between pages,
  stylesheets, images and their responsive variants, the islands bundle,
  canonical links, OpenGraph and Twitter image URLs, JSON-LD, feed links and
  entries, sitemap locations, and the targets of `redirect_from` rules. A
  permalink (`/posts/:slug/`), a feed path (`/feed.xml`) and a `redirect_from`
  entry (`/old/`) are written without it; the build adds it. A root-relative
  `url` in `site.toml`, such as the author's `/about/`, is a path of the site
  too, so it becomes `/blog/about/`.
- No file is written under the base path. `/blog/posts/hello/` is
  `public/posts/hello/index.html`, `/blog/feed.xml` is `public/feed.xml`, and
  `static/favicon.ico` is `public/favicon.ico`, served at
  `/blog/favicon.ico`. Deploy `public/` so that the host serves it at
  `/blog/`: as a GitHub Pages project site, behind a reverse proxy that
  forwards `/blog/` to it, or copied into the `blog/` directory of the host's
  document root.
- No `robots.txt` is generated. Crawlers read `robots.txt` only at the root of
  a host ([RFC 9309 §2.3](https://www.rfc-editor.org/rfc/rfc9309#section-2.3)),
  and the output root of a site under a base path is not the host's root. Add
  the rules, and a `Sitemap:` line naming `https://example.net/blog/sitemap.xml`,
  to the `robots.txt` of whatever serves the host's root. A
  `static/robots.txt` is still copied, but crawlers ignore it at
  `/blog/robots.txt`.
- Host configuration files in the output (`_headers`, `_redirects`) are read
  by a host that serves `public/` as its own root, so their paths are paths
  from the output root: a `redirect_from` rule reads
  `/old/ /blog/posts/hello/ 301`, its source without the base path and its
  target, the address the visitor's browser follows, with it. Cloudflare
  Pages serves a project at the root of its own hostname, so a Pages site
  under a sub-path of another host needs a proxy in front of it that forwards
  `/blog/` with the prefix removed.
- `isonim-blog serve` serves `public/` at the base path
  (`http://127.0.0.1:4000/blog/`), so the preview resolves the same URLs as
  the deployed site; other paths answer 404. `isonim-blog check` follows the
  links the same way.

## Images and OpenGraph images

Every `<img>` on a built page, from Markdown or from a layout, is checked and
served responsively:

- It gets `width` and `height` from the image file itself (a JPEG's Exif
  orientation is taken into account), so the page does not shift while it
  loads. An `<img>` that already has both keeps them; one given dimension
  scales the other.
- A PNG, JPEG, WebP or AVIF (one still frame) becomes a `<picture>` with one
  `<source srcset>` per format in `[images] formats`, at each width in
  `[images] widths` below the image's own width, plus its own width when a
  configured width reaches it: an image is never enlarged. `sizes` says the
  image is at most its own width. The original stays the `<img src>`
  fallback. Variants are fingerprinted under `assets/`, with metadata
  removed.
- SVGs pass through unchanged (with their declared size when they have one),
  and so do GIFs and animated images, which resizing would freeze.
- The first image of a page loads normally; every later one gets
  `loading="lazy"`.
- An image without alt text, one larger than `[images] max_source_bytes`, or
  a site path that names no file is an error naming the page. An image on
  another site keeps its markup, with a warning that it has no dimensions.

Every page also gets an OpenGraph image: a 1200x630 PNG referenced by
`og:image` and `twitter:image`, with a `summary_large_image` Twitter card.
It is rendered from an SVG template with [resvg](https://github.com/linebender/resvg)
and the bundled DejaVu fonts; the fonts installed on the machine are never
used. The built-in template shows the site title, the page title and the
post date. A site (or theme) replaces it with `og.svg.nim` at its root, a
module exporting

```nim
import isonim_blog/[model, og]
proc ogImage*(page: Page; site: Site): string =
  ## The SVG of the page's card; svgText escapes text, wrapLines breaks it.
  "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1200 630\">" &
    "<text x=\"80\" y=\"300\" font-size=\"64\">" & svgText(page.title) & "</text></svg>"
```

The SVG must be 1.91:1 and self-contained, so a template cannot read files.
A link (`href` under any namespace prefix, `src`, `xml:base`) must be a
`#fragment` or a `data:` URL, and CSS (in `<style>`, CDATA included, in a
`style` attribute or in any attribute's `url(...)`) may name only `#fragment`s;
anything else fails the build, as do `@import`, CSS escapes, a `<!DOCTYPE>`
(and with it any entity) and processing instructions such as
`<?xml-stylesheet?>`. A leading `<?xml ...?>` declaration is fine. Text uses the bundled DejaVu families; `serif`, `sans-serif` and
`monospace` mean DejaVu Sans. A page's `og_image` replaces its card: a URL, or
a file of the site named relative to the page's source (a file in a post
bundle) or to the site root.

The tools come from the Nix dev shell, the packaged CLI and `buildSite`, by
path: libvips (`ISONIM_BLOG_VIPS`), resvg (`ISONIM_BLOG_RESVG`) and the font
directory (`ISONIM_BLOG_OG_FONTS`). Both run with fixed settings, so the same
inputs give the same bytes; `isonim-blog build` keeps encoded variants under
`build/isonim-blog/images/` and reuses them.

## Zero JavaScript by default

With `scripts = "none"`, a built page contains no `<script>` element other
than `application/ld+json` and the configured analytics snippet. A layout
that emits any other script element, including an inert data block, fails the
build. The generated `_headers` carries a Content-Security-Policy whose
`script-src` names only the scripts the pages load. The script policy is
site-wide, so this is one rule for every path (`/*`), which keeps even a large
site far below Cloudflare Pages' limit of 100 header rules; a site's own
`static/_headers` is kept and the generated rules are appended to it.

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
isonim-blog build [--drafts] [--future] [--now <time>] [--out public] [--url <origin>] [--incremental]
```

Run it in the site's directory. It prints whether the site program was
compiled or reused, then a summary, and exits with status 0 or 1. `--url`
replaces the canonical origin, for preview deployments. `--now` sets the
build clock that decides which posts are future; with it, rebuilding the same
files gives the same bytes. Compiled programs and
their caches live under `build/isonim-blog/`. The output directory is written
completely before it replaces the previous one, so a failed build leaves the
last good output in place. It may not overlap the input directories.
With `--incremental` (what `isonim-blog serve` uses) the complete output is
still produced first, but then only the files whose bytes changed are written
into the existing output directory and the files the build no longer produces
are removed; unchanged files keep their timestamps.

`redirect_from` entries in front matter become permanent (301) rules in the
generated `_redirects`, after the site's own `static/_redirects` if it has
one. Each entry is a literal site path (`/2019/old-post.html`, `/old/`); an
entry claimed by two pages, or equal to a page's own URL, fails the build.

Every build writes `build.json`: the generator, the source revision (a commit
when the builder knows one, otherwise a content hash of every file the build
could read), the isonim-blog and theme revisions, `sourceDateEpoch` and a
hash of the output, so a deployed site can be matched to its sources.

## Reproducible builds with Nix

The flake exports `lib.<system>.buildSite`:

```nix
isonim-blog.lib.${system}.buildSite {
  src = self;               # needs lastModified > 0; a flake input or self has it
  theme = null;             # a theme directory or flake input; default: theme in site.toml
  drafts = false;
  url = null;               # overrides url from site.toml
  now = null;               # the build clock; default: src.lastModified
}
```

It builds the site in the Nix sandbox, with no network and only `site.toml`
and the declared directories copied in. `src.lastModified` is both
`SOURCE_DATE_EPOCH` and, unless `now` is given, the build clock. For a flake's
`self` it is the time of the last commit (a dirty tree has its last commit's
time), so it names the source, not the moment the build ran. `now` takes what
`--now` takes, or an integer number of seconds. A `src` whose `lastModified` is
missing or 0 has no known time; rather than build the blog of 1970, with every
post left out, evaluation fails, unless `now` is given, as an integer, which
then also dates the output. Nothing in the output depends
on when or where it is built and every listing is sorted, so
`nix build --rebuild` reproduces it byte for byte. It
wraps IsoNim's `buildStaticSite`, which compiles the site program against the
pinned IsoNim.

## Scheduled posts

A post dated in the future is left out until a build runs whose clock is past
its date. Nothing publishes it by itself, as with Jekyll and Hugo: a scheduled
post needs a build, and a deployment, on or after its date.

- `isonim-blog build` uses the current time, so a scheduled job that runs it
  (once a day, say) and deploys the output publishes each post on its date.
- The Nix build uses the time of the last commit, so rebuilding the same
  commit never publishes anything new: that is what keeps it reproducible. A
  commit made on or after the date publishes the post. To publish on schedule
  without a commit, give the flake a second package with the current time as
  its clock and build it from the scheduled job with `--impure` (the current
  time is not available to a pure evaluation):

  ```nix
  packages.scheduled = isonim-blog.lib.${system}.buildSite {
    src = self;
    now = builtins.currentTime;  # nix build --impure .#scheduled
  };
  ```

  Its output depends on the day it is built, so compare such builds by their
  `build.json`, not by store path.
