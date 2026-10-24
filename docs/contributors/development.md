# Development

The repository currently supplies the build plumbing and a CLI with help and
version reporting. The site model, generation, preview server and themes are
not implemented yet. Start with the commands in [AGENTS.md](../../AGENTS.md).

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
build reporting that version. `nix build` installs `bin/isonim-blog` and its
Apache-2.0 license, after running the C and JavaScript test binaries inside the
sandbox against locked inputs, with no sibling checkouts or network access.

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
