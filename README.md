# LibreDarwin CoreAnalytics

Clean-room reimplementation of Apple's private `CoreAnalytics.framework`:
the client side of the `com.apple.analyticsd` telemetry service.

All 100 of Apple's exported symbols are implemented (see
`src/CoreAnalytics/CoreAnalytics.exp`):

- the public C API: `Analytics*` / `analytics_*` event submission and
  management calls plus the legacy `setObjectForKey` / `getObjectForKey` /
  `ad_addScalarForKey` / `report_locale_prefs_to_analyticsd` helpers;
- the `AnalyticsEventObserver` and `AnalyticsConfigurationObserver`
  classes;
- the Swift `AnalyticsQueryValuesFor(arguments:)` (built with `swiftc`
  as module `CoreAnalytics` so its mangled name matches);
- the C++ interface (`src/CoreAnalytics/client_cxx.mm`):
  `CoreAnalytics::Client`, the `EventObserver` / `ConfigurationObserver`
  base classes and the `analytics_tool_*` management helpers.  Nothing
  shipped in macOS imports them, but they behave like Apple's: Client
  methods forward to `client.m`, and JSON values cross the interface in
  nlohmann's object layout.

The framework is universal: arm64e (what system processes run), arm64 and
x86_64 (Intel Macs and Rosetta).

## Build

    make                  # build/release/CoreAnalytics.framework
    make CONFIG=debug
    make test             # all checks below, the parity tests on every slice
    xcodebuild -project CoreAnalytics.xcodeproj                         # same framework
    xcodebuild -project CoreAnalytics.xcodeproj -target exports-check

`make test` runs:

- `json-check`: the JSON writer and parser on their own;
- `exports-check`: every slice exports exactly
  `src/CoreAnalytics/CoreAnalytics.exp`, all of them Apple's symbols;
- `payload-parity`: event JSON byte for byte against Apple's framework;
- `cxx-parity`: the C++ interface against Apple's: every
  `analytics_tool_*` under 22 kinds of daemon reply, the text form of each
  XPC type, and Client sends, management calls, observers and the error
  handler.

The parity tests run in-process against Apple's framework and ours with
interposers standing in for analyticsd, so nothing reaches the daemon.  They
run once per slice: x86_64 under Rosetta, arm64e only with the
`-arm64e_preview_abi` boot-arg (required for any non-Apple arm64e code).

The framework keeps Apple's install name, so a binary built against either
copy loads Apple's by default and ours with

    DYLD_FRAMEWORK_PATH=build/release ./your-tool

## Wire protocol (as recovered)

Events go to analyticsd as `{command: "send", event, json, timestamp (µs
since epoch), priority, format}`; the payload is compact JSON with sorted
keys, laid out like nlohmann::json's `dump()` (numbers via a clean-room
Grisu2).  analyticsd may push a shared-memory
configuration (`notification: "configuration-change"`, magic `0xF09116A8`
v1) listing the events in use, followed by a JSON array of
`{"kind", "configuration"}` entries for configuration observers; unused
events are dropped before their payload is built.  Event observers
subscribe with `create-event-observer` and receive
`notification: "message-emit"` messages carrying JSON text.
