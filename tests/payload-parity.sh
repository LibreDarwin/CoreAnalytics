#!/bin/bash
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Byte-compare the event JSON our framework sends with what Apple's sends
# for the same payloads.  tests/payload_gen is run twice with
# tests/capture_send.dylib inserted, which records every outgoing "send"
# message and answers it locally (nothing reaches analyticsd): once
# against /System's CoreAnalytics and once with DYLD_FRAMEWORK_PATH
# pointing at ours.
#
#   GEN=build/release/payload_gen CAP=build/release/capture_send.dylib \
#   FWDIR=build/release bash tests/payload-parity.sh [count]
set -euo pipefail
cd "$(dirname "$0")/.."
: "${GEN:?}" "${CAP:?}" "${FWDIR:?}"
COUNT=${1:-20000}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

CAP_OUT="$TMP/apple" DYLD_INSERT_LIBRARIES="$CAP" "$GEN" "$COUNT"
CAP_OUT="$TMP/ours" DYLD_INSERT_LIBRARIES="$CAP" DYLD_FRAMEWORK_PATH="$PWD/$FWDIR" "$GEN" "$COUNT"

apple=$(wc -l < "$TMP/apple" | tr -d ' ')
ours=$(wc -l < "$TMP/ours" | tr -d ' ')
if [ "$apple" -lt 100 ]; then
	echo "payload-parity: only $apple messages captured from Apple's framework" >&2
	exit 1
fi
if ! cmp -s "$TMP/apple" "$TMP/ours"; then
	echo "payload-parity: output differs (Apple $apple lines, ours $ours lines):"
	diff "$TMP/apple" "$TMP/ours" | head -20
	exit 1
fi
echo "payload-parity: $apple payloads identical"
