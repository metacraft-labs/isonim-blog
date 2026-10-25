# isonim-blog

A static-blog framework being built on [IsoNim](https://github.com/metacraft-labs/isonim).

This development snapshot builds sites: posts, drafts, pages, collections,
data and assets, rendered through layouts written as IsoNim components, with
tag, category and year archives, a paginated post index, RSS and Atom feeds,
a sitemap and JSON-LD metadata, responsive images and generated OpenGraph
images, zero JavaScript by default and byte-reproducible Nix builds. The CLI
creates sites and posts, previews them with live reload, checks links, feeds
and front matter, and can generate a Cloudflare Pages deployment recipe.
Themes are packages (or directories in the site's repository); new sites use
the shipped `isonim-blog-theme-minimal`, plain, accessible and script-free.

With Nix installed:

```sh
nix build                                   # the CLI, in ./result
./result/bin/isonim-blog new site my-blog   # add --deploy cloudflare-pages for the recipe
cd my-blog
../result/bin/isonim-blog serve             # http://127.0.0.1:4000/, reloads on every edit
../result/bin/isonim-blog check             # links, anchors, front matter, feeds
../result/bin/isonim-blog build             # the site, in public/
```

See [Writing and previewing](docs/users/writing-and-previewing.md),
[Building a site](docs/users/building-a-site.md), [Themes](docs/users/themes.md) and
[Deploying to Cloudflare Pages](docs/users/deploying-to-cloudflare-pages.md).

See the [development notes](docs/contributors/development.md) and
[agent guide](AGENTS.md) to contribute. Licensed under [Apache-2.0](LICENSE).
