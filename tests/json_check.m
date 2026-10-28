/*
 * Checks the payload JSON writer against the text nlohmann::json's
 * dump(-1, ' ', false, strict) produces for the same values.
 *
 * Copyright (C) 2026, LibreDarwin
 * SPDX-License-Identifier: BSD-3-Clause
 */

#import "ca_internal.h"

#include <stdio.h>
#include <string.h>
#include <uuid/uuid.h>

static int failures;

static void
expect_ns(id obj, const char *want)
{
	ca_buf b = {0};
	NSString *got;
	@try {
		ca_json_from_ns(obj, &b);
		got = @(b.ptr);
	} @catch (NSException *e) {
		got = [@"raise: " stringByAppendingString:[e reason]];
	}
	if (strcmp([got UTF8String], want) != 0) {
		printf("FAIL ns: want %s\n           got  %s\n", want, [got UTF8String]);
		failures++;
	}
	ca_buf_free(&b);
}

static void
expect_xpc(xpc_object_t obj, const char *want)
{
	ca_buf b = {0};
	char *err = NULL;
	const char *got = ca_json_from_xpc(obj, &b, &err) ? b.ptr : err;
	if (strcmp(got, want) != 0) {
		printf("FAIL xpc: want %s\n            got  %s\n", want, got);
		failures++;
	}
	free(err);
	ca_buf_free(&b);
}

