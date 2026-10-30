/*
 * Internal interfaces shared by the CoreAnalytics sources.
 *
 * Copyright (C) 2026, LibreDarwin
 * SPDX-License-Identifier: BSD-3-Clause
 */

#ifndef CA_INTERNAL_H
#define CA_INTERNAL_H

#import <Foundation/Foundation.h>
#include <os/log.h>
#include <stdbool.h>
#include <stdint.h>
#include <sys/cdefs.h>
#include <xpc/xpc.h>

__BEGIN_DECLS

/* XPCMessagePriority: 1 sends on a UTILITY block, everything else BACKGROUND. */
enum { CA_PRIORITY_DEFAULT = 0, CA_PRIORITY_HIGH = 1 };
/* EventPayloadFormat, forwarded to analyticsd as "format". */
enum { CA_FORMAT_DEFAULT = 0, CA_FORMAT_EXPLODING = 1 };

/* Log handles, created once by ca_enter(). */
extern os_log_t ca_log_client, ca_log_send, ca_log_send_diag, ca_log_mgmt;
extern os_log_t ca_log_config;

/* CASPIEnter(): aborts on the child side of a fork, sets up logging. */
void ca_enter(void);

/* --- JSON (json.m) ------------------------------------------------------ */

/* Growable byte buffer; `ptr` is NUL-terminated once ca_json_* succeeds. */
typedef struct {
	char *ptr;
	size_t len, cap;
} ca_buf;

/* Compact JSON text for an Objective-C property-list-ish object.  Raises
 * NSInvalidArgumentException exactly where Apple's converter does. */
bool ca_json_from_ns(id obj, ca_buf *out);

/* Compact JSON text for an XPC object.  On failure returns false and puts
 * a malloc'd reason in *err. */
bool ca_json_from_xpc(xpc_object_t obj, ca_buf *out, char **err);

/* XPC object for an Objective-C object (raises like ca_json_from_ns). */
xpc_object_t ca_xpc_from_ns(id obj);

/* nlohmann dump(indent) of a value produced by ca_ns_from_json(). */
bool ca_json_pretty_from_ns(id obj, int indent, ca_buf *out);

/* Parse JSON text into Foundation objects (nil when malformed). */
id ca_ns_from_json(const char *text, size_t len);

void ca_buf_free(ca_buf *b);

/* --- Client (client.m) -------------------------------------------------- */

bool ca_client_is_event_used(const char *name, size_t len);
void ca_client_allow_all_events(void);

/* True once a framework configuration has been received. */
bool ca_client_has_config(void);

/* Send one event.  `render` writes the payload JSON and is only called
 * once the connection is up; a failed render or a payload that is not a
 * JSON object drops the event (returns false). */
bool ca_client_send_event(const char *name, bool (^render)(ca_buf *out),
    uint8_t priority, uint8_t format, bool log_payload);

/* Synchronous management command.  Sets "command" and "priority" in
 * `args` (or a fresh dictionary when args is not one) and returns the
 * reply dictionary, or XPC null when there is none. */
xpc_object_t ca_client_mgmt(const char *command, xpc_object_t args);

/* A reply field read as applesauce's dyn_cast_or_default<bool>(v, false):
 * a bool, or an integer of either sign (non-zero is true). */
bool ca_xpc_bool(xpc_object_t v);

/* The rest of Apple's CoreAnalytics::Client, one function per method, for
 * the C++ exports.  ca_client_get() creates the client once (Client::get);
 * the *_sync functions expect to run on the client queue, as Apple's do. */
void ca_client_get(void);
void ca_client_init_sync(void);
void ca_init_connection_sync(void);
void ca_update_daemon_state(void);
bool ca_send_xpc_message(xpc_object_t msg, uint8_t priority, bool log_payload, bool retry);
bool ca_send_xpc_message_sync(xpc_object_t msg, uint8_t priority, bool log_payload, bool retry);
void ca_retry_helper(xpc_object_t msg, uint8_t priority, bool retry, uint8_t attempt,
    uint64_t delay_ms);
void ca_acquire_send_transaction(void);
void ca_release_send_transaction(void);
void ca_send_checkin_sync(void);
void ca_handle_server_message_sync(xpc_object_t msg);
void ca_handle_sink_message_emit_sync(xpc_object_t msg);
void ca_handle_configuration_change_sync(xpc_object_t msg);
void ca_cancel_connection_sync(void);
void ca_send_exit_barrier_with_timeout_sync(unsigned ms);

/* --- observers (client.m <-> observers.mm) ------------------------------ */

struct ca_config;

__END_DECLS	/* Objective-C declarations cannot sit in extern "C" */

/* The client keeps zeroing-weak references to these, the counterpart of
 * Apple's std::weak_ptr<CoreAnalytics::{Event,Configuration}Observer>
 * lists; the Objective-C observer classes own them. */
@protocol CAEventObserverImpl <NSObject>
/* `message` is the parsed "message-emit" payload (a dictionary). */
- (void)notifyMessageEmitted:(id)message;
@end

@protocol CAConfigurationObserverImpl <NSObject>
- (void)notifyConfigurationActivated:(const struct ca_config *)config;
@end

__BEGIN_DECLS

/* Append to the list on the client queue, then check in with analyticsd.
 * A configuration observer is notified at once when a configuration is
 * already loaded. */
void ca_client_register_event_observer(id<CAEventObserverImpl> impl);
void ca_client_register_configuration_observer(id<CAConfigurationObserverImpl> impl);

/* Replace the connection error handler (nil clears it).  Called on the
 * client queue with the XPC error description. */
void ca_client_register_error_handler(void (^handler)(const char *description));

/* The "configuration" of the entry whose "kind" equals `kind` in the
 * configuration's external-configuration array, as Foundation objects;
 * nil when absent. */
id ca_config_external(const struct ca_config *config, const char *kind);

__END_DECLS

#endif /* CA_INTERNAL_H */
