set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

build:
    @mkdir -p test-logs
    repro build 2>&1 | tee test-logs/build.log

test:
    @mkdir -p test-logs
    repro test 2>&1 | tee test-logs/test.log

# Keep this separate from prek: the pre-commit lint hook calls this recipe.
lint:
    @mkdir -p test-logs
    just lint-checks 2>&1 | tee test-logs/lint.log

lint-checks:
    bash scripts/check-license.sh
    nim check src/isonim_blog_cli.nim
    nim check src/isonim_blog_prepare.nim
    for suite in tests/test_*.nim; do nim check "$suite"; done
    nim check tests/theme_kit.nim
    nim check tests/theme_kit_controls.nim
    node --check tests/theme_kit_browser.mjs
    nixfmt --check flake.nix nix/site.nix
    shellcheck scripts/*.sh
    shfmt -d scripts/*.sh
    actionlint

pre-commit:
    @mkdir -p test-logs
    prek run --all-files 2>&1 | tee test-logs/pre-commit.log

fmt:
    nimpretty src/*.nim src/isonim_blog/*.nim tests/*.nim
    nixfmt flake.nix nix/site.nix
    shfmt -w scripts/*.sh

# The package (with every suite in the sandbox) and the site-builder checks.
nix-build:
    @mkdir -p test-logs
    system="$(nix eval --raw --impure --expr builtins.currentSystem)"; \
    nix build --print-build-logs .#default \
        ".#checks.$system.example-basic" \
        ".#checks.$system.theme-minimal" \
        ".#checks.$system.build-site-contract" \
        ".#checks.$system.build-site-clock" \
        ".#checks.$system.build-site-source-clock" \
        ".#checks.$system.build-site-islands" 2>&1 | tee test-logs/nix-build.log
    @# build-site-source-clock proves an unknown source time is refused; this
    @# proves the refusal says why (the message is not visible to tryEval).
    system="$(nix eval --raw --impure --expr builtins.currentSystem)"; \
    if message="$(nix eval --impure --raw --expr "(((builtins.getFlake (toString ./.)).lib.$system.buildSite { src = { outPath = ./examples/basic; lastModified = 0; }; }).drvPath)" 2>&1)"; then \
        echo "buildSite accepted lastModified = 0" >&2; exit 1; \
    fi; \
    grep -qF 'src carries no source time (lastModified is 0)' <<<"$message" || { echo "$message" >&2; exit 1; }

# The theme conformance kit: check a theme directory (the shipped
# themes/minimal, a theme package, or a private site-local theme) against
# the generic fixture, including axe-core in Chromium in both colour schemes.
test-theme theme:
    @mkdir -p test-logs build/bin
    nim c --hints:off -d:release --out:build/bin/theme-kit --nimcache:build/nimcache/theme-kit tests/theme_kit.nim
    theme={{ quote(theme) }}; case "$theme" in /*) ;; *) theme={{ quote(invocation_directory()) }}/"$theme" ;; esac; \
        build/bin/theme-kit "$theme" 2>&1 | tee test-logs/test-theme.log

# The kit's browser checks must fail for broken themes: low contrast in
# either scheme, sideways scrolling at 360px, a script, a missing layout.
test-theme-controls:
    @mkdir -p test-logs build/bin
    nim c --hints:off -d:release --out:build/bin/theme-kit --nimcache:build/nimcache/theme-kit tests/theme_kit.nim
    nim c -r --hints:off --out:build/bin/theme-kit-controls --nimcache:build/nimcache/theme-kit-controls tests/theme_kit_controls.nim 2>&1 | tee test-logs/test-theme-controls.log

alias t := test
