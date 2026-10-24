# isonim-blog

A static-blog framework being built on [IsoNim](https://github.com/metacraft-labs/isonim).

This development snapshot builds sites: posts, drafts, pages, collections,
data and assets, rendered through layouts written as IsoNim components, with
zero JavaScript by default and byte-reproducible Nix builds. Feeds, archives,
images, the preview server, project scaffolding and packaged themes are not
available yet. See [Building a site](docs/users/building-a-site.md).

With Nix installed, build the CLI and the example site:

```sh
nix build
cd examples/basic && ../../result/bin/isonim-blog build
```

See the [development notes](docs/contributors/development.md) and
[agent guide](AGENTS.md) to contribute. Licensed under [Apache-2.0](LICENSE).
