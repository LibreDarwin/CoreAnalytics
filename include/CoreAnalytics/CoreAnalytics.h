/*
 * CoreAnalytics/CoreAnalytics.h
 *
 * Public C interface of the CoreAnalytics private framework: submit
 * telemetry events to analyticsd and drive a few of its management
 * commands.  Signatures are recovered from Apple's framework; any binary
 * built against this header links against either implementation.
 *
 * The header stays valid C and C++ (ld64's Options.cpp includes it from
 * C++); the NSString/NSDictionary entry points are only declared when
 * compiling Objective-C.
 *
 * Copyright (C) 2026, LibreDarwin
 * SPDX-License-Identifier: BSD-3-Clause
 */

#ifndef _COREANALYTICS_COREANALYTICS_H_
#define _COREANALYTICS_COREANALYTICS_H_

#include <stdbool.h>
#include <stdint.h>
#include <sys/cdefs.h>
#include <xpc/xpc.h>
#include <dispatch/dispatch.h>

#ifdef __OBJC__
#import <Foundation/Foundation.h>
#endif

__BEGIN_DECLS

/* Lazy XPC payload builders hand back a +1 reference, e.g.
 *	analytics_send_event_lazy("com.example.event",
 *	    ^xpc_object_t (void) CA_RETURNS_RETAINED { return payload; });
 * Under MRR, return a retained object. */
#if __has_feature(attribute_ns_returns_retained)
#define CA_RETURNS_RETAINED __attribute__((ns_returns_retained))
#else
#define CA_RETURNS_RETAINED
#endif

/* --- xpc_object_t interface -------------------------------------------- */

/* Send `payload` (an XPC dictionary, or NULL for an empty one) as event
 * `event_name`.  Dropped silently when analyticsd's configuration does not
 * use the event. */
void analytics_send_event(const char *event_name, xpc_object_t payload);

/* `options` is an XPC dictionary; the only key read is "kLogPayload"
 * (bool), which logs the payload to the send-diagnostics category. */
void analytics_send_event_with_options(const char *event_name,
    xpc_object_t payload, xpc_object_t options);

/* The builder is only called when the event is in use.  Return true when
 * the event was handed to the XPC send queue. */
bool analytics_send_event_lazy(const char *event_name,
    xpc_object_t (^builder)(void) CA_RETURNS_RETAINED);
bool analytics_send_event_lazy_with_options(const char *event_name,
    xpc_object_t (^builder)(void) CA_RETURNS_RETAINED, xpc_object_t options);
bool analytics_send_event_lazy_high_priority(const char *event_name,
    xpc_object_t (^builder)(void) CA_RETURNS_RETAINED);
bool analytics_send_exploding_event_lazy(const char *event_name,
    xpc_object_t (^builder)(void) CA_RETURNS_RETAINED);

bool analytics_is_event_used(const char *event_name);

/* Management commands (synchronous round trip to analyticsd). */
bool analytics_rollover_events(void);
bool analytics_rollover_with_options(xpc_object_t options);
bool analytics_disable_all_transform_sampling(void);
bool analytics_reenable_all_transform_sampling(void);
bool analytics_notify_tasking_available(const char *tasking_id);

/* No-ops in Apple's framework; kept for link compatibility. */
void analytics_set_callback_for_queried_event(const char *event_name,
    xpc_object_t (^callback)(void));
void analytics_set_callback_for_queried_event_with_queue(
    const char *event_name, xpc_object_t (^callback)(void),
    dispatch_queue_t queue);

/* Daemon-side preference store. */
void setObjectForKey(xpc_object_t value, const char *key);
xpc_object_t getObjectForKey(const char *key);

/* Legacy AggregateDictionary bridge: forwards to
 * ADClientAddValueForScalarKey when that framework is present. */
void ad_addScalarForKey(const char *key, int64_t value);

/* Sends the UI language, preferred language and region format to
 * analyticsd now and again whenever the current locale changes. */
void report_locale_prefs_to_analyticsd(void);

/* --- Foundation interface ---------------------------------------------- */

#ifdef __OBJC__

extern NSString *const CASendEventOptionKeyLogPayload;

void AnalyticsSendEvent(NSString *eventName,
    NSDictionary<NSString *, NSObject *> *eventPayload);
