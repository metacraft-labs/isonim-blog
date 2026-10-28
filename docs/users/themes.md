# Themes

A theme gives a site its layouts, includes, assets, OpenGraph card and
design tokens. Its directory mirrors a site:

```
my-theme/
├── theme.toml        # the manifest (below)
├── tokens.json       # design tokens (W3C DTCG), any file names
├── layouts/          # post.nim, page.nim, index.nim, tag.nim, category.nim, archive.nim, ...
├── includes/         # Nim modules the layouts import; directives.nim (optional)
├── assets/           # stylesheets, fonts, images: fingerprinted like a site's
├── og.svg.nim        # optional OpenGraph card template
└── README.md
```

isonim-blog ships one theme, `isonim-blog-theme-minimal` (`themes/minimal/`),
which `new site` selects. It is plain, accessible (WCAG 2.2 AA in the light
and the dark scheme) and uses no JavaScript.

## Long code lines and wide tables

The Markdown renderer emits every fenced code block as `<pre tabindex="0">`
and wraps every table in a scroll region:

```html
<div class="table-scroll" role="region" tabindex="0" aria-label="Table">
  <table>
    ...
  </table>
</div>
```

A theme can therefore let a code line or a table that is wider than the
column scroll inside its own box (`overflow-x: auto` on `pre` and
`.table-scroll`) without widening the page. Each of those boxes can be
focused, so a reader without a pointer can reach it and scroll it with the
arrow keys: WCAG 2.2 success criterion 2.1.1
(<https://www.w3.org/TR/WCAG22/#keyboard>) asks for that, and axe-core's
`scrollable-region-focusable` rule checks it. A scrolling box without
`tabindex` (a `table` given `overflow-x: auto` itself, say) fails the check.

The minimal theme scrolls both by default, as Hugo, Astro and most other
static site generators do: a wrapped code line cannot be told from two
lines, which matters in Python, YAML and shell, and in copied code. A site
that prefers wrapped code lines sets this in `site.toml`:

```toml
wrap_code = true    # default false: long code lines scroll
```

The theme then adds the class `wrap-code` to the `<main>` element, and its
stylesheet wraps the lines of every code block inside it. Wide tables keep
scrolling. Any other value than `true` or `false` fails the build. When
printed, code lines and table cells always wrap.

## Naming a theme in `site.toml`

```toml
theme = "isonim-blog-theme-minimal"   # a theme package, by name
theme = "themes/notebook"             # or a directory, relative to the site
```

A value containing `/` (or starting with `.`) is a directory. A site-local
theme lives in the site's own repository, for example `themes/notebook/`,
and works exactly like a packaged one; nothing else in the repository is
read, so it needs no exclude list.

Any other value is a package name. The CLI looks for it first in each
directory of `ISONIM_BLOG_THEME_PATH` (separated like `PATH`): a directory
that is itself the theme, or that holds it as `<name>/`. Then it looks among
the themes isonim-blog ships.

The theme found must have that `name` in its `theme.toml`.

### As a flake input

`lib.<system>.buildSite` resolves the shipped themes by name. A theme from
another repository is a flake input passed as `theme`:

```nix
inputs.notebook-theme = {
  url = "github:example/notebook-theme";
  flake = false;
};
# ...
packages.default = isonim-blog.lib.${system}.buildSite {
  src = self;
  theme = inputs.notebook-theme;
};
```

If `site.toml` names the theme by package name, the build checks that the
input's `theme.toml` has that name. To use the same theme with the CLI in the
site's dev shell, export its path:
`shellHook = "export ISONIM_BLOG_THEME_PATH=${inputs.notebook-theme}";`.
`build.json` records the input's revision as the theme revision.

### As a Nimble package

A theme can be published as a Nimble package whose `installDirs` and
`installFiles` are the theme's files (see
`themes/minimal/isonim_blog_theme_minimal.nimble`). After `nimble install`,
add `nimble path <package>` to `ISONIM_BLOG_THEME_PATH`.

## `theme.toml`

```toml
name = "isonim-blog-theme-notebook"     # required: lower-case letters, digits, dashes
version = "1.0.0"
description = "A notebook look"
tokens = ["tokens/ref.json", "tokens/sys.json"]   # DTCG documents, merged in order
stylesheets = ["assets/notebook.css", "assets/print.css"]   # linked by every page
theme_color = "sys.color.surface"       # a color token: <meta name="theme-color">
required = ["description", "author.name"]   # site.toml keys the theme needs
directives = ["pullquote"]              # registered by includes/directives.nim

[config]                                # defaults for site.toml; the site's values win
paginate = 8

[config.feeds]
per_tag = false
```

Every key except `name` is optional; an unknown key is an error.

