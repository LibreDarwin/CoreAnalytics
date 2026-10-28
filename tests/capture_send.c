/*
 * DYLD_INSERT_LIBRARIES helper for tests/payload-parity.sh: prints the
 * event name and "json" field of every CoreAnalytics "send" message to
 * $CAP_OUT and answers it locally instead of sending it, so nothing
 * reaches analyticsd.  Other messages pass through.
 *
 * Copyright (C) 2026, LibreDarwin
 * SPDX-License-Identifier: BSD-3-Clause
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <xpc/xpc.h>
static FILE *out;

static void my_send(xpc_connection_t c, xpc_object_t m, dispatch_queue_t q, xpc_handler_t h) {
	const char *cmd = xpc_dictionary_get_string(m, "command");
	if (cmd && strcmp(cmd, "send") == 0) {
		if (!out) out = fopen(getenv("CAP_OUT"), "w");
		fprintf(out, "%s\t%s\n", xpc_dictionary_get_string(m, "event"), xpc_dictionary_get_string(m, "json"));
		fflush(out);
		dispatch_async(q, ^{ h(xpc_dictionary_create_empty()); });
		return;
	}
	xpc_connection_send_message_with_reply(c, m, q, h);
}
__attribute__((used)) static struct { const void *n, *o; } interposers[] __attribute__((section("__DATA,__interpose"))) = {
	{ (const void *)my_send, (const void *)xpc_connection_send_message_with_reply },
};
