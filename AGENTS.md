# isonim-blog contributor and agent guide

This public repository is a static-blog framework on IsoNim. The CLI
implements `build` (see `docs/users/building-a-site.md`), `--help` and
`--version`, with archives, feeds and the sitemap; images, `serve`, `new` and
themes are later work.

Enter this repository's `nix develop` shell before running commands:

```sh
just build       # typed Reprobuild CLI compile
just test        # every suite on C, plus the backend-independent ones on JavaScript
just lint        # Nim, Nix, shell, workflow and license checks
just pre-commit  # the shared hook set, plus repository checks
just fmt         # format Nim, Nix and shell sources
nix build        # CLI package, with every suite run in the sandbox
just nix-build   # the package plus the sandboxed site-builder checks
```

Run the complete suite during development and before every push: seven suites
(30 cases) on C, and the two backend-independent suites (12 cases) on
JavaScript too. The site suites compile real site programs with the real Nim
compiler; no browser or server is needed.
On Linux x86_64, with the site-model changes on top of `c8bfe2f2`, a cold
`repro test` (fresh action cache, provider already compiled) took 339 seconds
on 2026-10-25; unchanged edges are reused on later runs.
`just test` delegates to `repro test`; use its recorded history when available
to investigate failures. Record measured timings with the tested revision.

`src/isonim_blog.nim` is the library entry point and `src/isonim_blog_cli.nim`
owns process I/O. The development notes map the remaining modules. Tests use
the generic `examples/basic/` site; never add personal or private content.
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
