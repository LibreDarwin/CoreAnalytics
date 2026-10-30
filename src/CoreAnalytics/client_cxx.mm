/*
 * The framework's C++ interface: CoreAnalytics::Client, the EventObserver
 * and ConfigurationObserver base classes, and the analytics_tool_* helpers
 * behind analyticsd's command-line tools.  Every Client method forwards to
 * its counterpart in client.m.
 *
 * Arguments of Apple's applesauce::xpc::object and ::dict types are one
 * retained xpc_object_t; whether passed by value or by reference they
 * arrive as a pointer to it, so those functions take `const xpc_object_t *`
 * and are bound to Apple's symbol names with asm labels.
 *
 * Copyright (C) 2026, LibreDarwin
 * SPDX-License-Identifier: BSD-3-Clause
 */

#include <CoreAnalytics/CoreAnalytics.h>
#include "ca_internal.h"
#include "nlohmann_json.h"

#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <time.h>
#include <utility>
#include <uuid/uuid.h>
#include <vector>

#define CA_SYMBOL(name) __asm__("_" name)

using nlohmann::json;
using jtype = json::value_t;

/* JSON value -> XPC, keeping nlohmann's integer/unsigned/float typing so
 * ca_json_from_xpc() writes what nlohmann's dump() would. */
static xpc_object_t
xpc_from_json(const json &j)
{
	switch (j.m_type) {
	case jtype::object: {
		xpc_object_t d = xpc_dictionary_create_empty();
		for (const auto &kv : *j.m_value.object)
			xpc_dictionary_set_value(d, kv.first.c_str(), xpc_from_json(kv.second));
		return d;
	}
	case jtype::array: {
		xpc_object_t a = xpc_array_create_empty();
		for (const json &v : *j.m_value.array)
			xpc_array_append_value(a, xpc_from_json(v));
		return a;
	}
	case jtype::string: return xpc_string_create(j.m_value.string->c_str());
	case jtype::boolean: return xpc_bool_create(j.m_value.boolean);
	case jtype::number_integer: return xpc_int64_create(j.m_value.number_integer);
	case jtype::number_unsigned: return xpc_uint64_create(j.m_value.number_unsigned);
	case jtype::number_float: return xpc_double_create(j.m_value.number_float);
	/* ponytail: binary values are sent as null; nothing produces them */
	default: return xpc_null_create();
	}
}

/* A parsed "message-emit" payload -> JSON value.  ca_ns_from_json() typed
 * the numbers the way nlohmann's parser does, except that non-negative
 * integers come back as signed ('q'); nlohmann stores those unsigned. */
static json
json_from_ns(id obj)
{
	json j;
	if ([obj isKindOfClass:[NSDictionary class]]) {
		j.m_type = jtype::object;
		j.m_value.object = new json::object_t;
		for (NSString *k in obj)
			j.m_value.object->emplace(std::string([k UTF8String]),
			    json_from_ns([obj objectForKey:k]));
	} else if ([obj isKindOfClass:[NSArray class]]) {
		j.m_type = jtype::array;
		j.m_value.array = new json::array_t;
		for (id v in obj)
			j.m_value.array->push_back(json_from_ns(v));
	} else if ([obj isKindOfClass:[NSString class]]) {
		j.m_type = jtype::string;
		j.m_value.string = new std::string([obj UTF8String]);
	} else if (obj == (__bridge id)kCFBooleanTrue || obj == (__bridge id)kCFBooleanFalse) {
		j.m_type = jtype::boolean;
		j.m_value.boolean = [obj boolValue];
	} else if ([obj isKindOfClass:[NSNumber class]]) {
		char t = *[obj objCType];
		if (t == 'd' || t == 'f') {
			j.m_type = jtype::number_float;
			j.m_value.number_float = [obj doubleValue];
		} else if (t == 'Q' || [obj longLongValue] >= 0) {
			j.m_type = jtype::number_unsigned;
			j.m_value.number_unsigned = [obj unsignedLongLongValue];
		} else {
			j.m_type = jtype::number_integer;
			j.m_value.number_integer = [obj longLongValue];
		}
	}
	return j;
}

/* --- classes ------------------------------------------------------------ */

/*
 * The observer methods' exact signatures matter beyond the vtable layout:
 * on arm64e each virtual call is signed with a hash of the method's mangled
 * name.  Apple's take the message by value and a FrameworkConfiguration
 * from the global namespace (opaque here: it is our struct ca_config).
 */
