/*
 * DYLD_INSERT_LIBRARIES helper for tests/cxx-parity.sh: stands in for
 * analyticsd so nothing reaches the real daemon.
 *
 * Management commands (synchronous) are logged to stderr as "REQ" lines
 * and answered according to FAKE_REPLY:
 *   nondict	XPC null
 *   empty	{}
 *   error	{"error": false}
 *   text	{"count": 2, "u": 7u}
 *   key	{FAKE_KEY: <FAKE_TYPE value>, "other": 3}; FAKE_KEY "@" means
 *		the command's own name
 * Other messages (sends, apart from checkin) are logged as "SENT" lines
 * and answered locally.
 *
 * Copyright (C) 2026, LibreDarwin
 * SPDX-License-Identifier: BSD-3-Clause
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <xpc/xpc.h>

static int
cmp_str(const void *a, const void *b)
{
	return strcmp(*(char *const *)a, *(char *const *)b);
}

/* One line, fields sorted by name; the timestamp's value varies. */
static void
log_fields(const char *tag, xpc_object_t m)
{
	char *fields[64], **f = fields;
	__block size_t n = 0;
	xpc_dictionary_apply(m, ^bool(const char *k, xpc_object_t v) {
		xpc_type_t t = xpc_get_type(v);
		if (n == 64)
			return false;
		if (!strcmp(k, "timestamp"))
			asprintf(&f[n++], "%s", k);
		else if (t == XPC_TYPE_STRING)
			asprintf(&f[n++], "%s=s:%s", k, xpc_string_get_string_ptr(v));
		else if (t == XPC_TYPE_BOOL)
			asprintf(&f[n++], "%s=b:%d", k, xpc_bool_get_value(v));
		else if (t == XPC_TYPE_INT64)
			asprintf(&f[n++], "%s=i:%lld", k, xpc_int64_get_value(v));
		else if (t == XPC_TYPE_UINT64)
			asprintf(&f[n++], "%s=u:%llu", k, xpc_uint64_get_value(v));
		else
			asprintf(&f[n++], "%s=%s", k, xpc_type_get_name(t));
		return true;
	});
	qsort(f, n, sizeof f[0], cmp_str);
	flockfile(stderr);
	fputs(tag, stderr);
	for (size_t i = 0; i < n; i++) {
		fprintf(stderr, " %s", f[i]);
		free(f[i]);
	}
	fputc('\n', stderr);
	funlockfile(stderr);
}

static xpc_object_t
value_of_type(const char *t)
{
	if (!strcmp(t, "str")) return xpc_string_create("a\"b\\c\nd");
	if (!strcmp(t, "strtrue")) return xpc_string_create("true");
	if (!strcmp(t, "true")) return xpc_bool_create(true);
	if (!strcmp(t, "false")) return xpc_bool_create(false);
	if (!strcmp(t, "zero")) return xpc_int64_create(0);
	if (!strcmp(t, "neg")) return xpc_int64_create(-1);
	if (!strcmp(t, "uint")) return xpc_uint64_create(5);
	if (!strcmp(t, "uzero")) return xpc_uint64_create(0);
	if (!strcmp(t, "double")) return xpc_double_create(0.5);
	if (!strcmp(t, "null")) return xpc_null_create();
	if (!strcmp(t, "date")) return xpc_date_create(1700000000LL * 1000000000LL);
	if (!strcmp(t, "data")) return xpc_data_create("\x01\xab\xff", 3);
	if (!strcmp(t, "uuid")) {
		static const unsigned char u[16] = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
		return xpc_uuid_create(u);
	}
	if (!strcmp(t, "emptyarr")) return xpc_array_create_empty();
	if (!strcmp(t, "arr")) {
		xpc_object_t a = xpc_array_create_empty();
		xpc_array_set_int64(a, XPC_ARRAY_APPEND, 1);
		xpc_array_set_string(a, XPC_ARRAY_APPEND, "x");
		return a;
	}
	if (!strcmp(t, "nested")) {
		xpc_object_t d = xpc_dictionary_create_empty();
		xpc_dictionary_set_int64(d, "k", 1);
		xpc_dictionary_set_value(d, "e", xpc_dictionary_create_empty());
		return d;
	}
	if (!strcmp(t, "error")) return (xpc_object_t)XPC_ERROR_CONNECTION_INVALID;
	if (!strcmp(t, "interrupted")) return (xpc_object_t)XPC_ERROR_CONNECTION_INTERRUPTED;
	if (!strcmp(t, "fd")) return xpc_fd_create(0);
	return xpc_int64_create(1);
}

static xpc_object_t
fake_sync(xpc_connection_t c, xpc_object_t m)
{
	const char *cmd = xpc_dictionary_get_string(m, "command");
	if (cmd == NULL || !strcmp(cmd, "send") || !strcmp(cmd, "checkin"))
		return xpc_connection_send_message_with_reply_sync(c, m);
	log_fields("REQ", m);

	const char *mode = getenv("FAKE_REPLY");
	if (mode == NULL)
		mode = "empty";
	if (!strcmp(mode, "nondict"))
		return xpc_null_create();
	xpc_object_t r = xpc_dictionary_create_empty();
	if (!strcmp(mode, "error"))
		xpc_dictionary_set_bool(r, "error", false);
	else if (!strcmp(mode, "text")) {
		xpc_dictionary_set_int64(r, "count", 2);
		xpc_dictionary_set_uint64(r, "u", 7);
	} else if (!strcmp(mode, "key")) {
		const char *k = getenv("FAKE_KEY");
		xpc_dictionary_set_value(r, strcmp(k, "@") ? k : cmd, value_of_type(getenv("FAKE_TYPE")));
		xpc_dictionary_set_int64(r, "other", 3);
	}
	return r;
}

static void
fake_send(xpc_connection_t c, xpc_object_t m, dispatch_queue_t q, xpc_handler_t h)
{
	const char *cmd = xpc_dictionary_get_string(m, "command");
	if (cmd != NULL && !strcmp(cmd, "checkin")) {
		xpc_connection_send_message_with_reply(c, m, q, h);
		return;
	}
	log_fields("SENT", m);
	dispatch_async(q, ^{ h(xpc_dictionary_create_empty()); });
}

__attribute__((used)) static struct { const void *n, *o; } interposers[]
    __attribute__((section("__DATA,__interpose"))) = {
	{ (const void *)fake_sync, (const void *)xpc_connection_send_message_with_reply_sync },
	{ (const void *)fake_send, (const void *)xpc_connection_send_message_with_reply },
};
