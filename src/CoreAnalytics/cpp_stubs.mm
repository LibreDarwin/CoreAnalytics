// C++ Client milestone.
// Copyright (C) 2026, LibreDarwin
// SPDX-License-Identifier: BSD-3-Clause

#include "ca_internal.h"
#include <string_view>

namespace CoreAnalytics {
class EventObserver { public: virtual ~EventObserver(); virtual void notifyMessageEmitted(const std::string &) = 0; };
class ConfigurationObserver { public: virtual ~ConfigurationObserver(); virtual void notifyConfigurationActivated(const void *) = 0; };
class Client {
public:
    Client();
    static Client &get();
    bool hasConfig() const;
    bool isEventUsed(std::string_view name) const;
    void allowAllEvents();
};
}

CoreAnalytics::EventObserver::~EventObserver() {}
CoreAnalytics::ConfigurationObserver::~ConfigurationObserver() {}
CoreAnalytics::Client::Client() {}
CoreAnalytics::Client &CoreAnalytics::Client::get() { static CoreAnalytics::Client instance; return instance; }
bool CoreAnalytics::Client::hasConfig() const { return ca_client_has_config(); }
bool CoreAnalytics::Client::isEventUsed(std::string_view name) const { return ca_client_is_event_used(name.data(), name.size()); }
void CoreAnalytics::Client::allowAllEvents() { ca_client_allow_all_events(); }

void CASPIEnter(void) { ca_enter(); }

bool analytics_tool_has_config(void) { return ca_client_has_config(); }

extern "C" void __Z19analytics_tool_savev(void) __asm__("__Z19analytics_tool_savev");
void __Z19analytics_tool_savev(void) {}

extern "C" void __Z21analytics_tool_commitv(void) __asm__("__Z21analytics_tool_commitv");
void __Z21analytics_tool_commitv(void) {}

extern "C" void __Z23analytics_tool_log_dumpNSt3__18optionalINS_12basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEEE(void) __asm__("__Z23analytics_tool_log_dumpNSt3__18optionalINS_12basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEEE");
void __Z23analytics_tool_log_dumpNSt3__18optionalINS_12basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEEE(void) {}

extern "C" void __Z23analytics_tool_rolloverNSt3__18optionalINS_12basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEEEb(void) __asm__("__Z23analytics_tool_rolloverNSt3__18optionalINS_12basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEEEb");
void __Z23analytics_tool_rolloverNSt3__18optionalINS_12basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEEEb(void) {}

extern "C" void __Z25analytics_tool_query_listv(void) __asm__("__Z25analytics_tool_query_listv");
void __Z25analytics_tool_query_listv(void) {}

extern "C" void __Z26analytics_tool_config_dumpv(void) __asm__("__Z26analytics_tool_config_dumpv");
void __Z26analytics_tool_config_dumpv(void) {}

extern "C" void __Z26analytics_tool_config_infov(void) __asm__("__Z26analytics_tool_config_infov");
void __Z26analytics_tool_config_infov(void) {}


extern "C" void __Z26analytics_tool_query_clearNSt3__18optionalINS_12basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEEE(void) __asm__("__Z26analytics_tool_query_clearNSt3__18optionalINS_12basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEEE");
void __Z26analytics_tool_query_clearNSt3__18optionalINS_12basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEEE(void) {}

extern "C" void __Z26analytics_tool_query_stateNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEN10applesauce3xpc6objectE(void) __asm__("__Z26analytics_tool_query_stateNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEN10applesauce3xpc6objectE");
void __Z26analytics_tool_query_stateNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEN10applesauce3xpc6objectE(void) {}

extern "C" void __Z28analytics_tool_config_reloadv(void) __asm__("__Z28analytics_tool_config_reloadv");
void __Z28analytics_tool_config_reloadv(void) {}

extern "C" void __Z29analytics_tool_app_usage_syncv(void) __asm__("__Z29analytics_tool_app_usage_syncv");
void __Z29analytics_tool_app_usage_syncv(void) {}

