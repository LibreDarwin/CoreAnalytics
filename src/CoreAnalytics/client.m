/*
 * The analyticsd client: one per process, mirroring Apple's
 * CoreAnalytics::Client.
 *
 *   - An XPC connection to the "com.apple.analyticsd" mach service, owned
 *     by a serial "Client" queue that serialises all state changes.
 *   - Event sends are queued on "XPC Send" as QoS-enforced blocks
 *     (UTILITY for high priority, BACKGROUND otherwise), limited to 1000
 *     in flight, and retried on the "XPC Retry" queue when the daemon
 *     drops the connection: up to 5 attempts, 100 ms doubling backoff.
 *   - analyticsd pushes a shared-memory "framework configuration" that
 *     lists the events any transform uses; unused events are dropped
 *     before their payload is built.  Until one arrives every event is
 *     considered used.
 *   - At exit (atexit and SIGTERM) an XPC barrier gives queued messages
 *     up to 300 ms to leave before the connection is cancelled.
 *
 * Copyright (C) 2026, LibreDarwin
 * SPDX-License-Identifier: BSD-3-Clause
 */

#import "ca_internal.h"

#include <dispatch/dispatch.h>
#include <notify.h>
#include <os/lock.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

/* libsystem SPI used by Apple's build (no SDK headers). */
OS_OBJECT_DECL(os_transaction);
extern os_transaction_t os_transaction_create(const char *description)
    OS_OBJECT_RETURNS_RETAINED;
extern bool _dispatch_is_fork_of_multithreaded_parent(void);
extern void abort_with_reason(uint32_t reason_namespace, uint64_t reason_code,
    const char *reason_string, uint64_t reason_flags) __attribute__((noreturn));

#define CA_SUBSYSTEM		"com.apple.CoreAnalytics"
#define CA_EVENT_SUBSYSTEM	"com.apple.CoreAnalytics.event"
#define CA_SHARED_SUBSYSTEM	"com.apple.CoreAnalytics.Shared.critical"
#define CA_SERVICE		"com.apple.analyticsd"
#define CA_RUNNING_NOTIFICATION	"com.apple.analyticsd.running"

#define CA_MAX_IN_FLIGHT	1000
#define CA_MAX_ATTEMPTS		5
#define CA_FIRST_RETRY_MS	100
#define CA_EXIT_TIMEOUT_MS	300

#define CA_CONFIG_MAGIC		0xF09116A8u
#define CA_CONFIG_VERSION	1

os_log_t ca_log_client, ca_log_send, ca_log_send_diag, ca_log_mgmt;
os_log_t ca_log_config;

/* --- CASPIEnter --------------------------------------------------------- */

void
ca_enter(void)
{
	static dispatch_once_t once;

	if (_dispatch_is_fork_of_multithreaded_parent()) {
		static const char msg[] = "Usage of CoreAnalytics is explicitly "
		    "forbidden on the child side of fork. You must use exec.";
		os_log_error(OS_LOG_DEFAULT, "%{public}s", msg);
		abort_with_reason(24 /* OS_REASON_LIBSYSTEM */, 110, msg, 0);
	}
	dispatch_once(&once, ^{
		ca_log_client = os_log_create(CA_SUBSYSTEM, "client");
		ca_log_send = os_log_create(CA_EVENT_SUBSYSTEM, "send");
		ca_log_send_diag = os_log_create(CA_EVENT_SUBSYSTEM, "send-diagnostics");
		ca_log_mgmt = os_log_create(CA_EVENT_SUBSYSTEM, "mgmt-send");
		ca_log_config = os_log_create(CA_SHARED_SUBSYSTEM, "config");
	});
}

/* --- framework configuration -------------------------------------------- */

/* Shared, immutable snapshot of the daemon's configuration blob.
 * Layout: u32 magic, u32 version, u32 event count at +0x08, u32 end offset
 * of the framework section at +0x14, then `count` u32 offsets (from the
 * start of the blob) of NUL-terminated event names in ascending order. */
struct ca_config {
	_Atomic int refs;
	void *base;
	size_t size;
};

static struct ca_config *g_config;
static os_unfair_lock g_config_lock = OS_UNFAIR_LOCK_INIT;

static void
config_release(struct ca_config *c)
{
	if (c == NULL || atomic_fetch_sub(&c->refs, 1) != 1)
		return;
	if (c->base != NULL)
		munmap(c->base, c->size);
	free(c);
}

