/*
 * Exported C entry points of CoreAnalytics.framework.
 *
 * Copyright (C) 2026, LibreDarwin
 * SPDX-License-Identifier: BSD-3-Clause
 */

#import "ca_internal.h"
#import <CoreAnalytics/CoreAnalytics.h>

#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <objc/message.h>
#include <stdlib.h>
#include <string.h>

NSString *const CASendEventOptionKeyLogPayload = @"kLogPayload";

/* --- event submission --------------------------------------------------- */

/* AnalyticsSendEventInternal */
static bool
send_ns(NSString *name, NSDictionary *(^builder)(void), uint8_t priority,
    uint8_t format, NSDictionary *options)
{
	@autoreleasepool {
		ca_enter();
		if (name == nil) {
			os_log_error(ca_log_client, "Dropping because event name was null");
			return false;
		}
		const char *u = [name UTF8String];
		if (u == NULL) {
			os_log_fault(ca_log_client, "Dropping because event name was non-UTF8");
			return false;
		}
		if (!ca_client_is_event_used(u, strlen(u))) {
			os_log_info(ca_log_client, "Dropping \"%@\" as it isn't used in any "
			    "transform (not in the config or budgeted?)", name);
			return false;
		}
		bool log_payload = false;
		id lp = options[[NSString stringWithUTF8String:"kLogPayload"]];
		if ([lp isKindOfClass:[NSNumber class]])
			log_payload = [lp boolValue];

		return ca_client_send_event(u, ^bool(ca_buf *out) {
			@try {
				NSDictionary *payload = builder ? builder() : nil;
				return ca_json_from_ns(payload ? payload : @{}, out);
			} @catch (NSException *e) {
				os_log_fault(ca_log_client, "Error: event \"%@\" dropped because the payload "
				    "was unable to be converted to json: %{public}@ (%{public}@) %@",
				    name, [e name], [e reason], [e userInfo]);
				return false;
			}
		}, priority, format, log_payload);
	}
}

/* analytics_send_event_internal */
static bool
send_xpc(const char *name, xpc_object_t (^builder)(void) CA_RETURNS_RETAINED, uint8_t priority,
    uint8_t format, xpc_object_t options)
{
	@autoreleasepool {
		ca_enter();
		if (name == NULL) {
			os_log_error(ca_log_client, "Dropping because event name was null");
			return false;
		}
		if (!ca_client_is_event_used(name, strlen(name))) {
			os_log_info(ca_log_client, "Dropping \"%s\" as it isn't used in any "
			    "transform (not in the config or budgeted?)", name);
			return false;
		}
		bool log_payload = false;
		if (options != nil && xpc_get_type(options) == XPC_TYPE_DICTIONARY) {
			xpc_object_t lp = xpc_dictionary_get_value(options, "kLogPayload");
			if (lp != nil && xpc_get_type(lp) == XPC_TYPE_BOOL)
				log_payload = xpc_bool_get_value(lp);
		}

		return ca_client_send_event(name, ^bool(ca_buf *out) {
			xpc_object_t payload = builder ? builder() : nil;
			char *err = NULL;
			if (payload == nil || xpc_get_type(payload) == XPC_TYPE_NULL)
				payload = xpc_dictionary_create_empty();
			else if (xpc_get_type(payload) != XPC_TYPE_DICTIONARY)
				return false;
			if (ca_json_from_xpc(payload, out, &err))
				return true;
			char *d = xpc_copy_description(payload);
			os_log_fault(ca_log_client, "Error: event \"%s\" %s dropped because the payload "
			    "was unable to be converted to json: %{public}s", name, d, err);
			free(d);
			free(err);
			return false;
		}, priority, format, log_payload);
	}
}

void
AnalyticsSendEvent(NSString *eventName, NSDictionary *eventPayload)
{
	send_ns(eventName, ^NSDictionary *{ return eventPayload; },
	    CA_PRIORITY_DEFAULT, CA_FORMAT_DEFAULT, nil);
}

