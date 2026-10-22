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

/// Known special cases (SPEC §5.2).
public enum AppPresets {
    /// Safari plays through the shared WebKit GPU process.
    public static let webKitGPU = "com.apple.WebKit.GPU"

    private static let callApps: Set<String> = [
        "com.apple.FaceTime", "us.zoom.xos", "com.microsoft.teams2", "com.microsoft.teams", "com.cisco.webexmeetingsapp",
    ]

    /// Extra bundle IDs routed together with `bundleID` by default.
    public static func defaultExtraBundleIDs(for bundleID: String) -> [String] {
        bundleID.caseInsensitiveCompare("com.apple.Safari") == .orderedSame ? [webKitGPU] : []
    }

    /// A user-facing caveat for this app, if any.
    public static func warning(for rule: AppRule) -> String? {
        let ids = ([rule.bundleID] + rule.extraBundleIDs).map { $0.lowercased() }
        if ids.contains(webKitGPU.lowercased()) {
            return "Safari는 공용 WebKit 프로세스로 소리를 내므로 다른 WebKit 앱의 소리도 함께 라우팅될 수 있습니다."
        }
        if callApps.contains(where: { $0.lowercased() == rule.bundleID.lowercased() }) {
            return "통화 앱은 출력 장치를 기준으로 에코를 제거하므로 라우팅하면 상대방에게 에코가 들릴 수 있습니다."
        }
        return nil
    }

    /// Friendlier name for processes that are not apps themselves.
    public static func displayName(for bundleID: String) -> String? {
        bundleID == webKitGPU ? "Safari 및 WebKit 앱" : nil
    }
}
