/*
 * AnalyticsQueryValuesFor(arguments:), the framework's one Swift export
 * (ReportCrash imports it).  Callers pass a set of query keys and get back
 * an XPC dictionary with one entry per answered key.
 *
 * Copyright (C) 2026, LibreDarwin
 * SPDX-License-Identifier: BSD-3-Clause
 */

import Foundation
import XPC
import os

private let logger = Logger(subsystem: "com.apple.analyticsagent-client", category: "xpc")

private enum QueryKey {
    case greymatter
    case localePrefsSubscribe
}

private let queryKeys: [String: QueryKey] = [
    "greymatter": .greymatter,
    "locale-prefs-subscribe": .localePrefsSubscribe,
]

/// Answers the requested keys from analyticsd's preference store.
/// "greymatter" yields `{availability, countryPolicy, reasons}` from the
/// stored "GreyMatterAvailable" value; "locale-prefs-subscribe" is accepted
/// but yields nothing; other keys are logged and skipped.
public func AnalyticsQueryValuesFor(arguments: NSSet) -> xpc_object_t {
    let result = xpc_dictionary_create_empty()
    guard let keys = arguments as? Set<String> else {
        logger.error("Invalid parameter type. Expected a set of strings.")
        return result
    }

    for key in keys {
        guard let kind = queryKeys[key] else {
            logger.error("Unexpected argument key: \(key)")
            continue
        }
        guard kind == .greymatter else {
            continue
        }
        guard let stored = getObjectForKey("GreyMatterAvailable"),
              xpc_get_type(stored) == XPC_TYPE_DICTIONARY else {
            logger.error("Unexpected object for key: \(key)")
            continue
        }

        let entry = xpc_dictionary_create_empty()
        if let availability = xpc_dictionary_get_string(stored, "availability") {
            xpc_dictionary_set_string(entry, "availability", String(cString: availability))
        } else {
            logger.error("Unable to unwrap availability string")
            xpc_dictionary_set_string(entry, "availability", "")
        }
        if let policy = xpc_dictionary_get_string(stored, "countryPolicy") {
            xpc_dictionary_set_string(entry, "countryPolicy", String(cString: policy))
        } else {
            logger.error("Unable to unwrap country policy string")
            xpc_dictionary_set_string(entry, "countryPolicy", "ROW")
        }
        xpc_dictionary_set_value(entry, "reasons", xpc_dictionary_get_array(stored, "reasons"))
        xpc_dictionary_set_value(result, key, entry)
    }
    return result
}
