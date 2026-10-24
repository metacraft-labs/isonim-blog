# isonim-blog

A static-blog framework being built on [IsoNim](https://github.com/metacraft-labs/isonim).

This development snapshot provides a bootstrap CLI with help and version
reporting. Site generation, preview and themes are not available yet.

With Nix installed, build and inspect the CLI:

```sh
nix build
./result/bin/isonim-blog --help
./result/bin/isonim-blog --version
```

See the [development notes](docs/contributors/development.md) and
[agent guide](AGENTS.md) to contribute. Licensed under [Apache-2.0](LICENSE).