void
AnalyticsSendEventWithOptions(NSString *eventName, NSDictionary *eventPayload,
    NSDictionary *options)
{
	send_ns(eventName, ^NSDictionary *{ return eventPayload; },
	    CA_PRIORITY_DEFAULT, CA_FORMAT_DEFAULT, options);
}

bool
AnalyticsSendEventLazy(NSString *eventName, NSDictionary *(^builder)(void))
{
	return send_ns(eventName, builder, CA_PRIORITY_DEFAULT, CA_FORMAT_DEFAULT, nil);
}

bool
AnalyticsSendEventLazyWithOptions(NSString *eventName, NSDictionary *(^builder)(void),
    NSDictionary *options)
{
	return send_ns(eventName, builder, CA_PRIORITY_DEFAULT, CA_FORMAT_DEFAULT, options);
}

bool
AnalyticsSendEventLazyHighPriority(NSString *eventName, NSDictionary *(^builder)(void))
{
	return send_ns(eventName, builder, CA_PRIORITY_HIGH, CA_FORMAT_DEFAULT, nil);
}

bool
AnalyticsSendExplodingEventLazy(NSString *eventName, NSDictionary *(^builder)(void))
{
	return send_ns(eventName, builder, CA_PRIORITY_DEFAULT, CA_FORMAT_EXPLODING, nil);
}

bool
AnalyticsIsEventUsed(NSString *eventName)
{
	@autoreleasepool {
		ca_enter();
		const char *u = [eventName UTF8String];
		return ca_client_is_event_used(u ? u : "", u ? strlen(u) : 0);
	}
}

void
analytics_send_event(const char *event_name, xpc_object_t payload)
{
	send_xpc(event_name, ^xpc_object_t (void) CA_RETURNS_RETAINED { return payload; },
	    CA_PRIORITY_DEFAULT, CA_FORMAT_DEFAULT, nil);
}

void
analytics_send_event_with_options(const char *event_name, xpc_object_t payload,
    xpc_object_t options)
{
	send_xpc(event_name, ^xpc_object_t (void) CA_RETURNS_RETAINED { return payload; },
	    CA_PRIORITY_DEFAULT, CA_FORMAT_DEFAULT, options);
}

bool
analytics_send_event_lazy(const char *event_name, xpc_object_t (^builder)(void) CA_RETURNS_RETAINED)
{
	return send_xpc(event_name, builder, CA_PRIORITY_DEFAULT, CA_FORMAT_DEFAULT, nil);
}

bool
analytics_send_event_lazy_with_options(const char *event_name,
    xpc_object_t (^builder)(void) CA_RETURNS_RETAINED, xpc_object_t options)
{
	return send_xpc(event_name, builder, CA_PRIORITY_DEFAULT, CA_FORMAT_DEFAULT, options);
}

bool
analytics_send_event_lazy_high_priority(const char *event_name, xpc_object_t (^builder)(void) CA_RETURNS_RETAINED)
{
	return send_xpc(event_name, builder, CA_PRIORITY_HIGH, CA_FORMAT_DEFAULT, nil);
}

bool
analytics_send_exploding_event_lazy(const char *event_name, xpc_object_t (^builder)(void) CA_RETURNS_RETAINED)
{
	return send_xpc(event_name, builder, CA_PRIORITY_DEFAULT, CA_FORMAT_EXPLODING, nil);
}

bool
analytics_is_event_used(const char *event_name)
{
	@autoreleasepool {
		ca_enter();
		return ca_client_is_event_used(event_name, strlen(event_name));
	}
}

/* --- management commands ------------------------------------------------ */

/* Shared tail: reply["error"] set -> returns NULL-terminated error text in
 * *err and false; otherwise reply[command] as a bool. */
