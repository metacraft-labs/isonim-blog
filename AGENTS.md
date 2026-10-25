# isonim-blog contributor and agent guide

This public repository is a static-blog framework on IsoNim. The CLI
implements `build` (see `docs/users/building-a-site.md`), with archives,
feeds, the sitemap, responsive images and OpenGraph images; `new`,
`publish-draft`, `serve` and `check` (`docs/users/writing-and-previewing.md`);
the Cloudflare Pages recipe (`docs/users/deploying-to-cloudflare-pages.md`);
themes as packages, `theme eject` and the shipped `themes/minimal`
(`docs/users/themes.md`); `--help` and `--version`.

Enter this repository's `nix develop` shell before running commands:

```sh
just build       # typed Reprobuild CLI compile
just test        # every suite on C, plus the backend-independent ones on JavaScript
just lint        # Nim, Nix, shell, workflow and license checks
just pre-commit  # the shared hook set, plus repository checks
just fmt         # format Nim, Nix and shell sources
nix build        # CLI package, with every suite run in the sandbox
just nix-build   # the package plus the sandboxed site-builder checks
just test-theme themes/minimal  # theme conformance kit, axe-core in Chromium
just test-theme-controls        # the kit must fail for broken themes
```

Run the complete suite during development and before every push: sixteen
suites on C, and the three backend-independent suites on JavaScript too.
After changing a theme, the theme format or the content renderer, also run
`just test-theme themes/minimal` and `just test-theme-controls`: they drive
the dev shell's pinned Playwright Chromium and axe-core, so they run outside
the sandboxed and Reprobuild suites. The site suites compile real site programs with the real
Nim compiler; no browser is needed. The image and OpenGraph suites run the
libvips and resvg the dev shell provides; the serve suite runs a real server
on a loopback port; the check suite starts a local HTTP server for
`--external`. `test_cli_scaffold` and `test_deploy_recipe` build generated
site flakes with `nix build` (the deploy suite with a stub `wrangler`), so
they need the Nix daemon and are not part of the package's sandboxed check
phase; their first run builds the CLI package, which takes several minutes.
On Linux x86_64, with the site-model changes on top of `c8bfe2f2`, a cold
`repro test` (fresh action cache, provider already compiled) took 339 seconds
on 2026-10-25; unchanged edges are reused on later runs.
`just test` delegates to `repro test`; use its recorded history when available
to investigate failures. Record measured timings with the tested revision.

`src/isonim_blog.nim` is the library entry point and `src/isonim_blog_cli.nim`
owns process I/O. The development notes map the remaining modules. Tests use
the generic `examples/basic/` site and `tests/fixtures/`; never add personal
or private content, and never a theme other than generic ones.
`config.nims` chooses sibling sources for development
and locked Nix inputs for standalone and sandboxed builds. See
[development notes](docs/contributors/development.md) for source selection.

Keep public files and commit messages self-contained and user-facing. Add no
private repository links. Use `AGENTS.md` for instructions, never `CLAUDE.md`.
Keep compile outputs and per-edge caches under `build/`. Tests use real APIs;
justify any test double in its file header. Do not weaken tests to land a change.

Product mainline: `dev`; agent landing branch: `agents`. Run local gates on
`agents`; CI does not run on it or on `agents-to-dev-*` pushes. Promotion is a
separate integration operation. The dev shell installs the standard hooks while
retaining Reprobuild dispatchers. Never bypass a hook or force-push shared work.