static struct ca_config *
config_load(void)
{
	os_unfair_lock_lock(&g_config_lock);
	struct ca_config *c = g_config;
	if (c != NULL)
		atomic_fetch_add(&c->refs, 1);
	os_unfair_lock_unlock(&g_config_lock);
	return c;
}

/* Returns the previous snapshot (caller releases). */
static struct ca_config *
config_exchange(struct ca_config *c)
{
	os_unfair_lock_lock(&g_config_lock);
	struct ca_config *old = g_config;
	g_config = c;
	os_unfair_lock_unlock(&g_config_lock);
	return old;
}

static struct ca_config *
config_create(xpc_object_t shmem, size_t size)
{
	if (xpc_get_type(shmem) != XPC_TYPE_SHMEM) {
		os_log_error(ca_log_config, "[FrameworkConfiguration] #Error: "
		    "Received configuration update from daemon but was wrong type.");
		return NULL;
	}

	void *base = NULL;
	size_t mapped = xpc_shmem_map(shmem, &base);
	if (base == NULL || mapped == 0) {
		os_log_error(ca_log_config, "[FrameworkConfiguration] Received "
		    "configuration update from daemon but was not usable (not deserializable)");
		return NULL;
	}

	const uint32_t *h = base;
	bool usable = false;
	if (h[0] != CA_CONFIG_MAGIC)
		os_log_fault(ca_log_config, "[FrameworkConfiguration] Received "
		    "configuration update from daemon but was not usable (invalid magic number) %u", h[0]);
	else if (h[1] != CA_CONFIG_VERSION)
		os_log_fault(ca_log_config, "[FrameworkConfiguration] Received "
		    "configuration update from daemon but was not usable (invalid version) %u", h[1]);
	else if (size < h[5])
		os_log_fault(ca_log_config, "[FrameworkConfiguration] Received "
		    "configuration update from daemon but was not usable (fw end offset [%u] > mmap size [%zu])",
		    h[5], size);
	else
		usable = true;
	if (!usable) {
		munmap(base, size);
		return NULL;
	}

	struct ca_config *c = calloc(1, sizeof *c);
	atomic_init(&c->refs, 1);
	c->base = base;
	c->size = size;
	return c;
}

static bool
config_has_event(const struct ca_config *c, const char *name, size_t len)
{
	const char *base = c->base;
	const uint32_t *h = c->base;
	uint32_t lo = 1, hi = h[2];

	while (lo <= hi) {
		uint32_t mid = (lo + hi) / 2;
		const char *s = base + h[6 + mid - 1];
		size_t slen = strlen(s);
		int r = memcmp(name, s, len < slen ? len : slen);

		if (r == 0 && len == slen)
			return true;
		if (r < 0 || (r == 0 && len < slen))
			hi = mid - 1;
		else
			lo = mid + 1;
	}
	return false;
}

/* FrameworkConfiguration::getExternalConfiguration: after the framework
 * section (from end offset + 1 up to the u32 offset at +0x0c) the blob
 * holds a JSON array of {"kind": ..., "configuration": ...} entries. */
id
ca_config_external(const struct ca_config *c, const char *kind)
{
	const char *base = c->base;
	const uint32_t *h = c->base;

	/* ponytail: Apple parses with exceptions on; a malformed section is
	 * treated as "no configuration" here rather than throwing. */
	if (h[3] <= h[5] + 1 || h[3] > c->size)
		return nil;
	id all = ca_ns_from_json(base + h[5] + 1, h[3] - (h[5] + 1));
	if (![all isKindOfClass:[NSArray class]]) {
		os_log_debug(ca_log_config, "[FrameworkConfiguration] external configuration is not an array");
		return nil;
	}
	NSString *want = @(kind);
	for (id entry in (NSArray *)all) {
		if (![entry isKindOfClass:[NSDictionary class]])
			continue;
		id k = entry[@"kind"];
		if ([k isKindOfClass:[NSString class]] && [k isEqualToString:want] &&
		    entry[@"configuration"] != nil)
			return entry[@"configuration"];
	}
	return nil;
}

/* --- client state ------------------------------------------------------- */