class FrameworkConfiguration;

namespace CoreAnalytics {
class EventObserver {
public:
	virtual ~EventObserver();
	virtual void notifyMessageEmitted(json message) = 0;
};

class ConfigurationObserver {
public:
	virtual ~ConfigurationObserver();
	virtual void notifyConfigurationActivated(const FrameworkConfiguration &config) = 0;
};

/* Passed in one register: bytes 0-2 of the argument. */
struct SendEventOptions {
	uint8_t priority;
	uint8_t format;
	bool logPayload;
};

/* Stateless: everything lives in client.m's single client. */
class Client {
public:
	Client();
	static Client &get();
	void init();
	void initConnection();
	void updateDaemonState(int token);
	bool hasConfig() const;
	bool isEventUsed(std::string_view name) const;
	void allowAllEvents();
	bool sendEventAlways(std::string name, const std::function<json()> &payload,
	    SendEventOptions options);
	void registerErrorHandler(std::function<void(const std::string &)> &&handler);
	void registerEventObserver(std::weak_ptr<EventObserver> observer);
	void registerConfigurationObserver(std::weak_ptr<ConfigurationObserver> observer);
	void sendCheckinMessage_sync();
	void acquireSendTransaction();
	void releaseSendTransaction();
	void cancelConnection_sync();
	void sendExitBarrierWithTimeoutSync(unsigned timeout_ms);
};
}	/* namespace CoreAnalytics */

using namespace CoreAnalytics;

EventObserver::~EventObserver() {}
ConfigurationObserver::~ConfigurationObserver() {}

/* The client holds observers weakly, like Apple's std::weak_ptr lists;
 * these adapters carry a C++ observer into that list and stay alive for
 * the life of the process (as Apple's never-pruned list entries do). */
@interface CACxxEventObserver : NSObject <CAEventObserverImpl> {
@public
	std::weak_ptr<EventObserver> _observer;
}
@end

@implementation CACxxEventObserver
- (void)notifyMessageEmitted:(id)message
{
	if (std::shared_ptr<EventObserver> o = _observer.lock()) {
		o->notifyMessageEmitted(json_from_ns(message));
	}
}
@end

@interface CACxxConfigurationObserver : NSObject <CAConfigurationObserverImpl> {
@public
	std::weak_ptr<ConfigurationObserver> _observer;
}
@end

@implementation CACxxConfigurationObserver
- (void)notifyConfigurationActivated:(const struct ca_config *)config
{
	if (std::shared_ptr<ConfigurationObserver> o = _observer.lock())
		o->notifyConfigurationActivated(*reinterpret_cast<const FrameworkConfiguration *>(config));
}
@end

static void
keep_alive(id adapter)
{
	static NSMutableArray *adapters;
	@synchronized ([CACxxEventObserver class]) {
		if (adapters == nil)
			adapters = [NSMutableArray array];
		[adapters addObject:adapter];
	}
}

/* --- Client ------------------------------------------------------------- */

Client::Client() {}

Client &
Client::get()
{
	static Client client;
	ca_client_get();
	return client;
}

void Client::init() { ca_client_init_sync(); }
void Client::initConnection() { ca_init_connection_sync(); }
void Client::updateDaemonState(int) { ca_update_daemon_state(); }
bool Client::hasConfig() const { return ca_client_has_config(); }
bool Client::isEventUsed(std::string_view name) const { return ca_client_is_event_used(name.data(), name.size()); }
void Client::allowAllEvents() { ca_client_allow_all_events(); }
void Client::sendCheckinMessage_sync() { ca_send_checkin_sync(); }
void Client::acquireSendTransaction() { ca_acquire_send_transaction(); }
void Client::releaseSendTransaction() { ca_release_send_transaction(); }
void Client::cancelConnection_sync() { ca_cancel_connection_sync(); }
void Client::sendExitBarrierWithTimeoutSync(unsigned timeout_ms) { ca_send_exit_barrier_with_timeout_sync(timeout_ms); }

/* The payload is only built once there is a connection; one that is not a
 * JSON object drops the event. */