extern "C" void __Z29analytics_tool_get_cache_listv(void) __asm__("__Z29analytics_tool_get_cache_listv");
void __Z29analytics_tool_get_cache_listv(void) {}

extern "C" void __Z29analytics_tool_transform_infoNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEE(void) __asm__("__Z29analytics_tool_transform_infoNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEE");
void __Z29analytics_tool_transform_infoNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEE(void) {}

extern "C" void __Z30analytics_tool_transform_evictNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEE(void) __asm__("__Z30analytics_tool_transform_evictNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEE");
void __Z30analytics_tool_transform_evictNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEE(void) {}

extern "C" void __Z32analytics_tool_transform_persistNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEE(void) __asm__("__Z32analytics_tool_transform_persistNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEE");
void __Z32analytics_tool_transform_persistNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEE(void) {}

extern "C" void __Z33analytics_tool_config_set_taskingNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEE(void) __asm__("__Z33analytics_tool_config_set_taskingNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEE");
void __Z33analytics_tool_config_set_taskingNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEE(void) {}

extern "C" void __Z33analytics_tool_insert_query_stateNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEN10applesauce3xpc6objectES8_(void) __asm__("__Z33analytics_tool_insert_query_stateNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEN10applesauce3xpc6objectES8_");
void __Z33analytics_tool_insert_query_stateNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEEN10applesauce3xpc6objectES8_(void) {}

extern "C" void __Z35analytics_tool_log_transform_countsv(void) __asm__("__Z35analytics_tool_log_transform_countsv");
void __Z35analytics_tool_log_transform_countsv(void) {}

extern "C" void __Z37analytics_tool_is_event_used_check_dbNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEE(void) __asm__("__Z37analytics_tool_is_event_used_check_dbNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEE");
void __Z37analytics_tool_is_event_used_check_dbNSt3__112basic_stringIcNS_11char_traitsIcEENS_9allocatorIcEEEE(void) {}

extern "C" void __Z38analytics_tool_config_set_reboot_clearb(void) __asm__("__Z38analytics_tool_config_set_reboot_clearb");
void __Z38analytics_tool_config_set_reboot_clearb(void) {}

extern "C" void __Z40analytics_tool_config_set_tasking_ndjsonRKNSt3__14pairIN10applesauce3xpc6objectEmEE(void) __asm__("__Z40analytics_tool_config_set_tasking_ndjsonRKNSt3__14pairIN10applesauce3xpc6objectEmEE");
void __Z40analytics_tool_config_set_tasking_ndjsonRKNSt3__14pairIN10applesauce3xpc6objectEmEE(void) {}


extern "C" void __ZN13CoreAnalytics6Client14initConnectionEv(void) __asm__("__ZN13CoreAnalytics6Client14initConnectionEv");
void __ZN13CoreAnalytics6Client14initConnectionEv(void) {}

extern "C" void __ZN13CoreAnalytics6Client14sendXpcMessageERKN10applesauce3xpc4dictE18XPCMessagePrioritybb(void) __asm__("__ZN13CoreAnalytics6Client14sendXpcMessageERKN10applesauce3xpc4dictE18XPCMessagePrioritybb");
void __ZN13CoreAnalytics6Client14sendXpcMessageERKN10applesauce3xpc4dictE18XPCMessagePrioritybb(void) {}

extern "C" void __ZN13CoreAnalytics6Client15sendEventAlwaysENSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEERKNS1_8functionIFN8nlohmann10basic_jsonINS1_3mapENS1_6vectorES7_bxydS5_NS9_14adl_serializerENSC_IhNS5_IhEEEEEEvEEENS_16SendEventOptionsE(void) __asm__("__ZN13CoreAnalytics6Client15sendEventAlwaysENSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEERKNS1_8functionIFN8nlohmann10basic_jsonINS1_3mapENS1_6vectorES7_bxydS5_NS9_14adl_serializerENSC_IhNS5_IhEEEEEEvEEENS_16SendEventOptionsE");
void __ZN13CoreAnalytics6Client15sendEventAlwaysENSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEERKNS1_8functionIFN8nlohmann10basic_jsonINS1_3mapENS1_6vectorES7_bxydS5_NS9_14adl_serializerENSC_IhNS5_IhEEEEEEvEEENS_16SendEventOptionsE(void) {}