static struct {
	dispatch_queue_t queue;		/* "Client": owns everything below */
	dispatch_queue_t send_queue;
	dispatch_queue_t reply_queue;
	dispatch_queue_t retry_queue;
	dispatch_semaphore_t in_flight;
	bool exiting;
	xpc_object_t conn;		/* xpc_connection_t or XPC null */
	int notify_token;
	bool daemon_running;
	bool checked_in;
	bool allow_all;
	os_transaction_t send_txn;
	int active_sends;
	/* Weak; dead entries are skipped, never removed (as in Apple's). */
	NSPointerArray *config_observers;
	NSPointerArray *event_observers;
	void (^error_handler)(const char *);
} C;

static bool
conn_ok(xpc_object_t conn)
{
	return xpc_get_type(conn) == XPC_TYPE_CONNECTION;
}

static char *
describe(xpc_object_t o)
{
	ca_buf b = {0};
	char *err = NULL;
	if (o != nil && ca_json_from_xpc(o, &b, &err))
		return b.ptr;
	free(err);
	ca_buf_free(&b);
	return strdup("null");
}

static void
acquire_send_transaction(void)
{
	dispatch_sync(C.queue, ^{
		if (C.active_sends == 0)
			C.send_txn = os_transaction_create("com.apple.CoreAnalytics.messages-in-flight");
		C.active_sends++;
	});
}

static void
release_send_transaction(void)
{
	dispatch_sync(C.queue, ^{
		if (--C.active_sends <= 0) {
			C.send_txn = nil;
			C.active_sends = 0;
		}
	});
}

static dispatch_block_t
qos_block(uint8_t priority, dispatch_block_t body)
{
	return dispatch_block_create_with_qos_class(DISPATCH_BLOCK_ENFORCE_QOS_CLASS,
	    priority == CA_PRIORITY_HIGH ? QOS_CLASS_UTILITY : QOS_CLASS_BACKGROUND, 0, body);
}

/* --- sending ------------------------------------------------------------ */

static void
retry_helper(xpc_object_t msg, uint8_t priority, bool retry, uint8_t attempt,
    uint64_t delay_ms)
{
	if (attempt >= CA_MAX_ATTEMPTS) {
		if (os_log_type_enabled(ca_log_client, OS_LOG_TYPE_ERROR)) {
			char *d = describe(msg);
			os_log_error(ca_log_client, "Used all retries. Discarding message: %s.", d);
			free(d);
		}
		release_send_transaction();
		dispatch_semaphore_signal(C.in_flight);
		return;
	}

	xpc_connection_send_message_with_reply(C.conn, msg, C.reply_queue, ^(xpc_object_t reply) {
		if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
			if (reply == XPC_ERROR_CONNECTION_INTERRUPTED) {
				os_log_error(ca_log_client, "XPC message reply connection "
				    "interrupted (daemon probably exited)");
			} else if (reply == XPC_ERROR_CONNECTION_INVALID) {
				os_log(ca_log_client, "XPC message reply connection invalidated "
				    "(client likely exiting): %{public}s",
				    xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION));
			}
		}
		if (reply == XPC_ERROR_CONNECTION_INTERRUPTED && retry) {
			if (os_log_type_enabled(ca_log_client, OS_LOG_TYPE_DEFAULT)) {
				char *d = describe(msg);
				os_log(ca_log_client, "Queueing retry %d with delay (ms) %llu for message: %s",
				    attempt + 1, delay_ms, d);
				free(d);
			}
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay_ms * NSEC_PER_MSEC)),
			    C.retry_queue, qos_block(priority, ^{
				if (os_log_type_enabled(ca_log_client, OS_LOG_TYPE_DEFAULT)) {
					char *d = describe(msg);
					os_log(ca_log_client, "Retrying message: %s", d);
					free(d);
				}
				retry_helper(msg, priority, retry, attempt + 1, delay_ms * 2);
			}));
			return;
		}
		release_send_transaction();
		dispatch_semaphore_signal(C.in_flight);
	});
}

static void
log_event(os_log_t log, xpc_object_t msg)
{
	if (!os_log_type_enabled(log, OS_LOG_TYPE_DEBUG))
		return;
	os_log_debug(log, "%s %s",
	    xpc_dictionary_get_string(msg, "event"),
	    xpc_dictionary_get_string(msg, "json"));
}

