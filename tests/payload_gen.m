/*
 * Event generator for tests/payload-parity.sh: sends a fixed, seeded
 * sequence of payloads through both the XPC and the Foundation entry
 * points.  Run once against Apple's framework and once against ours with
 * tests/capture_send.c inserted; the captured JSON must be identical.
 *
 *   payload_gen <count>
 *
 * Copyright (C) 2026, LibreDarwin
 * SPDX-License-Identifier: BSD-3-Clause
 */

#import <CoreAnalytics/CoreAnalytics.h>

#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <uuid/uuid.h>

static double
random_double(void)
{
	for (;;) {
		uint64_t bits = ((uint64_t)random() << 33) ^ ((uint64_t)random() << 11) ^
		    (uint64_t)random();
		double v;
		memcpy(&v, &bits, sizeof v);
		if (isfinite(v))
			return v;
	}
}

int
main(int argc, char **argv)
{
	@autoreleasepool {
		long n = argc > 1 ? atol(argv[1]) : 1000;
		/* Edge cases, including values where Grisu2 is not shortest. */
		static const double fixed[] = {
			1.0, 0.1, 0.3, 2.5, 123.456, 1e14, 1e15, 1e16, 1e21, 1e-5,
			5e-324, 2.2250738585072014e-308, 1.7976931348623157e308, -0.0, 0.0,
			9007199254740993.0, 123456789012345680.0, 7.7132213375453208e+140,
			4.2403506834040578e-165, 33833667468557792.0,
			-2.6515429685090411e+241, -3.5077677739450782e-295,
		};
		const long nfixed = sizeof fixed / sizeof fixed[0];
		uuid_t uu;
		uuid_parse("0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9", uu);

		srandom(7);
		for (long i = 0; i < nfixed + n; i++) {
			double v = i < nfixed ? fixed[i] : random_double();
			long long ll = (long long)(((uint64_t)random() << 32) ^ (uint64_t)random());

			xpc_object_t d = xpc_dictionary_create_empty();
			xpc_dictionary_set_double(d, "v", v);
			xpc_dictionary_set_int64(d, "i", ll);
			xpc_dictionary_set_uint64(d, "u", (uint64_t)ll);
			xpc_dictionary_set_bool(d, "b", i & 1);
			xpc_dictionary_set_string(d, "s", "q\"\\/\b\f\n\r\t\x01\x7f\xc3\xa9");
			xpc_dictionary_set_data(d, "d", &ll, sizeof ll);
			xpc_dictionary_set_uuid(d, "id", uu);
			xpc_object_t a = xpc_array_create_empty();
			xpc_array_set_double(a, XPC_ARRAY_APPEND, v / 3);
			xpc_array_append_value(a, xpc_dictionary_create_empty());
			xpc_dictionary_set_value(d, "a", a);
			analytics_send_event("org.libredarwin.parity.xpc", d);

			AnalyticsSendEvent(@"org.libredarwin.parity.ns", @{
				@"v": @(v), @"f": @((float)v), @"i": @(ll),
				@"u": @((unsigned long long)ll), @"b": @(i & 1 ? YES : NO),
				@"s": @"q\"\\/\b\f\n\r\t\x01\x7fé", @"n": [NSNull null],
				@"d": [NSData dataWithBytes:&ll length:sizeof ll],
				@"a": @[ @(v / 3), @{}, @[] ],
			});
			if (i % 400 == 399)
				[NSThread sleepForTimeInterval:0.02];
		}
		[NSThread sleepForTimeInterval:1.0];
	}
	return 0;
}
