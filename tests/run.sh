#!/bin/bash
# Run shellcheck on every script and the bats suite. Uses local tools when
# installed, otherwise the pinned Docker images.
#
# Copyright (C) 2025-2026 Makondoo Inc.
# Licence: AGPL-3.0-or-later
set -euo pipefail
cd "$(dirname "$0")/.."

SHELLCHECK_IMAGE=koalaman/shellcheck:v0.10.0
BATS_IMAGE=bats/bats:1.11.1

mapfile -t SCRIPTS < <(git ls-files -co --exclude-standard '*.sh' 'bin/*' | grep -v '^tests/reference_v1')

echo "== shellcheck (${#SCRIPTS[@]} files)"
if command -v shellcheck >/dev/null; then
    shellcheck -S warning -x "${SCRIPTS[@]}"
else
    docker run --rm -v "$PWD:/mnt:ro" "$SHELLCHECK_IMAGE" -S warning -x "${SCRIPTS[@]}"
fi

echo "== bats"
if command -v bats >/dev/null; then
    bats tests
else
    docker run --rm -v "$PWD:/code:ro" "$BATS_IMAGE" tests
fi
