# Development

The repository supplies the site model and the `build` command described in
[Building a site](../users/building-a-site.md). Feeds, archives, images, the
preview server, scaffolding and packaged themes are not implemented yet.
Start with the commands in [AGENTS.md](../../AGENTS.md).

## Source map

- `src/isonim_blog/model.nim`: backend-independent configuration, front
  matter, permalink and collision rules (tested on C and JavaScript).
- `src/isonim_blog/inputs.nim`: the native input boundary. It walks only the
  declared directories and decodes TOML with the pinned Python `tomllib`.
- `src/isonim_blog/program.nim`: generates the layout program from
  `layouts/` and `includes/` (code only) and compiles it once per source hash.
- `src/isonim_blog/runtime.nim`: what the compiled program runs; it reads the
  content and exports the site through `isonim/static`.
- `src/isonim_blog_prepare.nim`: the preparation step as a separate tool, used
  by the Reprobuild graph and by the Nix `buildSite` wrapper (`nix/site.nix`).
- `examples/basic/` is the generic fixture site; `tests/fixtures/` holds a
  theme and an islands site for the Nix checks and tests.

## Build graph

`repro.nim` builds the example site as separate edges: preparation reads only
layouts and includes, the compile reads the prepared program and library
sources, and the export reads the content. A content-only edit re-runs the
export and is a cache hit for the compile; a layout or include edit re-runs
preparation and the compile. Select it with `repro build example-basic`.
The export edge currently re-runs on every build: IsoNim publishes the output
directory with a raw `renameat2` system call that the Reprobuild monitor does
not yet observe, so the engine conservatively withholds that edge's cache
record. The prepare and export tools are built by the graph itself, so their
edges run them with `inlineExecCall` and depend on the producing compile.

## Dependencies

`config.nims` resolves `isonim` and `nim-everywhere` from real sibling checkouts
when they exist. Otherwise it uses the sources pinned in `flake.lock`, exported
by the dev shell as `ISONIM_BLOG_ISONIM_SRC` and
`ISONIM_BLOG_NIM_EVERYWHERE_SRC`. `ISONIM_BLOG_PINNED_SOURCES=1` selects only
those pinned sources even when siblings exist; the Nix package always sets it.
An absent selected dependency fails the compile.

The same config is used for direct Nim commands and the typed Reprobuild
graph. Build and test execution are separate graph edges. Use `just build` and
`just test`, which delegate to Reprobuild and capture logs under `test-logs/`.
The Nimble manifest supplies package metadata and dependency declarations;
it does not define workflow tasks. For direct compilation, name both output and
cache paths, for example:

```sh
nim c -r --out:build/tests/test_plumbing --nimcache:build/nimcache/direct-c tests/test_plumbing.nim
```

The Nimble manifest owns the version. No release is implied by a development
build reporting that version. `nix build` installs `bin/isonim-blog`,
`bin/isonim-blog-prepare` and the Apache-2.0 license, after running every test
suite inside the sandbox against locked inputs, with no sibling checkouts or
network access. `just nix-build` also builds the `example-basic`,
`build-site-contract` and `build-site-islands` checks; `nix build
.#checks.<system>.example-basic --rebuild` verifies a byte-identical rebuild.

## Hooks

The flake imports the shared `mcl-standard-hooks` set and adds `just lint` and
an always-running license-presence check. Its generated configuration is ignored
by Git. Enter the shell from this repository so installation targets it; if
Reprobuild hooks need repair, use `repro hooks ensure --vcs`.

## CI qualification

CI covers Linux x64/arm64 and macOS arm64 through the Nix environment. Windows
is not currently a supported development or package target. The native CLI
and backend-independent tests are both built; no browser tooling is needed.

Each platform resolves its runner through the shared chooser and the
organization/repository Actions variable `CI_RUNNER_MODE`. With the variable
unset, this public repository uses GitHub-hosted runners: `ubuntu-24.04` for
Linux x64, `ubuntu-24.04-arm` for Linux arm64, and `macos-15` for macOS arm64.
Explicit `github-hosted` selects those same runners. `self-hosted` or an
unrecognized value selects the corresponding `[self-hosted, linux, x64]`,
`[self-hosted, linux, arm64]` or `[self-hosted, macos, arm64]` capability labels.
The test and package gates run on all three native platforms; pre-commit runs
on Linux x64. Job and artifact names use the platform, independent of mode.

Normal CI runs on `dev` and `stable` pushes and pull requests targeting those
branches. A reviewed bootstrap candidate can also be qualified by pushing its
exact commit to a temporary `ci/qualify-bootstrap-<identifier>` branch. This
explicit opt-in runs the same gates without a promotion. Retain the run URL and
tested SHA, and remove the temporary branch after qualification. No trigger
matches `agents` or `agents-to-dev-*` pushes.