/* Client::sendXpcMessage_sync; runs on C.queue. */
static bool
send_xpc_message_sync(xpc_object_t msg, uint8_t priority, bool log_payload, bool retry)
{
	if (!conn_ok(C.conn))
		return false;
	dispatch_block_t b = qos_block(priority, ^{
		if (xpc_dictionary_get_value(msg, "event") != nil &&
		    xpc_dictionary_get_value(msg, "json") != nil) {
			log_event(ca_log_send, msg);
			if (log_payload)
				log_event(ca_log_send_diag, msg);
		}
		dispatch_semaphore_wait(C.in_flight, DISPATCH_TIME_FOREVER);
		acquire_send_transaction();
		retry_helper(msg, priority, retry, 0, CA_FIRST_RETRY_MS);
	});
	dispatch_async(C.send_queue, b);
	return true;
}

static bool
send_xpc_message(xpc_object_t msg, uint8_t priority, bool log_payload, bool retry)
{
	__block bool ok;
	dispatch_sync(C.queue, ^{
		ok = send_xpc_message_sync(msg, priority, log_payload, retry);
	});
	return ok;
}

static void
send_checkin_sync(void)
{
	if (!conn_ok(C.conn) || C.checked_in)
		return;
	C.checked_in = true;
	os_log_debug(ca_log_client, "Checkin. Running=%d", C.daemon_running);

	xpc_object_t msg = xpc_dictionary_create_empty();
	xpc_dictionary_set_string(msg, "command", "checkin");
	xpc_dictionary_set_string(msg, "process", getprogname());
	xpc_dictionary_set_int64(msg, "priority", CA_PRIORITY_DEFAULT);
	send_xpc_message_sync(msg, CA_PRIORITY_DEFAULT, false, true);
}

static void
update_daemon_state(void)
{
	uint64_t state = 0;
	notify_get_state(C.notify_token, &state);
	bool was = C.daemon_running;
	C.daemon_running = state != 0;
	if (was == C.daemon_running)
		os_log_debug(ca_log_client, "Daemon status did not change; still %d", C.daemon_running);
	else
		os_log_info(ca_log_client, "Daemon status changed from %d to %d", was, C.daemon_running);
	if (!C.daemon_running)
		C.checked_in = false;
}

/* --- server messages ---------------------------------------------------- */

static void
handle_configuration_change_sync(xpc_object_t msg)
{
	xpc_object_t cfg = xpc_dictionary_get_value(msg, "configuration");
	if (cfg == nil || xpc_get_type(cfg) == XPC_TYPE_NULL) {
		os_log_error(ca_log_client, "#Error: Received configuration update from daemon but no config.");
		return;
	}
	/* applesauce's dyn_cast_or_default<unsigned long>: either integer type. */
	xpc_object_t sz = xpc_dictionary_get_value(msg, "configuration-size");
	size_t size = 0;
	if (sz != nil && xpc_get_type(sz) == XPC_TYPE_UINT64)
		size = xpc_uint64_get_value(sz);
	else if (sz != nil && xpc_get_type(sz) == XPC_TYPE_INT64)
		size = (size_t)xpc_int64_get_value(sz);
	if (size == 0) {
		os_log_error(ca_log_client, "#Error: Received configuration update from daemon "
		    "but no config size specified.");
		return;
	}

	struct ca_config *c = config_create(cfg, size);
	struct ca_config *old = config_exchange(c);
	if (c == NULL)
		os_log_error(ca_log_client, "#Error: Received configuration update from daemon but was not usable.");
	else if (old == NULL)
		os_log(ca_log_client, "Received configuration update from daemon (initial)");
	else
		os_log(ca_log_client, "Received configuration update from daemon (change)");
	if (c != NULL)
		for (id<CAConfigurationObserverImpl> o in C.config_observers)
			if (o != nil)
				[o notifyConfigurationActivated:c];
	config_release(old);
}

static void
handle_sink_message_emit_sync(xpc_object_t msg)
{
	const char *text = xpc_dictionary_get_string(msg, "message");
	if (text == NULL) {
		os_log_error(ca_log_client, "#Error: Received message emit from daemon but no message.");
		return;
	}
	id message = ca_ns_from_json(text, strlen(text));
	if (![message isKindOfClass:[NSDictionary class]]) {
		os_log_error(ca_log_client, "#Error: Received message emit from daemon but was not parsable.");
		return;
	}
	for (id<CAEventObserverImpl> o in C.event_observers)
		if (o != nil)
			[o notifyMessageEmitted:message];
}

