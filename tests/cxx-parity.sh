#!/bin/bash
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
#
# Compare the C++ interface of our framework with Apple's.  tests/cxx_driver
# runs every case twice under tests/fake_daemon.dylib (which answers in place
# of analyticsd, so nothing reaches the real daemon): once against /System's
# CoreAnalytics and once with DYLD_FRAMEWORK_PATH pointing at ours.  Output,
# including the messages the fake daemon receives, must be identical.
#
#   DRV=build/release/cxx_driver FAKE=build/release/fake_daemon.dylib \
#   FWDIR=build/release bash tests/cxx-parity.sh
set -uo pipefail
cd "$(dirname "$0")/.."
: "${DRV:?}" "${FAKE:?}" "${FWDIR:?}"
export TZ=America/New_York	# dates in the text form use local time

TOOLS="has_config log_dump log_dump0 log_transform_counts config_list config_info
config_dump query_list transform_info get_cache_list app_usage_sync query_state
set_tasking set_tasking_ndjson transform_evict transform_persist is_event_used
config_reload reboot_clear query_clear query_clear0 insert_query_state save
commit rollover"

# Daemon replies: the generic shapes, the tool's own field holding each
# kind of value, and the other fields some tools read.
REPLIES=("FAKE_REPLY=nondict" "FAKE_REPLY=empty" "FAKE_REPLY=error" "FAKE_REPLY=text")
for t in str strtrue true false int zero neg uint uzero double; do
	REPLIES+=("FAKE_REPLY=key FAKE_KEY=@ FAKE_TYPE=$t")
done
for k in config-info transforms-in-cache appusage event-used; do
	REPLIES+=("FAKE_REPLY=key FAKE_KEY=$k FAKE_TYPE=str" "FAKE_REPLY=key FAKE_KEY=$k FAKE_TYPE=true")
done

# Every XPC type in AppleSauce's text form (config_list's fallback).
TEXT_TYPES="str int uint double true null date data uuid emptyarr arr nested error interrupted fd"

cases=0
fails=0

# run <env...> -- <driver args...>: output of one side, sorted (sends and
# observers run on other threads) and with addresses masked.
run() {
	local envs=()
	while [ "$1" != "--" ]; do envs+=("$1"); shift; done
	shift
	env "${envs[@]}" DYLD_INSERT_LIBRARIES="$FAKE" "$DRV" "$@" 2>&1 |
	    sed -E 's/0x[0-9a-f]+/0x/g' | sort
}

check() {	# check <label> <env...> -- <driver args...>
	local label=$1; shift
	local apple ours
	apple=$(run "$@")
	ours=$(run DYLD_FRAMEWORK_PATH="$PWD/$FWDIR" "$@")
	cases=$((cases + 1))
	if [ "$apple" != "$ours" ]; then
		fails=$((fails + 1))
		echo "cxx-parity: $label differs:"
		diff <(echo "$apple") <(echo "$ours") | head -10
	fi
}

for reply in "${REPLIES[@]}"; do
	for t in $TOOLS; do
		check "$t [$reply]" $reply -- tool "$t"
	done
done
for t in $TEXT_TYPES; do
	check "text form of $t" FAKE_REPLY=key FAKE_KEY=v FAKE_TYPE=$t -- tool config_list
done
for s in client config error; do
	check "$s" FAKE_REPLY=text -- "$s"
done

if [ "$fails" -ne 0 ]; then
	echo "cxx-parity: $fails of $cases cases differ"
	exit 1
fi
echo "cxx-parity: $cases cases identical"
