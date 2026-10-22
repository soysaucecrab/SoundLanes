import Foundation

/// Which processes belong to an app (SPEC §5).
public struct AppRule: Hashable, Sendable, Codable {
    public var bundleID: String
    /// Additional bundle IDs routed with the app, e.g. `com.apple.WebKit.GPU` for Safari.
    public var extraBundleIDs: [String]

    public init(bundleID: String, extraBundleIDs: [String] = []) {
        self.bundleID = bundleID
        self.extraBundleIDs = extraBundleIDs
    }
}

public enum AppMatcher {
    /// True if `processBundleID` equals one of the rule's IDs or is nested under it (`<id>.`).
    /// Processes without a bundle ID never match (SPEC §5.1).
    public static func matches(_ rule: AppRule, bundleID processBundleID: String) -> Bool {
        guard !processBundleID.isEmpty else { return false }
        let candidate = processBundleID.lowercased()
        return ([rule.bundleID] + rule.extraBundleIDs).contains { id in
            let id = id.lowercased()
            return !id.isEmpty && (candidate == id || candidate.hasPrefix(id + "."))
        }
    }

    public static func select(_ rule: AppRule, from processes: [AudioProcess]) -> [AudioProcess] {
        processes.filter { matches(rule, bundleID: $0.bundleID) }
    }
}

/// What a single route should look like given the current hardware state.
public enum RoutePlan: Equatable, Sendable {
    case inactive(InactiveReason)
    /// Tap exactly these process objects, sorted.
    case active(processes: [AudioObject])

    public enum InactiveReason: Equatable, Sendable {
        /// Target device is not connected (SPEC §6, S2).
        case deviceMissing
        /// Target device is already the default output, so no tap is needed (S6).
        case deviceIsDefault
        /// No running process matches the rule.
        case noProcesses
    }
}

public enum RoutePlanner {
    public static func plan(
        rule: AppRule,
        deviceUID: String,
        availableDeviceUIDs: Set<String>,
        defaultOutputUID: String?,
        processes: [AudioProcess]
    ) -> RoutePlan {
        guard availableDeviceUIDs.contains(deviceUID) else { return .inactive(.deviceMissing) }
        if defaultOutputUID == deviceUID { return .inactive(.deviceIsDefault) }
        let matched = AppMatcher.select(rule, from: processes).map(\.object).sorted { $0.id < $1.id }
        return matched.isEmpty ? .inactive(.noProcesses) : .active(processes: matched)
    }
}