bool
Client::sendEventAlways(std::string name, const std::function<json()> &payload,
    SendEventOptions options)
{
	const std::function<json()> *build = &payload;
	return ca_client_send_event(name.c_str(), ^bool(ca_buf *out) {
		json j = (*build)();
		if (j.m_type != jtype::object)
			return false;
		char *err = NULL;
		bool ok = ca_json_from_xpc(xpc_from_json(j), out, &err);
		free(err);
		return ok;
	}, options.priority, options.format, options.logPayload);
}

void
Client::registerErrorHandler(std::function<void(const std::string &)> &&handler)
{
	auto h = std::make_shared<std::function<void(const std::string &)>>(std::move(handler));
	ca_client_register_error_handler(^(const char *description) {
		if (*h)
			(*h)(description != NULL ? description : "");
	});
}

void
Client::registerEventObserver(std::weak_ptr<EventObserver> observer)
{
	CACxxEventObserver *a = [CACxxEventObserver new];
	a->_observer = std::move(observer);
	keep_alive(a);
	ca_client_register_event_observer(a);
}

void
Client::registerConfigurationObserver(std::weak_ptr<ConfigurationObserver> observer)
{
	CACxxConfigurationObserver *a = [CACxxConfigurationObserver new];
	a->_observer = std::move(observer);
	keep_alive(a);
	ca_client_register_configuration_observer(a);
}

/* Methods taking applesauce types.  `self` is unused: there is one client. */

bool cxx_sendXpcMessage(Client *, const xpc_object_t *, uint8_t, bool, bool)
    CA_SYMBOL("_ZN13CoreAnalytics6Client14sendXpcMessageERKN10applesauce3xpc4dictE18XPCMessagePrioritybb");
bool
cxx_sendXpcMessage(Client *, const xpc_object_t *msg, uint8_t priority, bool log_payload, bool retry)
{
	return ca_send_xpc_message(*msg, priority, log_payload, retry);
}

bool cxx_sendXpcMessage_sync(Client *, const xpc_object_t *, uint8_t, bool, bool)
    CA_SYMBOL("_ZN13CoreAnalytics6Client19sendXpcMessage_syncEN10applesauce3xpc4dictE18XPCMessagePrioritybb");
bool
cxx_sendXpcMessage_sync(Client *, const xpc_object_t *msg, uint8_t priority, bool log_payload, bool retry)
{
	return ca_send_xpc_message_sync(*msg, priority, log_payload, retry);
}

void cxx_retryXpcMessage_sync(Client *, const xpc_object_t *, uint8_t, bool)
    CA_SYMBOL("_ZN13CoreAnalytics6Client20retryXpcMessage_syncERKN10applesauce3xpc4dictE18XPCMessagePriorityb");
void
cxx_retryXpcMessage_sync(Client *, const xpc_object_t *msg, uint8_t priority, bool retry)
{
	ca_retry_helper(*msg, priority, retry, 0, 100);
}

void cxx_retryXpcMessageHelper_sync(Client *, const xpc_object_t *, uint8_t, bool, uint8_t, uint64_t)
    CA_SYMBOL("_ZN13CoreAnalytics6Client26retryXpcMessageHelper_syncEN10applesauce3xpc4dictE18XPCMessagePrioritybhy");
void
cxx_retryXpcMessageHelper_sync(Client *, const xpc_object_t *msg, uint8_t priority, bool retry,
    uint8_t attempt, uint64_t delay_ms)
{
	ca_retry_helper(*msg, priority, retry, attempt, delay_ms);
}

void cxx_handleServerMessage_sync(Client *, const xpc_object_t *)
    CA_SYMBOL("_ZN13CoreAnalytics6Client24handleServerMessage_syncERKN10applesauce3xpc4dictE");
void cxx_handleServerMessage_sync(Client *, const xpc_object_t *msg) { ca_handle_server_message_sync(*msg); }

void cxx_handleSinkMessageEmit_sync(Client *, const xpc_object_t *)
    CA_SYMBOL("_ZN13CoreAnalytics6Client26handleSinkMessageEmit_syncERKN10applesauce3xpc4dictE");
void cxx_handleSinkMessageEmit_sync(Client *, const xpc_object_t *msg) { ca_handle_sink_message_emit_sync(*msg); }

void cxx_handleConfigurationChange_sync(Client *, const xpc_object_t *)
    CA_SYMBOL("_ZN13CoreAnalytics6Client30handleConfigurationChange_syncERKN10applesauce3xpc4dictE");
void cxx_handleConfigurationChange_sync(Client *, const xpc_object_t *msg) { ca_handle_configuration_change_sync(*msg); }

