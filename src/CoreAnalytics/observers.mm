/*
 * AnalyticsEventObserver and AnalyticsConfigurationObserver.
 *
 * Each observer owns one implementation object, the counterpart of
 * Apple's EventObserverImpl / ConfigurationObserverImpl, which snapshots
 * the delegate (weakly), the delegate queue and the observer itself
 * (weakly) when observing starts.  The client holds the implementation
 * weakly, so releasing it (stop, restart or dealloc) ends delivery.
 * All state changes run as barriers on the observer's concurrent queue.
 *
 * Objective-C++ only so that a rejected create-event-observer request
 * throws std::runtime_error, as Apple's does.
 *
 * Copyright (C) 2026, LibreDarwin
 * SPDX-License-Identifier: BSD-3-Clause
 */

#import "ca_internal.h"
#import <CoreAnalytics/CoreAnalytics.h>

#include <stdexcept>
#include <stdlib.h>
#include <string.h>

/* --- implementation objects -------------------------------------------- */

@interface CAEventObserverImpl : NSObject <CAEventObserverImpl> {
@public
	__weak AnalyticsEventObserver *_observer;
	__weak id<AnalyticsEventObserverDelegate> _delegate;
	dispatch_queue_t _delegateQueue;
}
@end

@implementation CAEventObserverImpl

- (void)notifyMessageEmitted:(id)message
{
	id<AnalyticsEventObserverDelegate> delegate = _delegate;
	if (delegate == nil)
		return;
	AnalyticsEventObserver *observer = _observer;

	ca_buf b = {};
	ca_json_pretty_from_ns(message, 4, &b);
	NSString *text = [NSString stringWithUTF8String:b.ptr];
	ca_buf_free(&b);

	dispatch_barrier_async(_delegateQueue, ^{
		[delegate observer:observer didEmitMessage:text];
	});
}

@end

@interface CAConfigurationObserverImpl : NSObject <CAConfigurationObserverImpl> {
@public
	NSString *_type;
	__weak AnalyticsConfigurationObserver *_observer;
	__weak id<AnalyticsConfigurationObserverDelegate> _delegate;
	dispatch_queue_t _delegateQueue;
}
@end

@implementation CAConfigurationObserverImpl

- (void)notifyConfigurationActivated:(const struct ca_config *)config
{
	id<AnalyticsConfigurationObserverDelegate> delegate = _delegate;
	if (delegate == nil)
		return;
	id configuration = ca_config_external(config, [_type UTF8String]);
	NSString *type = _type;
	AnalyticsConfigurationObserver *observer = _observer;

	dispatch_barrier_async(_delegateQueue, ^{
		[delegate observer:observer didChangeConfiguration:configuration type:type];
	});
}

@end

/* The `observer` ivar.  Apple's is a std::shared_ptr; a C++ member with a
 * constructor keeps the same .cxx_construct/.cxx_destruct pair. */
struct CAImplRef {
	__strong id impl;
	CAImplRef() : impl(nil) {}
};

/* --- AnalyticsEventObserver --------------------------------------------- */

@implementation AnalyticsEventObserver {
	CAImplRef observer;
}

- (instancetype)init
{
	if ((self = [super init]) != nil) {
		_queue = dispatch_queue_create("com.apple.CoreAnalytics.EventObserver",
		    DISPATCH_QUEUE_CONCURRENT);
		self.delegate = nil;
		self.delegateQueue = nil;
	}
	return self;
}

- (void)dealloc
{
	observer.impl = nil;
}

- (void)setEventObserverDelegate:(id<AnalyticsEventObserverDelegate>)delegate
    queue:(dispatch_queue_t)queue
{
	ca_enter();
	dispatch_barrier_async(self.queue, ^{
		self.delegate = delegate;
		self.delegateQueue = queue;
	});
}

- (BOOL)startObservingEventList:(NSArray<NSString *> *)events
{
	return [self startObservingEventList:events withErrorHandler:nil];
}

- (BOOL)startObservingEventList:(NSArray<NSString *> *)events
    withErrorHandler:(void (^)(NSString *))errorHandler
{
	ca_enter();

	xpc_object_t names = xpc_array_create_empty();
	for (NSString *name in events) {
		const char *u = [name UTF8String];
		xpc_array_append_value(names, u != NULL ? xpc_string_create(u) : xpc_null_create());
	}
	xpc_object_t args = xpc_dictionary_create_empty();
	xpc_dictionary_set_value(args, "events", names);

	void (^handler)(const char *) = nil;
	if (errorHandler != nil)
		handler = ^(const char *d) {
			errorHandler([NSString stringWithUTF8String:d != NULL ? d : ""]);
		};
	ca_client_register_error_handler(handler);

	xpc_object_t reply = ca_client_mgmt("create-event-observer", args);
	if (xpc_get_type(reply) == XPC_TYPE_DICTIONARY &&
	    xpc_dictionary_get_value(reply, "error") != nil)
		throw std::runtime_error("create-event-observer failed");

	dispatch_barrier_async(self.queue, ^{
		CAEventObserverImpl *impl = [CAEventObserverImpl new];
		impl->_observer = self;
		impl->_delegate = self.delegate;
		impl->_delegateQueue = self.delegateQueue;
		self->observer.impl = impl;
		ca_client_register_event_observer(impl);
	});
	return YES;
}

- (BOOL)stopObserving
{
	ca_enter();
	dispatch_barrier_async(self.queue, ^{
		self->observer.impl = nil;
	});
	return YES;
}

@end

/* --- AnalyticsConfigurationObserver ------------------------------------- */

@implementation AnalyticsConfigurationObserver {
	CAImplRef observer;
}

- (instancetype)init
{
	if ((self = [super init]) != nil) {
		_queue = dispatch_queue_create("com.apple.CoreAnalytics.ConfigurationObserver",
		    DISPATCH_QUEUE_CONCURRENT);
		self.delegate = nil;
		self.delegateQueue = nil;
	}
	return self;
}

- (void)dealloc
{
	observer.impl = nil;
}

- (void)setConfigurationObserverDelegate:(id<AnalyticsConfigurationObserverDelegate>)delegate
    queue:(dispatch_queue_t)queue
{
	ca_enter();
	dispatch_barrier_async(self.queue, ^{
		self.delegate = delegate;
		self.delegateQueue = queue;
	});
}

- (BOOL)startObservingConfigurationType:(NSString *)type
{
	ca_enter();
	dispatch_barrier_async(self.queue, ^{
		CAConfigurationObserverImpl *impl = [CAConfigurationObserverImpl new];
		impl->_type = [[NSString alloc] initWithUTF8String:[type UTF8String]];
		impl->_observer = self;
		impl->_delegate = self.delegate;
		impl->_delegateQueue = self.delegateQueue;
		self->observer.impl = impl;
		ca_client_register_configuration_observer(impl);
	});
	return YES;
}

- (BOOL)stopObservingConfigurationType:(NSString *)type
{
	(void)type;
	ca_enter();
	dispatch_barrier_async(self.queue, ^{
		self->observer.impl = nil;
	});
	return YES;
}

@end
