/*
 * Exercises the framework's C++ interface for tests/cxx-parity.sh, which
 * runs it against Apple's framework and ours under tests/fake_daemon.dylib
 * and compares the output.
 *
 *   cxx_driver tool <name>	one analytics_tool_* call
 *   cxx_driver client		Client sends, management and event observers
 *   cxx_driver config		configuration observers and isEventUsed
 *   cxx_driver error		error handler and exit barrier
 *
 * Copyright (C) 2026, LibreDarwin
 * SPDX-License-Identifier: BSD-3-Clause
 */
#include <cstdio>
#include <cstring>
#include <functional>
#include <optional>
#include <stdexcept>
#include <string>
#include <string_view>
#include <sys/mman.h>
#include <unistd.h>
#include <xpc/xpc.h>

#include "nlohmann_json.h"

using nlohmann::json;
using jt = json::value_t;
typedef std::optional<std::string> ostr;

class FrameworkConfiguration;
namespace CoreAnalytics {
class EventObserver {
public:
	virtual ~EventObserver();
	virtual void notifyMessageEmitted(json) = 0;
};
class ConfigurationObserver {
public:
	virtual ~ConfigurationObserver();
	virtual void notifyConfigurationActivated(const FrameworkConfiguration &) = 0;
};
/* applesauce::xpc arguments: a pointer to one xpc_object_t; results come
 * back through the result pointer into an object that releases it. */
struct xpc_result {
	xpc_object_t o;
	~xpc_result() { if (o) xpc_release(o); }
};
#define SYM(s) __asm__("_" s)

struct SendEventOptions {
	uint8_t priority, format;
	bool logPayload;
};
class Client {
public:
	static Client &get();
	bool hasConfig() const;
	bool isEventUsed(std::string_view) const;
	bool sendEventAlways(std::string, const std::function<json()> &, SendEventOptions);
	void registerEventObserver(std::weak_ptr<EventObserver>);
	void registerConfigurationObserver(std::weak_ptr<ConfigurationObserver>);
	void registerErrorHandler(std::function<void(const std::string &)> &&);
	void sendExitBarrierWithTimeoutSync(unsigned);
	bool sendXpcMessage(xpc_object_t *, uint8_t, bool, bool)
	    SYM("_ZN13CoreAnalytics6Client14sendXpcMessageERKN10applesauce3xpc4dictE18XPCMessagePrioritybb");
	void handleSinkMessageEmit_sync(xpc_object_t *)
	    SYM("_ZN13CoreAnalytics6Client26handleSinkMessageEmit_syncERKN10applesauce3xpc4dictE");
	void handleServerMessage_sync(xpc_object_t *)
	    SYM("_ZN13CoreAnalytics6Client24handleServerMessage_syncERKN10applesauce3xpc4dictE");
	void handleConfigurationChange_sync(xpc_object_t *)
	    SYM("_ZN13CoreAnalytics6Client30handleConfigurationChange_syncERKN10applesauce3xpc4dictE");
	xpc_result sendManagementCommandWithReply(std::string, xpc_object_t *) const
	    SYM("_ZNK13CoreAnalytics6Client30sendManagementCommandWithReplyENSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEEN10applesauce3xpc4dictE");
};
}
using namespace CoreAnalytics;

bool analytics_tool_has_config();
std::string analytics_tool_log_dump(ostr);
std::string analytics_tool_log_transform_counts();
std::string analytics_tool_config_list();
std::string analytics_tool_config_info();
std::string analytics_tool_config_dump();
std::string analytics_tool_query_list();
std::string analytics_tool_transform_info(std::string);
std::string analytics_tool_get_cache_list();
std::string analytics_tool_app_usage_sync();
bool analytics_tool_config_set_tasking(std::string);
bool analytics_tool_transform_evict(std::string);
bool analytics_tool_transform_persist(std::string);
bool analytics_tool_is_event_used_check_db(std::string);
void analytics_tool_config_reload();
void analytics_tool_config_set_reboot_clear(bool);
void analytics_tool_query_clear(ostr);
void analytics_tool_save();
void analytics_tool_commit();
bool analytics_tool_rollover(ostr, bool);
std::string query_state(std::string, xpc_object_t *)
    SYM("_Z26analytics_tool_query_stateNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEN10applesauce3xpc6objectE");
