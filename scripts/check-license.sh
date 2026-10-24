#!/usr/bin/env bash
set -euo pipefail
if [[ ! -f LICENSE ]]; then
	echo 'Missing root LICENSE (Apache-2.0).' >&2
	exit 1
fi