static bool
mgmt_bool(const char *command, xpc_object_t args, const char **err)
{
	xpc_object_t reply = ca_client_mgmt(command, args);
	*err = NULL;
	if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY)
		return false;
	xpc_object_t e = xpc_dictionary_get_value(reply, "error");
	if (e != nil) {
		*err = xpc_get_type(e) == XPC_TYPE_STRING ? xpc_string_get_string_ptr(e) : "";
		return false;
	}
	return ca_xpc_bool(xpc_dictionary_get_value(reply, command));
}

bool
analytics_rollover_with_options(xpc_object_t options)
{
	@autoreleasepool {
		ca_enter();
		xpc_object_t args = options ? xpc_copy(options) : xpc_dictionary_create_empty();
		if (xpc_dictionary_get_value(args, "writeLogsSynchronously") == nil)
			xpc_dictionary_set_bool(args, "writeLogsSynchronously", true);
		const char *err;
		bool ok = mgmt_bool("rollover", args, &err);
		if (err != NULL)
			os_log_error(ca_log_client, "Rollover failed with error: %s", err);
		return ok;
	}
}

bool
analytics_rollover_events(void)
{
	return analytics_rollover_with_options(NULL);
}

bool
AnalyticsRolloverEvents(void)
{
	return analytics_rollover_with_options(NULL);
}

bool
AnalyticsRolloverWithOptions(NSDictionary *options)
{
	ca_enter();
	@try {
		return analytics_rollover_with_options(options ? ca_xpc_from_ns(options) : NULL);
	} @catch (NSException *e) {
		os_log_error(ca_log_client, "Error: Failed to perform rollover due to "
		    "%{public}@ (%{public}@)", [e name], [e reason]);
		return false;
	}
}

bool
analytics_disable_all_transform_sampling(void)
{
	@autoreleasepool {
		ca_enter();
		const char *err;
		bool ok = mgmt_bool("disable-sampling", xpc_dictionary_create_empty(), &err);
		if (err != NULL)
			os_log_error(ca_log_client, "Failed to disable sampling with error: %s", err);
		return ok;
	}
}

bool
AnalyticsDisableAllTransformSampling(void)
{
	return analytics_disable_all_transform_sampling();
}

bool
analytics_reenable_all_transform_sampling(void)
{
	@autoreleasepool {
		ca_enter();
		const char *err;
		bool ok = mgmt_bool("reenable-sampling", xpc_dictionary_create_empty(), &err);
		if (err != NULL)
			os_log_error(ca_log_client, "Failed to reenable sampling with error: %s", err);
		return ok;
	}
}

bool
AnalyticsReenableAllTransformSampling(void)
{
	return analytics_reenable_all_transform_sampling();
}

bool
analytics_notify_tasking_available(const char *tasking_id)
{
	@autoreleasepool {
		ca_enter();
		xpc_object_t args = xpc_dictionary_create_empty();
		if (tasking_id != NULL)
			xpc_dictionary_set_string(args, "tasking-id", tasking_id);
		const char *err;
		bool ok = mgmt_bool("tasking-notify", args, &err);
		if (err != NULL)
			os_log_error(ca_log_client, "Failed to reconfigure new tasking with error: %s", err);
		return ok;
	}
}

bool
AnalyticsNotifyTaskingAvailable(NSString *taskingID)
{
	return analytics_notify_tasking_available([taskingID UTF8String]);
}

/* Empty in Apple's framework. */
void AnalyticsSetCallbackForQueriedEvent(NSString *n, NSDictionary *(^cb)(void)) { (void)n; (void)cb; }
void AnalyticsSetCallbackForQueriedEventWithQueue(NSString *n, NSDictionary *(^cb)(void),
    dispatch_queue_t q) { (void)n; (void)cb; (void)q; }
void analytics_set_callback_for_queried_event(const char *n, xpc_object_t (^cb)(void)) { (void)n; (void)cb; }
void analytics_set_callback_for_queried_event_with_queue(const char *n,
    xpc_object_t (^cb)(void), dispatch_queue_t q) { (void)n; (void)cb; (void)q; }

/* --- preferences, AggregateDictionary, locale --------------------------- */