/* Returned like applesauce::xpc::object: through x8, owning one reference.
 * The user-provided destructor keeps it out of registers, where ARC would
 * otherwise let clang pass a struct whose only member is a strong pointer. */
struct xpc_result {
	xpc_object_t object;
	~xpc_result() {}
};

xpc_result cxx_sendManagementCommandWithReply(const Client *, std::string, const xpc_object_t *)
    CA_SYMBOL("_ZNK13CoreAnalytics6Client30sendManagementCommandWithReplyENSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEEN10applesauce3xpc4dictE");
xpc_result
cxx_sendManagementCommandWithReply(const Client *, std::string command, const xpc_object_t *args)
{
	return { ca_client_mgmt(command.c_str(), *args) };
}

void CASPIEnter(void) { ca_enter(); }

/* --- AppleSauce text form ----------------------------------------------- */

/* applesauce::xpc::object::to_string(), which the tools return when the
 * reply has no field of their own: tab-indented "key": value lines. */
static void
to_text(xpc_object_t obj, std::string &out, int depth)
{
	xpc_type_t t = xpc_get_type(obj);
	if (t == XPC_TYPE_DICTIONARY) {
		if (xpc_dictionary_get_count(obj) == 0) {
			out += "{}";
			return;
		}
		out += '{';
		__block bool first = true;
		xpc_dictionary_apply(obj, ^bool(const char *key, xpc_object_t value) {
			out += first ? "\n" : ",\n";
			first = false;
			out.append(depth + 1, '\t');
			out += '"';
			out += key;
			out += "\": ";
			to_text(value, out, depth + 1);
			return true;
		});
		out += '\n';
		out.append(depth, '\t');
		out += '}';
	} else if (t == XPC_TYPE_ARRAY) {
		size_t n = xpc_array_get_count(obj);
		if (n == 0) {
			out += "[]";
			return;
		}
		out += '[';
		for (size_t i = 0; i < n; i++) {
			out += i == 0 ? "\n" : ",\n";
			out.append(depth + 1, '\t');
			out += std::to_string(i) + ": ";
			to_text(xpc_array_get_value(obj, i), out, depth + 1);
		}
		out += '\n';
		out.append(depth, '\t');
		out += ']';
	} else if (t == XPC_TYPE_STRING) {
		out += '"';
		out += xpc_string_get_string_ptr(obj);
		out += '"';
	} else if (t == XPC_TYPE_INT64) {
		out += std::to_string(xpc_int64_get_value(obj));
	} else if (t == XPC_TYPE_UINT64) {
		out += std::to_string(xpc_uint64_get_value(obj)) + "u";
	} else if (t == XPC_TYPE_DOUBLE) {
		out += std::to_string(xpc_double_get_value(obj));
	} else if (t == XPC_TYPE_BOOL) {
		out += xpc_bool_get_value(obj) ? "true" : "false";
	} else if (t == XPC_TYPE_NULL) {
		out += "null";
	} else if (t == XPC_TYPE_DATE) {
		time_t s = (time_t)(xpc_date_get_value(obj) / NSEC_PER_SEC);
		struct tm tm;
		char buf[64];
		localtime_r(&s, &tm);
		strftime(buf, sizeof buf, "%F %T %Z", &tm);
		out += buf;
	} else if (t == XPC_TYPE_DATA) {
		const uint8_t *p = (const uint8_t *)xpc_data_get_bytes_ptr(obj);
		size_t n = xpc_data_get_length(obj);
		char buf[32];
		snprintf(buf, sizeof buf, "[%zu bytes]", n);
		out += buf;
		for (size_t i = 0; i < n; i++) {
			snprintf(buf, sizeof buf, " %02x", p[i]);
			out += buf;
		}
	} else if (t == XPC_TYPE_UUID) {
		char buf[37];
		uuid_unparse_lower(xpc_uuid_get_bytes(obj), buf);
		out += buf;
	} else if (t == XPC_TYPE_ERROR) {
		const char *d = xpc_dictionary_get_string(obj, XPC_ERROR_KEY_DESCRIPTION);
		out += "XPC_ERROR(";
		out += d != NULL ? d : "";
		out += ')';
	} else {
		char *d = xpc_copy_description(obj);
		out += d;
		free(d);
	}
}