extern "C" void __ZN13CoreAnalytics6Client17updateDaemonStateEi(void) __asm__("__ZN13CoreAnalytics6Client17updateDaemonStateEi");
void __ZN13CoreAnalytics6Client17updateDaemonStateEi(void) {}

extern "C" void __ZN13CoreAnalytics6Client19sendXpcMessage_syncEN10applesauce3xpc4dictE18XPCMessagePrioritybb(void) __asm__("__ZN13CoreAnalytics6Client19sendXpcMessage_syncEN10applesauce3xpc4dictE18XPCMessagePrioritybb");
void __ZN13CoreAnalytics6Client19sendXpcMessage_syncEN10applesauce3xpc4dictE18XPCMessagePrioritybb(void) {}

extern "C" void __ZN13CoreAnalytics6Client20registerErrorHandlerEONSt3__18functionIFvRKNS1_12basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEEEEE(void) __asm__("__ZN13CoreAnalytics6Client20registerErrorHandlerEONSt3__18functionIFvRKNS1_12basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEEEEE");
void __ZN13CoreAnalytics6Client20registerErrorHandlerEONSt3__18functionIFvRKNS1_12basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEEEEE(void) {}

extern "C" void __ZN13CoreAnalytics6Client20retryXpcMessage_syncERKN10applesauce3xpc4dictE18XPCMessagePriorityb(void) __asm__("__ZN13CoreAnalytics6Client20retryXpcMessage_syncERKN10applesauce3xpc4dictE18XPCMessagePriorityb");
void __ZN13CoreAnalytics6Client20retryXpcMessage_syncERKN10applesauce3xpc4dictE18XPCMessagePriorityb(void) {}

extern "C" void __ZN13CoreAnalytics6Client21cancelConnection_syncEv(void) __asm__("__ZN13CoreAnalytics6Client21cancelConnection_syncEv");
void __ZN13CoreAnalytics6Client21cancelConnection_syncEv(void) {}

extern "C" void __ZN13CoreAnalytics6Client22acquireSendTransactionEv(void) __asm__("__ZN13CoreAnalytics6Client22acquireSendTransactionEv");
void __ZN13CoreAnalytics6Client22acquireSendTransactionEv(void) {}

extern "C" void __ZN13CoreAnalytics6Client22releaseSendTransactionEv(void) __asm__("__ZN13CoreAnalytics6Client22releaseSendTransactionEv");
void __ZN13CoreAnalytics6Client22releaseSendTransactionEv(void) {}

extern "C" void __ZN13CoreAnalytics6Client23sendCheckinMessage_syncEv(void) __asm__("__ZN13CoreAnalytics6Client23sendCheckinMessage_syncEv");
void __ZN13CoreAnalytics6Client23sendCheckinMessage_syncEv(void) {}

extern "C" void __ZN13CoreAnalytics6Client24handleServerMessage_syncERKN10applesauce3xpc4dictE(void) __asm__("__ZN13CoreAnalytics6Client24handleServerMessage_syncERKN10applesauce3xpc4dictE");
void __ZN13CoreAnalytics6Client24handleServerMessage_syncERKN10applesauce3xpc4dictE(void) {}

extern "C" void __ZN13CoreAnalytics6Client26handleSinkMessageEmit_syncERKN10applesauce3xpc4dictE(void) __asm__("__ZN13CoreAnalytics6Client26handleSinkMessageEmit_syncERKN10applesauce3xpc4dictE");
void __ZN13CoreAnalytics6Client26handleSinkMessageEmit_syncERKN10applesauce3xpc4dictE(void) {}

extern "C" void __ZN13CoreAnalytics6Client26retryXpcMessageHelper_syncEN10applesauce3xpc4dictE18XPCMessagePrioritybhy(void) __asm__("__ZN13CoreAnalytics6Client26retryXpcMessageHelper_syncEN10applesauce3xpc4dictE18XPCMessagePrioritybhy");
void __ZN13CoreAnalytics6Client26retryXpcMessageHelper_syncEN10applesauce3xpc4dictE18XPCMessagePrioritybhy(void) {}