void
setObjectForKey(xpc_object_t value, const char *key)
{
	@autoreleasepool {
		ca_enter();
		xpc_object_t args = xpc_dictionary_create_empty();
		xpc_dictionary_set_string(args, "key", key);
		xpc_dictionary_set_value(args, "value", value ? value : xpc_null_create());
		xpc_object_t reply = ca_client_mgmt("prefs-set", args);
		if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY ||
		    xpc_dictionary_get_value(reply, "error") != nil)
			os_log_error(ca_log_client, "Error setting the value for %s", key);
	}
}

xpc_object_t
getObjectForKey(const char *key)
{
	ca_enter();
	xpc_object_t args = xpc_dictionary_create_empty();
	xpc_dictionary_set_string(args, "key", key);
	xpc_object_t reply = ca_client_mgmt("prefs-get", args);
	if (xpc_get_type(reply) != XPC_TYPE_DICTIONARY ||
	    xpc_dictionary_get_value(reply, "error") != nil) {
		os_log_error(ca_log_client, "Error getting the value for %s", key);
		return nil;
	}
	xpc_object_t v = xpc_dictionary_get_value(reply, "value");
	return (v != nil && xpc_get_type(v) == XPC_TYPE_DICTIONARY) ? v : xpc_null_create();
}

void
ad_addScalarForKey(const char *key, int64_t value)
{
	static dispatch_once_t once;
	static void (*add)(CFStringRef, int64_t);

	ca_enter();
	dispatch_once(&once, ^{
		void *h = dlopen("/System/Library/PrivateFrameworks/AggregateDictionary.framework/"
		    "AggregateDictionary", RTLD_LAZY);
		if (h != NULL)
			add = (void (*)(CFStringRef, int64_t))dlsym(h, "ADClientAddValueForScalarKey");
	});
	if (add != NULL)
		add((__bridge CFStringRef)[NSString stringWithUTF8String:key], value);
}

static void
store_locale_info(void)
{
	xpc_object_t args = xpc_dictionary_create_empty();
	@autoreleasepool {
		NSArray *preferred = [NSLocale preferredLanguages];
		/* +[NSLocale systemLanguages] is Foundation SPI. */
		NSArray *system = ((id (*)(id, SEL))objc_msgSend)([NSLocale class],
		    sel_registerName("systemLanguages"));
		NSArray *ui = [NSBundle preferredLocalizationsFromArray:system forPreferences:preferred];
		if ([ui count] != 0)
			xpc_dictionary_set_string(args, "user-interface-language", [ui[0] UTF8String]);
		if ([preferred count] != 0)
			xpc_dictionary_set_string(args, "preferred-user-interface-language",
			    [preferred[0] UTF8String]);
		NSLocale *cur = [NSLocale currentLocale];
		id cc = [cur objectForKey:(__bridge NSString *)kCFLocaleCountryCode];
		if (cc != nil)
			xpc_dictionary_set_string(args, "user-set-region-format", [cc UTF8String]);
	}
	char *d = xpc_copy_description(args);
	os_log(ca_log_client, "store-locale-info is sending %s", d);
	free(d);

	xpc_object_t reply = ca_client_mgmt("store-locale-info", args);
	if (xpc_get_type(reply) == XPC_TYPE_DICTIONARY) {
		const char *e = xpc_dictionary_get_string(reply, "error");
		if (e != NULL)
			os_log_error(ca_log_client, "store-locale-info failed error: %s", e);
	}
}

void
report_locale_prefs_to_analyticsd(void)
{
	ca_enter();
	store_locale_info();
	[[NSNotificationCenter defaultCenter]
	    addObserverForName:(__bridge NSString *)kCFLocaleCurrentLocaleDidChangeNotification
			object:nil
			 queue:[[NSOperationQueue alloc] init]
		    usingBlock:^(NSNotification *note) {
			(void)note;
			os_log(ca_log_client, "Received locale changed notification");
			store_locale_info();
		    }];
}