int
main(void)
{
	@autoreleasepool {
		/* object keys sorted bytewise, compact separators */
		expect_ns(@{ @"b": @1, @"a": @"x", @"B": @YES, @"ab": [NSNull null] },
		    "{\"B\":true,\"a\":\"x\",\"ab\":null,\"b\":1}");
		expect_ns(@{}, "{}");
		expect_ns(@{ @"k": @[ @1, @[], @{} ] }, "{\"k\":[1,[],{}]}");

		/* string escaping; '/' and DEL pass through, other C0 is \u00xx */
		expect_ns(@{ @"s": @"q\"b\\/\b\f\n\r\t\x01\x7fé\U0001F600" },
		    "{\"s\":\"q\\\"b\\\\/\\b\\f\\n\\r\\t\\u0001\x7f\xc3\xa9\xf0\x9f\x98\x80\"}");

		/* integers */
		expect_ns(@{ @"i": @(-42), @"u": @(UINT64_MAX), @"c": @((char)-3),
			     @"h": @((unsigned short)7), @"l": @(INT64_MIN) },
		    "{\"c\":-3,\"h\":7,\"i\":-42,\"l\":-9223372036854775808,\"u\":18446744073709551615}");

		/* nlohmann's float layout */
		expect_ns(@[ @1.0, @0.1, @123.456, @1e14, @1e15, @123456789012345.6, @1e20,
			     @1e-4, @1.5e-5, @(-0.0), @0.0, @(-2.5e-300), @1.7976931348623157e308 ],
		    "[1.0,0.1,123.456,100000000000000.0,1e+15,123456789012345.6,1e+20,"
		    "0.0001,1.5e-05,-0.0,0.0,-2.5e-300,1.7976931348623157e+308]");
		expect_ns(@[ @0.1f ], "[0.10000000149011612]");

		/* Grisu2 is not always shortest; these are the digits Apple's
		 * framework sends (captured from its outgoing messages), one
		 * longer than the shortest round-trip form. */
		expect_ns(@[ @7.7132213375453208e+140, @4.2403506834040578e-165,
			     @33833667468557792.0, @(-2.6515429685090411e+241),
			     @(-3.5077677739450782e-295), @5e-324 ],
		    "[7.713221337545321e+140,4.2403506834040578e-165,3.3833667468557792e+16,"
		    "-2.6515429685090411e+241,-3.5077677739450782e-295,5e-324]");

		/* data -> lowercase hex string */
		expect_ns(@{ @"d": [NSData dataWithBytes:"\x00\xab\xff" length:3] },
		    "{\"d\":\"00abff\"}");

		/* rejects */
		expect_ns(@[ @(NAN) ], "raise: Invalid number value (NaN) in JSON write");
		expect_ns(@[ @(INFINITY) ], "raise: Invalid number value (infinite) in JSON write");
		expect_ns(@[ @((short)1) ], "raise: Invalid number type in JSON write (s)");
		expect_ns(@{ @1: @1 }, "raise: Invalid (non-string) key in JSON dictionary");
		expect_ns(@[ [NSDate dateWithTimeIntervalSince1970:0] ],
		    "raise: Invalid type in JSON write (__NSTaggedDate)");

		id deep = @1;
		for (int i = 0; i < 10; i++)
			deep = @[ deep ];
		expect_ns(deep, "[[[[[[[[[[1]]]]]]]]]]");
		expect_ns(@[ deep ], "raise: Object exceeded the max depth");

		/* xpc */
		xpc_object_t d = xpc_dictionary_create_empty();
		xpc_dictionary_set_int64(d, "z", -1);
		xpc_dictionary_set_uint64(d, "y", 5);
		xpc_dictionary_set_double(d, "x", 2.0);
		xpc_dictionary_set_double(d, "n", NAN);
		xpc_dictionary_set_bool(d, "w", false);
		xpc_dictionary_set_value(d, "v", xpc_null_create());
		xpc_dictionary_set_data(d, "u", "\x12\x34", 2);
		uuid_t uu;
		uuid_parse("0A1B2C3D-4E5F-6071-8293-A4B5C6D7E8F9", uu);
		xpc_dictionary_set_uuid(d, "t", uu);
		xpc_object_t a = xpc_array_create_empty();
		xpc_array_set_string(a, XPC_ARRAY_APPEND, "s");
		xpc_dictionary_set_value(d, "a", a);
		expect_xpc(d, "{\"a\":[\"s\"],\"n\":null,\"t\":\"0a1b2c3d-4e5f-6071-8293-a4b5c6d7e8f9\","
		    "\"u\":\"1234\",\"v\":null,\"w\":false,\"x\":2.0,\"y\":5,\"z\":-1}");

		xpc_object_t bad = xpc_dictionary_create_empty();
		xpc_dictionary_set_date(bad, "d", 0);
		expect_xpc(bad, "XPC type (date) cannot be converted and is invalid");

		xpc_object_t badutf = xpc_dictionary_create_empty();
		xpc_dictionary_set_string(badutf, "s", "\xc0\xaf");
		expect_xpc(badutf, "[json.exception.type_error.316] invalid UTF-8 byte");
	}
	@autoreleasepool {
		/* parse -> dump(4): the AnalyticsEventObserver message format */
		struct { const char *in, *out; } cases[] = {
			{ "{\"b\":[1,2.50,{}],\"a\":\"x\\u00e9\\ud83d\\ude00\",\"c\":[]}",
			  "{\n    \"a\": \"x\xc3\xa9\xf0\x9f\x98\x80\",\n    \"b\": [\n        1,\n        2.5,\n"
			  "        {}\n    ],\n    \"c\": []\n}" },
			{ " {\"k\":1,\"k\":2} ", "{\n    \"k\": 2\n}" },
			{ "{\"u\":18446744073709551615,\"o\":18446744073709551616,\"n\":-0,\"e\":1E2,"
			  "\"t\":true,\"z\":null,\"s\":\"a\\u0000b\"}",
			  "{\n    \"e\": 100.0,\n    \"n\": 0,\n    \"o\": 1.8446744073709552e+19,\n"
			  "    \"s\": \"a\\u0000b\",\n    \"t\": true,\n    \"u\": 18446744073709551615,\n"
			  "    \"z\": null\n}" },
			{ "{}", "{}" },
		};
		for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
			ca_buf b = {0};
			id v = ca_ns_from_json(cases[i].in, strlen(cases[i].in));
			const char *got = v ? (ca_json_pretty_from_ns(v, 4, &b), b.ptr) : "(parse error)";
			if (strcmp(got, cases[i].out) != 0) {
				printf("FAIL parse %zu:\nwant %s\ngot  %s\n", i, cases[i].out, got);
				failures++;
			}
			ca_buf_free(&b);
		}

		const char *bad[] = { "", "{", "[1,]", "{\"a\" 1}", "01", "1.", "\"\\ud800\"",
		    "\"a\x01\"", "tru", "{} x", "\"\xc0\xaf\"" };
		for (size_t i = 0; i < sizeof bad / sizeof bad[0]; i++)
			if (ca_ns_from_json(bad[i], strlen(bad[i])) != nil) {
				printf("FAIL parse accepted bad input %zu: %s\n", i, bad[i]);
				failures++;
			}
	}
	if (failures == 0)
		printf("json_check: all cases pass\n");
	return failures != 0;
}