void AnalyticsSendEventWithOptions(NSString *eventName,
    NSDictionary<NSString *, NSObject *> *eventPayload,
    NSDictionary<NSString *, NSObject *> *options);

bool AnalyticsSendEventLazy(NSString *eventName,
    NSDictionary<NSString *, NSObject *> *(^eventPayloadBuilder)(void));
bool AnalyticsSendEventLazyWithOptions(NSString *eventName,
    NSDictionary<NSString *, NSObject *> *(^eventPayloadBuilder)(void),
    NSDictionary<NSString *, NSObject *> *options);
bool AnalyticsSendEventLazyHighPriority(NSString *eventName,
    NSDictionary<NSString *, NSObject *> *(^eventPayloadBuilder)(void));
bool AnalyticsSendExplodingEventLazy(NSString *eventName,
    NSDictionary<NSString *, NSObject *> *(^eventPayloadBuilder)(void));

bool AnalyticsIsEventUsed(NSString *eventName);

bool AnalyticsRolloverEvents(void);
bool AnalyticsRolloverWithOptions(NSDictionary<NSString *, NSObject *> *options);
bool AnalyticsDisableAllTransformSampling(void);
bool AnalyticsReenableAllTransformSampling(void);
bool AnalyticsNotifyTaskingAvailable(NSString *taskingID);

void AnalyticsSetCallbackForQueriedEvent(NSString *eventName,
    NSDictionary<NSString *, NSObject *> *(^callback)(void));
void AnalyticsSetCallbackForQueriedEventWithQueue(NSString *eventName,
    NSDictionary<NSString *, NSObject *> *(^callback)(void),
    dispatch_queue_t queue);

#endif /* __OBJC__ */

__END_DECLS

/* --- observers ---------------------------------------------------------- */

#ifdef __OBJC__

@class AnalyticsEventObserver;
@class AnalyticsConfigurationObserver;

@protocol AnalyticsEventObserverDelegate <NSObject>
/* `message` is the emitted JSON object, pretty-printed (4-space indent,
 * sorted keys). */
- (void)observer:(AnalyticsEventObserver *)observer didEmitMessage:(NSString *)message;
@end

@protocol AnalyticsConfigurationObserverDelegate <NSObject>
/* `configuration` is the Foundation form of the daemon's configuration of
 * kind `type`, or nil when the active configuration has none. */
- (void)observer:(AnalyticsConfigurationObserver *)observer
    didChangeConfiguration:(id)configuration type:(NSString *)type;
@end

/* The start/stop methods always return YES (Apple's do too). */

/* Receives messages analyticsd emits for the given events.  The delegate
 * and delegate queue are captured when observing starts; delegate calls
 * are dispatch_barrier_async'd onto the delegate queue, which must be set. */
@interface AnalyticsEventObserver : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, weak) id<AnalyticsEventObserverDelegate> delegate;
@property (nonatomic, strong) dispatch_queue_t delegateQueue;
- (void)setEventObserverDelegate:(id<AnalyticsEventObserverDelegate>)delegate
    queue:(dispatch_queue_t)queue;
- (BOOL)startObservingEventList:(NSArray<NSString *> *)events;
/* Throws std::runtime_error("create-event-observer failed") when
 * analyticsd rejects the request.  `errorHandler` (nil clears it) is
 * called with the XPC error description when the connection drops. */
- (BOOL)startObservingEventList:(NSArray<NSString *> *)events
    withErrorHandler:(void (^)(NSString *description))errorHandler;
- (BOOL)stopObserving;
@end

/* Receives the daemon's external configuration of one kind whenever a new
 * configuration is activated (and at once if one is already active). */
@interface AnalyticsConfigurationObserver : NSObject
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, weak) id<AnalyticsConfigurationObserverDelegate> delegate;
@property (nonatomic, strong) dispatch_queue_t delegateQueue;
- (void)setConfigurationObserverDelegate:(id<AnalyticsConfigurationObserverDelegate>)delegate
    queue:(dispatch_queue_t)queue;
- (BOOL)startObservingConfigurationType:(NSString *)type;
/* Stops observing regardless of `type`. */
- (BOOL)stopObservingConfigurationType:(NSString *)type;
@end

#endif /* __OBJC__ */

#endif /* _COREANALYTICS_COREANALYTICS_H_ */