void insert_query_state(std::string, xpc_object_t *, xpc_object_t *)
    SYM("_Z33analytics_tool_insert_query_stateNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEN10applesauce3xpc6objectES8_");
struct tasking_pair {
	xpc_object_t config;
	unsigned long size;
};
bool set_tasking_ndjson(const tasking_pair &)
    SYM("_Z40analytics_tool_config_set_tasking_ndjsonRKNSt3__14pairIN10applesauce3xpc6objectEmEE");

static void str(const std::string &v) { printf("-> \"%s\"\n", v.c_str()); }
static void flag(bool v) { printf("-> %s\n", v ? "true" : "false"); }
static void none() { puts("-> void"); }

static int
tool(const char *t)
{
	xpc_object_t params = xpc_string_create("params"), state = xpc_int64_create(4);
	try {
		if (!strcmp(t, "has_config")) flag(analytics_tool_has_config());
		else if (!strcmp(t, "log_dump")) str(analytics_tool_log_dump(std::string("Daily")));
		else if (!strcmp(t, "log_dump0")) str(analytics_tool_log_dump(std::nullopt));
		else if (!strcmp(t, "log_transform_counts")) str(analytics_tool_log_transform_counts());
		else if (!strcmp(t, "config_list")) str(analytics_tool_config_list());
		else if (!strcmp(t, "config_info")) str(analytics_tool_config_info());
		else if (!strcmp(t, "config_dump")) str(analytics_tool_config_dump());
		else if (!strcmp(t, "query_list")) str(analytics_tool_query_list());
		else if (!strcmp(t, "transform_info")) str(analytics_tool_transform_info("tx"));
		else if (!strcmp(t, "get_cache_list")) str(analytics_tool_get_cache_list());
		else if (!strcmp(t, "app_usage_sync")) str(analytics_tool_app_usage_sync());
		else if (!strcmp(t, "query_state")) str(query_state("qs", &params));
		else if (!strcmp(t, "set_tasking")) flag(analytics_tool_config_set_tasking("cfg"));
		else if (!strcmp(t, "set_tasking_ndjson")) flag(set_tasking_ndjson({ state, 42 }));
		else if (!strcmp(t, "transform_evict")) flag(analytics_tool_transform_evict("tx"));
		else if (!strcmp(t, "transform_persist")) flag(analytics_tool_transform_persist("tx"));
		else if (!strcmp(t, "is_event_used")) flag(analytics_tool_is_event_used_check_db("ev"));
		else if (!strcmp(t, "config_reload")) { analytics_tool_config_reload(); none(); }
		else if (!strcmp(t, "reboot_clear")) { analytics_tool_config_set_reboot_clear(true); none(); }
		else if (!strcmp(t, "query_clear")) { analytics_tool_query_clear(std::string("qs")); none(); }
		else if (!strcmp(t, "query_clear0")) { analytics_tool_query_clear(std::nullopt); none(); }
		else if (!strcmp(t, "insert_query_state")) { insert_query_state("qs", &state, &params); none(); }
		else if (!strcmp(t, "save")) { analytics_tool_save(); none(); }
		else if (!strcmp(t, "commit")) { analytics_tool_commit(); none(); }
		else if (!strcmp(t, "rollover")) flag(analytics_tool_rollover(std::string("Daily"), true));
		else { fprintf(stderr, "unknown tool %s\n", t); return 2; }
	} catch (const std::exception &e) {
		printf("threw: %s\n", e.what());
	}
	return 0;
}

