#!/bin/bash
# Copyright (C) 2026, LibreDarwin
# SPDX-License-Identifier: BSD-3-Clause
# Check that our framework exports exactly the C symbols listed in
# src/CoreAnalytics/CoreAnalytics.exp and that each one is also exported by
# Apple's CoreAnalytics (read from the shared cache with dyld_info), in
# every architecture slice; ARCHS lists the slices the binary must have.
set -euo pipefail
cd "$(dirname "$0")/.."
FW=${FW:?set FW to the built framework binary}
ARCHS=${ARCHS:?set ARCHS to the expected architectures}
APPLE=/System/Library/PrivateFrameworks/CoreAnalytics.framework/CoreAnalytics

want=$(sort src/CoreAnalytics/CoreAnalytics.exp)
apple=$(dyld_info -exports "$APPLE" | awk 'NR>2 {print $2}' | sort)

fail=0
have=$(lipo -archs "$FW")
if [ "$(echo $have | tr ' ' '\n' | sort)" != "$(echo $ARCHS | tr ' ' '\n' | sort)" ]; then
	echo "architectures: have '$have', want '$ARCHS'"; fail=1
fi
for arch in $have; do
	ours=$(nm -gU -arch "$arch" "$FW" | awk '{print $3}' | sort)
	if [ "$ours" != "$want" ]; then
		echo "export list mismatch ($arch):"; diff <(echo "$want") <(echo "$ours") || true
		fail=1
	fi
done
missing=$(comm -23 <(echo "$want") <(echo "$apple"))
if [ -n "$missing" ]; then
	echo "not exported by Apple: $missing"; fail=1
fi
[ $fail = 0 ] && echo "exports: $(echo "$want" | wc -l | tr -d ' ') symbols match in $have"
exit $fail