static std::string
to_text(xpc_object_t obj)
{
	std::string s;
	to_text(obj, s, 0);
	return s;
}

/* --- analytics_tool_* --------------------------------------------------- */

/*
 * Each sends one management command and reads the reply.  A reply that is
 * not a dictionary is XPC null (ca_client_mgmt).  Field lookups go to the
 * reply whatever its type, as Apple's do; dyn_cast_or_default() reads a
 * field of the expected type or yields the default.
 */

static bool is_dict(xpc_object_t r) { return xpc_get_type(r) == XPC_TYPE_DICTIONARY; }
static xpc_object_t field(xpc_object_t r, const char *key) { return xpc_dictionary_get_value(r, key); }

static std::string
string_of(xpc_object_t v)
{
	if (v == nil || xpc_get_type(v) != XPC_TYPE_STRING)
		return "";
	return xpc_string_get_string_ptr(v);
}

static xpc_object_t
command(const char *cmd, xpc_object_t args = nil)
{
	ca_enter();
	return ca_client_mgmt(cmd, args);
}

static void
fail_if_error(xpc_object_t r, const char *failure)
{
	if (is_dict(r) && field(r, "error") != nil)
		throw std::runtime_error(failure);
}

/* An exception for "error", the reply's `cmd` string when present, else
 * the whole reply as text. */
static std::string
field_or_text(xpc_object_t r, const char *cmd, const char *failure)
{
	fail_if_error(r, failure);
	if (field(r, cmd) != nil)
		return string_of(field(r, cmd));
	return to_text(r);
}

/* The same, with "unknown" for a reply that is not a dictionary. */
static std::string
string_reply(const char *cmd, xpc_object_t args, const char *failure)
{
	xpc_object_t r = command(cmd, args);
	if (!is_dict(r))
		return "unknown";
	return field_or_text(r, cmd, failure);
}

static xpc_object_t
args_with(const char *key, xpc_object_t value)
{
	xpc_object_t d = xpc_dictionary_create_empty();
	xpc_dictionary_set_value(d, key, value);
	return d;
}

static xpc_object_t
args_with_string(const char *key, const std::string &value)
{
	return args_with(key, xpc_string_create(value.c_str()));
}

static xpc_object_t
args_with_optional(const char *key, const std::optional<std::string> &value)
{
	return value ? args_with_string(key, *value) : xpc_dictionary_create_empty();
}

bool
analytics_tool_has_config(void)
{
	ca_enter();
	return Client::get().hasConfig();
}

std::string
analytics_tool_log_dump(std::optional<std::string> aggPeriod)
{
	return string_reply("log-dump", args_with_optional("aggPeriod", aggPeriod), "log-dump failed");
}

std::string
analytics_tool_log_transform_counts(void)
{
	return string_reply("log-transform-counts", nil, "log-transform-counts failed");
}

std::string
analytics_tool_config_list(void)
{
	return string_reply("config-list", nil, "config-list failed");
}

std::string
analytics_tool_config_info(void)
{
	return string_reply("config-info", nil, "config-info failed");
}

/* Like string_reply, but also accepts the reply's "config-info". */
std::string
analytics_tool_config_dump(void)
{
	xpc_object_t r = command("config-dump");
	if (!is_dict(r))
		return "unknown";
	fail_if_error(r, "config-dump failed");
	if (field(r, "config-dump") != nil)
		return string_of(field(r, "config-dump"));
	if (field(r, "config-info") != nil)
		return string_of(field(r, "config-info"));
	return to_text(r);
}

std::string
analytics_tool_query_list(void)
{
	return field_or_text(command("query-list"), "query-list", "query-list failed");
}

std::string
analytics_tool_transform_info(std::string name)
{
	return string_reply("transform-info", args_with_string("name", name), "transform-info failed");
}

std::string cxx_query_state(std::string, const xpc_object_t *)
    CA_SYMBOL("_Z26analytics_tool_query_stateNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEN10applesauce3xpc6objectE");
std::string
cxx_query_state(std::string name, const xpc_object_t *parameters)
{
	xpc_object_t args = args_with_string("state-name", name);
	xpc_dictionary_set_value(args, "state-parameters", *parameters);
	return field_or_text(command("query-state", args), "query-state", "query-state failed");
}

std::string
analytics_tool_get_cache_list(void)
{
	xpc_object_t r = command("list-transforms-in-cache");
	fail_if_error(r, "list-transforms-in-cache failed");
	return string_of(field(r, "transforms-in-cache"));
}