- **`tokens`.** Design tokens in the W3C Design Tokens Community Group format
  (<https://tr.designtokens.org/format/>): leaves with `$value` (and `$type`,
  possibly on a group), aliases written `{group.token}`, resolved across all
  the files. A token that differs between colour schemes gives its scheme
  values in `$extensions.modes`, as design tools export them:

  ```json
  "surface": {
    "$type": "color",
    "$value": "{ref.color.white}",
    "$extensions": { "modes": { "light": "{ref.color.white}", "dark": "{ref.color.night}" } }
  }
  ```

  The build writes every token with a single value as a CSS custom property
  (`sys.color.surface` becomes `--sys-color-surface`) in a generated
  `assets/theme-tokens.css`: light values on `:root`, dark values under
  `@media (prefers-color-scheme: dark)`. The scheme follows the reader's
  system setting; no script is involved. Composite tokens (such as
  `typography`) are not written to CSS but layouts can read them. Every page
  links this stylesheet first. A value that could end a CSS declaration
  (`;`, `{`, `}`, `<`, comments) is refused.

- **`stylesheets`.** `.css` files under the theme's `assets/`, linked by
  every page after the token stylesheet. A print stylesheet is an ordinary
  stylesheet whose rules sit inside `@media print`.
- **`theme_color`.** A color token. Pages get one `theme-color` meta per
  scheme when the token has a dark value, else one.
- **`required`.** Dotted `site.toml` keys (`author.name`). A build of a site
  that leaves one unset, or empty, fails naming every missing key.
- **`config`.** Default values for `site.toml`, under the site's own. Tables
  merge key by key (a site that sets `[feeds] rss` keeps the theme's other
  `[feeds]` defaults); lists and values are replaced whole. A theme cannot
  default `theme`, `url` or `base_path`.
- **`directives`.** The custom `:::name` Markdown blocks the theme provides.
  `includes/directives.nim` exports them:

  ```nim
  import isonim/content/[markdown, directives]

  proc directives*(): seq[DirectiveRegistration] =
    @[DirectiveRegistration(name: "pullquote",
      render: proc(args, body: string): seq[Block] =
        @[Block(kind: bkBlockquote, quoteBlocks: parseMarkdownDoc(body).blocks)])]
  ```

  A directive listed in `theme.toml` that this module does not register fails
  the build. A site's own `includes/directives.nim` replaces the theme's and
  may register more.

## Layouts and what layouts see

Layouts and includes are the Nim modules described in
[Building a site](building-a-site.md#layouts-and-includes). A complete theme
provides the layouts the build selects by default: `post`, `page` (pages and
collection entries), `index`, `tag`, `category` and `archive` (year and month
archives). Any other layout a page names with `layout:` works too.

`site.theme` gives layouts the theme's `name`, `version`, resolved `tokens`
(`site.theme.tokens["sys.color.text"]["value"]`, and `["dark"]` when the
token has one) and the `stylesheets` URLs. Front-matter fields isonim-blog
does not interpret reach layouts in `page.extra`, so a theme can choose a
layout variant from fields of its own (`kind`, `status`, `credits`, ...).
`listing.pageAssetUrl(site, page, page.image)` turns a front-matter image
path into its fingerprinted URL.

A theme carries interactive behaviour without JavaScript the way the
fixture theme in `tests/fixtures/theme-capabilities/` does: state switched
with radio inputs and `:has()`, popovers opened with `popovertarget`,
scroll-driven animation (`animation-timeline: scroll()`), a print
stylesheet, and layouts that follow `page.extra`.

## Overriding a theme file

A site file wins over the theme's file of the same path: a layout, an
include, an asset (stylesheets included) or `og.svg.nim`. To start from the
theme's version, copy it into the site:

```sh
isonim-blog theme eject layouts/post.nim
isonim-blog theme eject assets/minimal.css
```

`eject` copies files from `layouts/`, `includes/`, `assets/` and
`og.svg.nim`, and never overwrites a file the site already has. Delete the
copy to return to the theme's file. To change the colours without touching
the theme, put your own `assets/theme-tokens.css` in the site; it replaces
the generated one.

## Checking a theme

From a checkout of isonim-blog, in its dev shell:

```sh
just test-theme themes/minimal
just test-theme /path/to/my-theme
```

The conformance kit builds a generic fixture site (every page kind and every
content feature, with no layouts of its own) with the theme and checks that:

- `theme.toml` is valid and the tokens resolve;
- every required layout exists (a missing one is named);
- the fixture builds, every page kind is produced, and the declared
  directives are exactly the registered ones;
- no page carries a script or an inline event handler, and the output has no
  JavaScript file;
- every page links the theme's stylesheets;
- `isonim-blog check` finds no broken link or anchor, missing alt text or
  invalid feed;
- in Chromium, axe-core finds no WCAG 2.0, 2.1 or 2.2 level A or AA
  violation on any page, in the light and the dark scheme, at 360 and 1280
  pixels wide, and no page scrolls sideways at 360 pixels. Its summary
  counts the boxes that scroll sideways inside the pages at 360 pixels
  (`pre 2, div.table-scroll 2` for the minimal theme), so you can see
  whether the theme scrolls or wraps wide content.

It exits with status 1 and names each problem when a check fails, and keeps
the build for inspection.
