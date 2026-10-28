# LibreDarwin CoreAnalytics

Clean-room reimplementation of Apple's private `CoreAnalytics.framework`:
the client side of the `com.apple.analyticsd` telemetry service.

Implemented so far: the public C API (33 exported symbols, see
`src/CoreAnalytics/CoreAnalytics.exp`), i.e. the `Analytics*` /
`analytics_*` event submission and management calls plus the legacy
`setObjectForKey` / `getObjectForKey` / `ad_addScalarForKey` /
`report_locale_prefs_to_analyticsd` helpers.  Not yet: the C++
`CoreAnalytics::Client` exports, the `AnalyticsEventObserver` /
`AnalyticsConfigurationObserver` classes, `analytics_tool_*` and the Swift
`QueryValuesFor`.

## Build

    make                  # build/release/CoreAnalytics.framework
    make CONFIG=debug
    make test             # JSON writer checks + export parity with Apple's
    xcodebuild -project CoreAnalytics.xcodeproj -target exports-check

The framework keeps Apple's install name, so a binary built against either
copy loads Apple's by default and ours with

    DYLD_FRAMEWORK_PATH=build/release ./your-tool

## Wire protocol (as recovered)

Events go to analyticsd as `{command: "send", event, json, timestamp (µs
since epoch), priority, format}`; the payload is compact JSON with sorted
keys (nlohmann::json's `dump()`).  analyticsd may push a shared-memory
configuration (`notification: "configuration-change"`) listing the events
in use; others are dropped before their payload is built.