/* --- JSON values in nlohmann's layout ------------------------------------ */

template <typename F>
static json
make(jt type, F fill)
{
	json j;
	j.m_type = type;
	fill(j);
	return j;
}
static json S(const char *s) { return make(jt::string, [&](json &j) { j.m_value.string = new std::string(s); }); }
static json I(long long v) { return make(jt::number_integer, [&](json &j) { j.m_value.number_integer = v; }); }
static json U(unsigned long long v) { return make(jt::number_unsigned, [&](json &j) { j.m_value.number_unsigned = v; }); }
static json D(double v) { return make(jt::number_float, [&](json &j) { j.m_value.number_float = v; }); }
static json B(bool v) { return make(jt::boolean, [&](json &j) { j.m_value.boolean = v; }); }
static json O() { return make(jt::object, [](json &j) { j.m_value.object = new json::object_t; }); }
static json A() { return make(jt::array, [](json &j) { j.m_value.array = new json::array_t; }); }

static void
show(const json &j)
{
	bool first = true;
	switch (j.m_type) {
	case jt::object:
		printf("{");
		for (const auto &kv : *j.m_value.object) {
			printf("%s%s:", first ? "" : ",", kv.first.c_str());
			show(kv.second);
			first = false;
		}
		printf("}");
		break;
	case jt::array:
		printf("[");
		for (const json &v : *j.m_value.array) {
			printf(first ? "" : ",");
			show(v);
			first = false;
		}
		printf("]");
		break;
	case jt::string: printf("s'%s'", j.m_value.string->c_str()); break;
	case jt::boolean: printf("b%d", j.m_value.boolean); break;
	case jt::number_integer: printf("i%lld", j.m_value.number_integer); break;
	case jt::number_unsigned: printf("u%llu", j.m_value.number_unsigned); break;
	case jt::number_float: printf("d%.17g", j.m_value.number_float); break;
	case jt::null: printf("null"); break;
	default: printf("type%d", (int)j.m_type);
	}
}

struct EventPrinter : EventObserver {
	const char *tag;
	void notifyMessageEmitted(json j) override
	{
		printf("event observer %s: ", tag);
		show(j);
		printf("\n");
	}
};

static int
client()
{
	Client &c = Client::get();
	bool ok = c.sendEventAlways("com.test.cxx", [] {
		json o = O();
		auto &m = *o.m_value.object;
		m.emplace("b", B(true));
		m.emplace("n", I(-3));
		m.emplace("u", U(18446744073709551615ull));
		m.emplace("d", D(0.1));
		m.emplace("s", S("hi \"x\"\n\xc3\xa9"));
		m.emplace("z", json());
		json a = A();
		a.m_value.array->push_back(I(1));
		a.m_value.array->push_back(S("two"));
		a.m_value.array->push_back(D(1e21));
		m.emplace("a", std::move(a));
		json in = O();
		in.m_value.object->emplace("k", U(5));
		m.emplace("o", std::move(in));
		return o;
	}, { 1, 1, false });
	printf("sendEventAlways(object) -> %d\n", ok);
	printf("sendEventAlways(array) -> %d\n", c.sendEventAlways("com.test.cxx2", [] { return A(); }, { 0, 0, true }));

	xpc_object_t d = xpc_dictionary_create_empty();
	xpc_dictionary_set_string(d, "command", "test-msg");
	xpc_dictionary_set_int64(d, "k", 9);
	printf("sendXpcMessage -> %d\n", c.sendXpcMessage(&d, 0, false, false));

	xpc_object_t args = xpc_dictionary_create_empty();
	xpc_dictionary_set_string(args, "name", "x");
	xpc_result r = c.sendManagementCommandWithReply("config-info", &args);
	printf("sendManagementCommandWithReply -> %s count=%zu, args command=%s\n",
	    xpc_type_get_name(xpc_get_type(r.o)),
	    xpc_get_type(r.o) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_count(r.o) : 0,
	    xpc_dictionary_get_string(args, "command"));

	auto one = std::make_shared<EventPrinter>(), two = std::make_shared<EventPrinter>();
	one->tag = "one";
	two->tag = "two";
	c.registerEventObserver(one);
	c.registerEventObserver(two);
	two.reset();	/* expired observers are skipped */
	xpc_object_t m = xpc_dictionary_create_empty();
	xpc_dictionary_set_string(m, "notification", "message-emit");
	xpc_dictionary_set_string(m, "message",
	    "{\"x\":1,\"neg\":-2,\"y\":[true,1.5,\"s\",null],\"big\":18446744073709551615,\"o\":{}}");
	c.handleSinkMessageEmit_sync(&m);
	c.handleServerMessage_sync(&m);
	xpc_dictionary_set_string(m, "message", "[1,2]");	/* not an object: ignored */
	c.handleSinkMessageEmit_sync(&m);
	sleep(1);	/* let the sends reach the fake daemon */
	return 0;
}

