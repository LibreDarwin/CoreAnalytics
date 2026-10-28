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
#include <xpc/xpc.h>

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

void ca_buf_free(ca_buf *b);

/* --- Client (client.m) -------------------------------------------------- */

bool ca_client_is_event_used(const char *name, size_t len);

/* Send one event.  `render` writes the payload JSON and is only called
 * once the connection is up; a failed render or a payload that is not a
 * JSON object drops the event (returns false). */
bool ca_client_send_event(const char *name, bool (^render)(ca_buf *out),
    uint8_t priority, uint8_t format, bool log_payload);

/* Synchronous management command.  Sets "command" and "priority" in
 * `args` (or a fresh dictionary when args is not one) and returns the
 * reply dictionary, or XPC null when there is none. */
xpc_object_t ca_client_mgmt(const char *command, xpc_object_t args);

#endif /* CA_INTERNAL_H */