static void
handle_server_message_sync(xpc_object_t msg)
{
	const char *n = xpc_dictionary_get_string(msg, "notification");

	if (n != NULL && strcmp(n, "configuration-change") == 0)
		handle_configuration_change_sync(msg);
	else if (n != NULL && strcmp(n, "message-emit") == 0)
		handle_sink_message_emit_sync(msg);
	else if (os_log_type_enabled(ca_log_client, OS_LOG_TYPE_ERROR)) {
		char *d = describe(msg);
		os_log_error(ca_log_client, "#Error: Received unknown event from daemon: %s", d);
		free(d);
	}
}

static void
handle_connection_event_sync(xpc_object_t ev)
{
	if (ev == XPC_ERROR_CONNECTION_INVALID) {
		os_log(ca_log_client, "XPC connection invalidated (daemon unloaded/disabled)");
		C.daemon_running = C.checked_in = false;
		if (C.error_handler != nil)
			C.error_handler(xpc_dictionary_get_string(ev, XPC_ERROR_KEY_DESCRIPTION));
	} else if (ev == XPC_ERROR_CONNECTION_INTERRUPTED) {
		os_log(ca_log_client, "XPC connection interrupted (daemon probably exited)");
		C.daemon_running = C.checked_in = false;
		if (C.error_handler != nil)
			C.error_handler(xpc_dictionary_get_string(ev, XPC_ERROR_KEY_DESCRIPTION));
	} else if (xpc_get_type(ev) == XPC_TYPE_DICTIONARY) {
		handle_server_message_sync(ev);
	}
}

static void
init_connection_sync(void)
{
	xpc_connection_t conn = xpc_connection_create_mach_service(CA_SERVICE, C.reply_queue,
	    XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
	C.conn = (conn != nil && conn_ok(conn)) ? conn : xpc_null_create();
	if (!conn_ok(C.conn))
		return;
	xpc_connection_set_event_handler(C.conn, ^(xpc_object_t ev) {
		dispatch_async(C.queue, ^{
			handle_connection_event_sync(ev);
		});
	});
	xpc_connection_activate(C.conn);
}

/* --- exit --------------------------------------------------------------- */

static void
cancel_connection_sync(void)
{
	if (!conn_ok(C.conn) || C.exiting)
		return;
	os_log(ca_log_client, "Cancelling XPC connection. Any further reply handler "
	    "invocations will not retry messages");
	C.exiting = true;
	xpc_connection_cancel(C.conn);
}

static void
send_exit_barrier_with_timeout_sync(unsigned ms)
{
	dispatch_group_t g = dispatch_group_create();
	dispatch_group_enter(g);
	dispatch_sync(C.queue, ^{
		if (!conn_ok(C.conn)) {
			dispatch_group_leave(g);
			return;
		}
		os_log(ca_log_client, "Queueing exit procedure onto XPC queue. Any further "
		    "messages sent will be discarded. activeSendTransactions=%d", C.active_sends);
		xpc_object_t conn = C.conn;
		dispatch_async(C.send_queue, ^{
			os_log_debug(ca_log_client, "Sending exit barrier");
			xpc_connection_send_barrier(conn, ^{
				os_log_debug(ca_log_client, "Running exit barrier block");
				dispatch_group_leave(g);
			});
		});
	});
	dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, (int64_t)ms * NSEC_PER_MSEC));
	dispatch_sync(C.queue, ^{
		cancel_connection_sync();
	});
}

static void
at_exit_handler(void)
{
	if (_dispatch_is_fork_of_multithreaded_parent())
		return;
	os_transaction_t t = os_transaction_create("com.apple.CoreAnalytics.exit-transaction");
	os_log(ca_log_client, "Entering exit handler.");
	send_exit_barrier_with_timeout_sync(CA_EXIT_TIMEOUT_MS);
	os_log(ca_log_client, "Exiting exit handler.");
	(void)t;
}

/* --- lifetime ----------------------------------------------------------- */

static void
client_init_sync(void)
{
	static dispatch_queue_t exit_queue;
	static dispatch_source_t sigterm;

	atexit(at_exit_handler);
	exit_queue = dispatch_queue_create("com.apple.CoreAnalytics::Client Exit Queue",
	    dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INITIATED, 0));
	sigterm = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, exit_queue);
	dispatch_source_set_event_handler(sigterm, ^{
		at_exit_handler();
	});
	dispatch_activate(sigterm);

	init_connection_sync();
	notify_register_dispatch(CA_RUNNING_NOTIFICATION, &C.notify_token, C.queue, ^(int token) {
		(void)token;
		update_daemon_state();
		if (C.daemon_running)
			send_checkin_sync();
	});
	update_daemon_state();
}