struct ConfigPrinter : ConfigurationObserver {
	const char *tag;
	void notifyConfigurationActivated(const FrameworkConfiguration &) override
	{
		printf("config observer %s called\n", tag);
	}
};

static int
config()
{
	Client &c = Client::get();
	auto a = std::make_shared<ConfigPrinter>();
	a->tag = "A";
	c.registerConfigurationObserver(a);
	printf("before: hasConfig=%d used(other)=%d\n", c.hasConfig(), c.isEventUsed("com.test.other"));

	/* A one-event framework configuration. */
	const char *name = "com.test.used";
	void *blob = mmap(NULL, 4096, PROT_READ | PROT_WRITE, MAP_ANON | MAP_SHARED, -1, 0);
	uint32_t *h = (uint32_t *)blob;
	h[0] = 0xF09116A8;	/* magic */
	h[1] = 1;		/* version */
	h[2] = 1;		/* event count */
	h[6] = 64;		/* offset of the first name */
	strcpy((char *)blob + 64, name);
	h[5] = 64 + (uint32_t)strlen(name) + 1;	/* end of the framework section */
	h[3] = h[5] + 1;	/* no external configuration */
	xpc_object_t m = xpc_dictionary_create_empty();
	xpc_dictionary_set_string(m, "notification", "configuration-change");
	xpc_dictionary_set_value(m, "configuration", xpc_shmem_create(blob, 4096));
	xpc_dictionary_set_uint64(m, "configuration-size", 4096);
	c.handleConfigurationChange_sync(&m);
	printf("after: hasConfig=%d used(used)=%d used(other)=%d\n", c.hasConfig(),
	    c.isEventUsed("com.test.used"), c.isEventUsed("com.test.other"));

	auto b = std::make_shared<ConfigPrinter>();
	b->tag = "B";
	c.registerConfigurationObserver(b);	/* notified at once */
	a.reset();
	c.handleConfigurationChange_sync(&m);
	return 0;
}

static int
error()
{
	Client &c = Client::get();
	c.registerErrorHandler([](const std::string &d) {
		printf("error handler: '%s'\n", d.c_str());
		fflush(stdout);
	});
	c.sendExitBarrierWithTimeoutSync(300);	/* cancels: "Connection invalid" */
	sleep(1);
	printf("after barrier\n");
	c.registerErrorHandler(std::function<void(const std::string &)>());
	return 0;
}

int
main(int argc, char **argv)
{
	setvbuf(stdout, NULL, _IOLBF, 0);
	if (argc == 3 && !strcmp(argv[1], "tool")) return tool(argv[2]);
	if (argc == 2 && !strcmp(argv[1], "client")) return client();
	if (argc == 2 && !strcmp(argv[1], "config")) return config();
	if (argc == 2 && !strcmp(argv[1], "error")) return error();
	fprintf(stderr, "usage: cxx_driver tool <name> | client | config | error\n");
	return 2;
}