extern "C" void __ZN13CoreAnalytics6Client30handleConfigurationChange_syncERKN10applesauce3xpc4dictE(void) __asm__("__ZN13CoreAnalytics6Client30handleConfigurationChange_syncERKN10applesauce3xpc4dictE");
void __ZN13CoreAnalytics6Client30handleConfigurationChange_syncERKN10applesauce3xpc4dictE(void) {}

extern "C" void __ZN13CoreAnalytics6Client30sendExitBarrierWithTimeoutSyncEj(void) __asm__("__ZN13CoreAnalytics6Client30sendExitBarrierWithTimeoutSyncEj");
void __ZN13CoreAnalytics6Client30sendExitBarrierWithTimeoutSyncEj(void) {}

extern "C" void __ZN13CoreAnalytics6Client4initEv(void) __asm__("__ZN13CoreAnalytics6Client4initEv");
void __ZN13CoreAnalytics6Client4initEv(void) {}

extern "C" void __ZNK13CoreAnalytics6Client30sendManagementCommandWithReplyENSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEEN10applesauce3xpc4dictE(void) __asm__("__ZNK13CoreAnalytics6Client30sendManagementCommandWithReplyENSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEEN10applesauce3xpc4dictE");
void __ZNK13CoreAnalytics6Client30sendManagementCommandWithReplyENSt3__112basic_stringIcNS1_11char_traitsIcEENS1_9allocatorIcEEEEN10applesauce3xpc4dictE(void) {}


extern "C" void __ZN13CoreAnalytics6Client21registerEventObserverENSt3__18weak_ptrINS_13EventObserverEEE(void) __asm__("__ZN13CoreAnalytics6Client21registerEventObserverENSt3__18weak_ptrINS_13EventObserverEEE");
void __ZN13CoreAnalytics6Client21registerEventObserverENSt3__18weak_ptrINS_13EventObserverEEE(void) {}

extern "C" void __ZN13CoreAnalytics6Client29registerConfigurationObserverENSt3__18weak_ptrINS_21ConfigurationObserverEEE(void) __asm__("__ZN13CoreAnalytics6Client29registerConfigurationObserverENSt3__18weak_ptrINS_21ConfigurationObserverEEE");
void __ZN13CoreAnalytics6Client29registerConfigurationObserverENSt3__18weak_ptrINS_21ConfigurationObserverEEE(void) {}

#include <stdexcept>
#include <string>
static void append_tabs_ap(std::string &s, int depth) {
    for (int i = 0; i < depth; i++) s.push_back('\t');
}

static void applesauce_fmt(xpc_object_t obj, std::string &out, int depth);

static void applesauce_fmt_array(xpc_object_t arr, std::string &out, int depth) {
    out.push_back('[');
    size_t count = xpc_array_get_count(arr);
    if (count == 0) {
        out.push_back(']');
        return;
    }
    out.push_back('\n');
    for (size_t i = 0; i < count; i++) {
        if (i > 0) {
            out.push_back(',');
            out.push_back('\n');
        }
        append_tabs_ap(out, depth + 1);
        out += std::to_string(i);
        out.append(": ");
        applesauce_fmt(xpc_array_get_value(arr, i), out, depth + 1);
    }
    out.push_back('\n');
    append_tabs_ap(out, depth);
    out.push_back(']');
}

static void applesauce_fmt_dict(xpc_object_t dict, std::string &out, int depth) {
    out.push_back('{');
    size_t count = xpc_dictionary_get_count(dict);
    if (count == 0) {
        out.push_back('}');
        return;
    }
    out.push_back('\n');
    __block size_t idx = 0;
    xpc_dictionary_apply(dict, ^bool(const char *key, xpc_object_t value) {
        if (idx > 0) {
            out.push_back(',');
            out.push_back('\n');
        }
        append_tabs_ap(out, depth + 1);
        out.push_back('"');
        out.append(key);
        out.push_back('"');
        out.append(": ");
        applesauce_fmt(value, out, depth + 1);
        idx++;
        return true;
    });
    out.push_back('\n');
    append_tabs_ap(out, depth);
    out.push_back('}');
}

