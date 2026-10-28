#!/bin/bash
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
# Check that our framework exports exactly the C symbols listed in
# src/CoreAnalytics/CoreAnalytics.exp and that each one is also exported by
# Apple's CoreAnalytics (read from the shared cache with dyld_info).
set -euo pipefail
cd "$(dirname "$0")/.."
FW=${FW:?set FW to the built framework binary}
APPLE=/System/Library/PrivateFrameworks/CoreAnalytics.framework/CoreAnalytics

ours=$(nm -gU "$FW" | awk '{print $3}' | sort)
want=$(sort src/CoreAnalytics/CoreAnalytics.exp)
apple=$(dyld_info -exports "$APPLE" | awk 'NR>2 {print $2}' | sort)

fail=0
if [ "$ours" != "$want" ]; then
	echo "export list mismatch:"; diff <(echo "$want") <(echo "$ours") || true
	fail=1
fi
missing=$(comm -23 <(echo "$want") <(echo "$apple"))
if [ -n "$missing" ]; then
	echo "not exported by Apple: $missing"; fail=1
fi
[ $fail = 0 ] && echo "exports: $(echo "$ours" | wc -l | tr -d ' ') symbols match"
exit $fail
