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
    nim check tests/test_plumbing.nim
    nixfmt --check flake.nix
    shellcheck scripts/*.sh
    shfmt -d scripts/*.sh
    actionlint

pre-commit:
    @mkdir -p test-logs
    prek run --all-files 2>&1 | tee test-logs/pre-commit.log

fmt:
    nimpretty src/*.nim src/isonim_blog/*.nim tests/*.nim
    nixfmt flake.nix
    shfmt -w scripts/*.sh

nix-build:
    @mkdir -p test-logs
    nix build --print-build-logs .#default 2>&1 | tee test-logs/nix-build.log

alias t := test