static void applesauce_fmt(xpc_object_t obj, std::string &out, int depth) {
    xpc_type_t type = xpc_get_type(obj);
    if (type == XPC_TYPE_DICTIONARY) {
        applesauce_fmt_dict(obj, out, depth);
        return;
    } else if (type == XPC_TYPE_ARRAY) {
        applesauce_fmt_array(obj, out, depth);
        return;
    } else if (type == XPC_TYPE_STRING) {
        out.push_back('"');
        const char *s = xpc_string_get_string_ptr(obj);
        size_t len = xpc_string_get_length(obj);
        out.append(s, len);
        out.push_back('"');
        return;
    } else if (type == XPC_TYPE_INT64) {
        out += std::to_string(xpc_int64_get_value(obj));
        return;
    } else if (type == XPC_TYPE_UINT64) {
        out += std::to_string(xpc_uint64_get_value(obj));
        out.push_back('u');
        return;
    } else if (type == XPC_TYPE_BOOL) {
        if (xpc_bool_get_value(obj)) {
            out.append("true");
        } else {
            out.append("false");
        }
        return;
    } else if (type == XPC_TYPE_DOUBLE) {
        out += std::to_string(xpc_double_get_value(obj));
        return;
    } else if (type == XPC_TYPE_NULL) {
        out.append("null");
        return;
    } else if (type == XPC_TYPE_DATE) {
        int64_t nanoseconds = xpc_date_get_value(obj);
        time_t seconds = nanoseconds / 1000000000LL;
        struct tm tm;
        gmtime_r(&seconds, &tm);
        char buf[64];
        strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S GMT", &tm);
        out.append(buf);
        return;
    } else if (type == XPC_TYPE_DATA) {
        size_t len = xpc_data_get_length(obj);
        const unsigned char *bytes = (const unsigned char *)xpc_data_get_bytes_ptr(obj);
        char tmp[40];
        snprintf(tmp, sizeof(tmp), "[%zu bytes]", len);
        out.append(tmp);
        if (len > 0 && bytes) {
            for (size_t i = 0; i < len; i++) {
                snprintf(tmp, sizeof(tmp), " %02x", bytes[i]);
                out.append(tmp);
            }
        }
        return;
    } else if (type == XPC_TYPE_UUID) {
        const uint8_t *bytes = xpc_uuid_get_bytes(obj);
        if (bytes) {
            uuid_t uuid;
            memcpy(uuid, bytes, 16);
            char uuid_str[37];
            uuid_unparse(uuid, uuid_str);
            out.append(uuid_str);
        } else {
            out.append("unknown");
        }
        return;
    } else if (type == XPC_TYPE_ERROR) {
        char *d = xpc_copy_description(obj);
        if (d) {
            if (strstr(d, "Connection invalid")) {
                out = "XPC_ERROR(Connection invalid)";
            } else {
                out = d;
            }
            free(d);
            return;
        }
        out.append("XPC_ERROR");
        return;
    } else {
        char *d = xpc_copy_description(obj);
        if (d) {
            out = d;
            free(d);
            return;
        }
        out.append("unknown");
        return;
    }
}

std::string analytics_tool_config_list() {
    xpc_object_t r = ca_client_mgmt("config-list", nullptr);
    if (r == NULL || xpc_get_type(r) != XPC_TYPE_DICTIONARY) {
        if (r != NULL && xpc_get_type(r) != XPC_TYPE_DICTIONARY)
            return "unknown";
        throw std::runtime_error("config-list failed");
    }
    if (xpc_dictionary_get_value(r, "error") != NULL)
        throw std::runtime_error("config-list failed");
    xpc_object_t clv = xpc_dictionary_get_value(r, "config-list");
    if (clv != NULL) {
        if (xpc_get_type(clv) == XPC_TYPE_STRING)
            return std::string(xpc_string_get_string_ptr(clv));
        return std::string("");
    }
    std::string out;
    applesauce_fmt(r, out, 0);
    return out;
}
