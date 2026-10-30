# isonim-blog-theme-minimal

The default theme of isonim-blog: one readable column, the reader's light or
dark colour scheme, no JavaScript, and accessible markup (WCAG 2.2 AA in both
schemes, checked by `just test-theme themes/minimal`).

A new site uses it (`isonim-blog new site` writes
`theme = "isonim-blog-theme-minimal"` to `site.toml`). The packaged CLI and
`lib.<system>.buildSite` find it by that name.

## What it styles

Every page kind the build produces: posts (with date, update, tags,
categories, series, hero image and draft notice), pages, collection entries,
the paginated post index, tag, category, year and month pages. In content:
headings, paragraphs, links, lists, task lists, quotations, inline and fenced
code, tables, figures and captions, footnotes, asides, maths and diagrams.
The footer links the RSS and Atom feeds; a tag page links its own feed.

Wide code and tables scroll inside their own boxes and diagrams scale down to
the column, so the page does not scroll sideways on a 360-pixel screen. A
display formula wider than the column is the exception: MathML does not
shrink, and the renderer gives formulas no focusable box to scroll in, so
such a formula widens the page. A print stylesheet
drops the site chrome and spells out external links.

## Configuration

- `description` in `site.toml` is required: the header shows it.
- `data/navigation.toml` (or `.json`) adds a navigation list:
  `items = [{ title = "About", url = "/about/" }]`. URLs starting with `/`
  are site paths, placed under `base_path`.
- `author = { name, url }` adds a byline to the footer.
- `wrap_code = true` wraps long code lines instead of scrolling them inside
  their block (default `false`). Wide tables scroll either way. See
  "Long code lines and wide tables" in the isonim-blog theme documentation.

## Changing it

Colours, fonts and sizes are design tokens in `tokens.json` (W3C DTCG
format). The build writes them as CSS custom properties
(`--sys-color-text`, ...) in `assets/theme-tokens.css`; a token's dark value
is in `$extensions.modes`. To change a file, copy it into your site with
`isonim-blog theme eject <file>` (for example `assets/minimal.css` or
`layouts/post.nim`); the site's copy then wins. To replace the colours, put
your own `assets/theme-tokens.css` in the site.

## License

Apache-2.0, like isonim-blog.
