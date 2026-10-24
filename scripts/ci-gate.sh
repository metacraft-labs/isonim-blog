#!/usr/bin/env bash
# Run from the repository root: capture activation as well as the gate itself.
set -euo pipefail
if [[ $# != 1 ]]; then
	echo 'Usage: bash scripts/ci-gate.sh <test|nix-build|pre-commit>' >&2
	exit 2
fi
case "$1" in
test | nix-build | pre-commit) ;;
*)
	echo "Unknown CI gate: $1" >&2
	exit 2
	;;
esac

mkdir -p test-logs
nix_args=(develop)
if [[ -n ${RUNNER_TEMP:-} ]]; then
	# Keep the activated closure rooted for the lifetime of the CI job.
	nix_args+=(--profile "$RUNNER_TEMP/isonim-blog-dev-shell")
fi
# Each Just target owns its own log; a distinct outer log keeps activation
# output intact when that target starts its tee. pipefail retains failures.
nix "${nix_args[@]}" --command just "$1" 2>&1 | tee "test-logs/ci-$1.log"