std::string
analytics_tool_app_usage_sync(void)
{
	xpc_object_t r = command("app-usage-sync");
	if (!is_dict(r))
		throw std::runtime_error("Failed to run 'app-usage-sync'");
	if (field(r, "appusage") != nil)
		return string_of(field(r, "appusage"));
	return to_text(r);
}

/* Old-style tasking: the reply's `cmd` flag, also read off a reply that is
 * not a dictionary. */
static bool
tasking_reply(const char *cmd, xpc_object_t args, const char *failure)
{
	xpc_object_t r = command(cmd, args);
	fail_if_error(r, failure);
	return ca_xpc_bool(field(r, cmd));
}

bool
analytics_tool_config_set_tasking(std::string config)
{
	return tasking_reply("set-tasking-old", args_with_string("string-config", config),
	    "Config-set-tasking (old style config) failed");
}

/* std::pair<applesauce::xpc::object, unsigned long>: the mapped config
 * (shared memory) and its size. */
struct tasking_pair {
	__unsafe_unretained xpc_object_t config;
	unsigned long size;
};

bool cxx_config_set_tasking_ndjson(const tasking_pair &)
    CA_SYMBOL("_Z40analytics_tool_config_set_tasking_ndjsonRKNSt3__14pairIN10applesauce3xpc6objectEmEE");
bool
cxx_config_set_tasking_ndjson(const tasking_pair &p)
{
	xpc_object_t args = args_with("mmap-config", p.config);
	xpc_dictionary_set_int64(args, "mmap-config-size", (int64_t)p.size);	/* signed, as Apple's */
	return tasking_reply("set-tasking", args, "Config-set-tasking (ndjson) failed");
}

/* false for a non-dictionary reply, else the reply's `cmd` flag. */
static bool
flag_reply(const char *cmd, xpc_object_t args, const char *failure)
{
	xpc_object_t r = command(cmd, args);
	if (!is_dict(r))
		return false;
	fail_if_error(r, failure);
	return ca_xpc_bool(field(r, cmd));
}

bool
analytics_tool_transform_evict(std::string name)
{
	return flag_reply("transform-evict", args_with_string("name", name), "transform-evict failed");
}

bool
analytics_tool_transform_persist(std::string name)
{
	return flag_reply("transform-persist", args_with_string("name", name), "transform-persist failed");
}

/* No "error" check; a non-dictionary reply throws. */
bool
analytics_tool_is_event_used_check_db(std::string name)
{
	xpc_object_t r = command("event-used", args_with_string("name", name));
	if (!is_dict(r))
		throw std::runtime_error("event-used failed");
	return ca_xpc_bool(field(r, "event-used"));
}

void
analytics_tool_config_reload(void)
{
	fail_if_error(command("config-reload"), "Config-reload failed");
}

void
analytics_tool_config_set_reboot_clear(bool clear)
{
	fail_if_error(command("set-clear-config-after-reboot",
	    args_with("should-clear-config-after-reboot", xpc_bool_create(clear))),
	    "Set-clear-config-after-reboot failed");
}

void
analytics_tool_query_clear(std::optional<std::string> name)
{
	fail_if_error(command("query-clear", args_with_optional("state-name", name)),
	    "query-clear failed");
}

void cxx_insert_query_state(std::string, const xpc_object_t *, const xpc_object_t *)
    CA_SYMBOL("_Z33analytics_tool_insert_query_stateNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEN10applesauce3xpc6objectES8_");
void
cxx_insert_query_state(std::string name, const xpc_object_t *state, const xpc_object_t *parameters)
{
	xpc_object_t args = args_with_string("state-name", name);
	xpc_dictionary_set_value(args, "state", *state);
	xpc_dictionary_set_value(args, "state-parameters", *parameters);
	fail_if_error(command("insert-query-state", args), "insert-query-state failed");
}

/* The reply is not looked at. */
void analytics_tool_save(void) { command("save-log"); }
void analytics_tool_commit(void) { command("commit"); }

bool
analytics_tool_rollover(std::optional<std::string> aggPeriod, bool preserveState)
{
	ca_enter();
	xpc_object_t options = args_with_optional("aggPeriod", aggPeriod);
	xpc_dictionary_set_bool(options, "preserveState", preserveState);
	return analytics_rollover_with_options(options);
}
