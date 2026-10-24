# isonim-blog contributor and agent guide

This public repository bootstraps a static-blog framework on IsoNim. The CLI
currently implements `--help` and `--version`; site generation is not available.

Enter this repository's `nix develop` shell before running commands:

```sh
just build       # typed Reprobuild CLI compile
just test        # all bootstrap tests, compiled and run on C and JavaScript
just lint        # Nim, Nix, shell, workflow and license checks
just pre-commit  # the shared hook set, plus repository checks
just fmt         # format Nim, Nix and shell sources
nix build        # CLI package, with sandboxed C and JavaScript tests
```

Run the complete bootstrap suite during development and before every push.
It contains four small cases on each backend; no browser or server is needed.
At seed `35f721b8` plus the bootstrap changes, `just test` took 36 seconds on
Linux after provider compilation; the first recipe compilation takes minutes.
`just test` delegates to `repro test`; use its recorded history when available
to investigate failures. Record measured timings with the tested revision.

`src/isonim_blog.nim` is the library entry point, `src/isonim_blog_cli.nim`
owns process I/O, and `tests/test_plumbing.nim` exercises the real dependencies
and command interface. `config.nims` chooses sibling sources for development
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