static void
client_get(void)
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		C.queue = dispatch_queue_create("com.apple.CoreAnalytics::Client",
		    dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
		C.send_queue = dispatch_queue_create("com.apple.CoreAnalytics::Client XPC Send", DISPATCH_QUEUE_SERIAL);
		C.reply_queue = dispatch_queue_create("com.apple.CoreAnalytics::Client XPC Reply", DISPATCH_QUEUE_SERIAL);
		C.retry_queue = dispatch_queue_create("com.apple.CoreAnalytics::Client XPC Retry", DISPATCH_QUEUE_SERIAL);
		C.in_flight = dispatch_semaphore_create(CA_MAX_IN_FLIGHT);
		C.conn = xpc_null_create();
		C.config_observers = [NSPointerArray weakObjectsPointerArray];
		C.event_observers = [NSPointerArray weakObjectsPointerArray];
		dispatch_sync(C.queue, ^{
			client_init_sync();
		});
	});
}

/* --- entry points used by api.m ----------------------------------------- */

bool
ca_client_is_event_used(const char *name, size_t len)
{
	client_get();
	struct ca_config *c = config_load();
	bool used = c == NULL || C.allow_all || config_has_event(c, name, len);
	config_release(c);
	return used;
}

bool
ca_client_send_event(const char *name, bool (^render)(ca_buf *out),
    uint8_t priority, uint8_t format, bool log_payload)
{
	client_get();
	if (!conn_ok(C.conn))
		return false;

	ca_buf b = {0};
	if (!render(&b) || b.ptr == NULL || b.ptr[0] != '{') {
		ca_buf_free(&b);
		return false;
	}
	const char *json = b.ptr;

	xpc_object_t msg = xpc_dictionary_create_empty();
	xpc_dictionary_set_string(msg, "command", "send");
	xpc_dictionary_set_int64(msg, "priority", priority);
	xpc_dictionary_set_string(msg, "event", name);
	/* std::chrono::system_clock::now(): microseconds since the epoch. */
	struct timespec ts;
	clock_gettime(CLOCK_REALTIME, &ts);
	xpc_dictionary_set_int64(msg, "timestamp", (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000);
	xpc_dictionary_set_string(msg, "json", json);
	xpc_dictionary_set_int64(msg, "format", format);
	ca_buf_free(&b);
	return send_xpc_message(msg, priority, log_payload, true);
}

xpc_object_t
ca_client_mgmt(const char *command, xpc_object_t args)
{
	client_get();
	xpc_object_t msg = (args != nil && xpc_get_type(args) == XPC_TYPE_DICTIONARY) ?
	    args : xpc_dictionary_create_empty();

	if (os_log_type_enabled(ca_log_mgmt, OS_LOG_TYPE_DEBUG)) {
		char *d = describe(msg);
		os_log_debug(ca_log_mgmt, "%s %s", command, d);
		free(d);
	}
	xpc_dictionary_set_string(msg, "command", command);
	xpc_dictionary_set_int64(msg, "priority", CA_PRIORITY_HIGH);

	__block xpc_object_t conn;
	dispatch_sync(C.queue, ^{
		conn = C.conn;
	});
	if (!conn_ok(conn))
		return xpc_null_create();
	xpc_object_t reply = xpc_connection_send_message_with_reply_sync(conn, msg);
	if (reply == nil || xpc_get_type(reply) != XPC_TYPE_DICTIONARY)
		return xpc_null_create();
	return reply;
}

void
ca_client_register_event_observer(id<CAEventObserverImpl> impl)
{
	client_get();
	dispatch_sync(C.queue, ^{
		[C.event_observers addPointer:(__bridge void *)impl];
		send_checkin_sync();
	});
}

void
ca_client_register_configuration_observer(id<CAConfigurationObserverImpl> impl)
{
	client_get();
	dispatch_sync(C.queue, ^{
		[C.config_observers addPointer:(__bridge void *)impl];
		struct ca_config *c = config_load();
		if (c != NULL)
			[impl notifyConfigurationActivated:c];
		config_release(c);
		send_checkin_sync();
	});
}

void
ca_client_register_error_handler(void (^handler)(const char *))
{
	client_get();
	dispatch_sync(C.queue, ^{
		C.error_handler = handler;
	});
}
