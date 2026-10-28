# LibreDarwin CoreAnalytics

Clean-room reimplementation of Apple's private `CoreAnalytics.framework`:
the client side of the `com.apple.analyticsd` telemetry service.

Implemented so far (37 exported symbols, see
`src/CoreAnalytics/CoreAnalytics.exp`):

- the public C API: `Analytics*` / `analytics_*` event submission and
  management calls plus the legacy `setObjectForKey` / `getObjectForKey` /
  `ad_addScalarForKey` / `report_locale_prefs_to_analyticsd` helpers;
- the `AnalyticsEventObserver` and `AnalyticsConfigurationObserver`
  classes.

Not yet: the C++ `CoreAnalytics::Client` exports, `analytics_tool_*` and
the Swift `QueryValuesFor`.

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
configuration (`notification: "configuration-change"`, magic `0xF09116A8`
v1) listing the events in use, followed by a JSON array of
`{"kind", "configuration"}` entries for configuration observers; unused
events are dropped before their payload is built.  Event observers
subscribe with `create-event-observer` and receive
`notification: "message-emit"` messages carrying JSON text.
