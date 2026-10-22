import Foundation

/// The output device a rule targets. Stored by UID; the name is for display and search (SPEC §6).
public struct DeviceRef: Codable, Hashable, Sendable {
    public var uid: String
    public var name: String

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// One saved route: an app (and its helpers) → a device (SPEC §8).
public struct RouteRule: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var enabled: Bool
    public var app: AppRule
    public var device: DeviceRef
    public var volume: Float

    public init(id: UUID = UUID(), enabled: Bool = true, app: AppRule, device: DeviceRef, volume: Float = 1) {
        self.id = id
        self.enabled = enabled
        self.app = app
        self.device = device
        self.volume = volume
    }
}

public struct RouteConfig: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var routes: [RouteRule]

    public init(version: Int = RouteConfig.currentVersion, routes: [RouteRule] = []) {
        self.version = version
        self.routes = routes
    }

    /// v1 allows one output per app (SPEC §8.1).
    public func validate() throws(ConfigError) {
        var seen = Set<String>()
        for rule in routes {
            let key = rule.app.bundleID.lowercased()
            guard seen.insert(key).inserted else { throw .duplicateApp(rule.app.bundleID) }
        }
    }

    public func rule(forBundleID bundleID: String) -> RouteRule? {
        routes.first { $0.app.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame }
    }

    /// Adds `rule`, or replaces the existing rule for the same app while keeping its ID.
    public mutating func upsert(_ rule: RouteRule) {
        if let index = routes.firstIndex(where: { $0.app.bundleID.caseInsensitiveCompare(rule.app.bundleID) == .orderedSame }) {
            var replacement = rule
            replacement.id = routes[index].id
            routes[index] = replacement
        } else {
            routes.append(rule)
        }
    }

    /// Returns the removed rule, if any.
    @discardableResult
    public mutating func remove(bundleID: String) -> RouteRule? {
        guard let index = routes.firstIndex(where: { $0.app.bundleID.caseInsensitiveCompare(bundleID) == .orderedSame })
        else { return nil }
        return routes.remove(at: index)
    }
}

public enum ConfigError: Error, CustomStringConvertible, Sendable {
    case duplicateApp(String)
    case readOnly(version: Int)
    case unreadable(String)

    public var description: String {
        switch self {
        case .duplicateApp(let id): "설정에 같은 앱(\(id))의 규칙이 여러 개 있습니다. 앱마다 규칙은 하나만 둘 수 있습니다."
        case .readOnly(let version): "설정 파일 버전(\(version))을 알 수 없어 읽기 전용으로 열었습니다. 저장하지 않습니다."
        case .unreadable(let reason): "설정 파일을 읽을 수 없습니다: \(reason)"
        }
    }
}

public struct LoadedConfig: Sendable {
    public var config: RouteConfig
    /// Set when the file has an unknown `version`; such a file is never overwritten (SPEC §8.1).
    public var isReadOnly: Bool
}

/// Reads and writes `routes.json`. Writes go to a temporary file that atomically replaces the original.
public struct ConfigStore: Sendable {
    public let url: URL

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SoundLanes", isDirectory: true)
    }

    public init(url: URL = ConfigStore.defaultDirectory.appendingPathComponent("routes.json")) {
        self.url = url
    }

    /// A missing file is an empty configuration.
    public func load() throws(ConfigError) -> LoadedConfig {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return LoadedConfig(config: RouteConfig(), isReadOnly: false)
        } catch {
            throw .unreadable(error.localizedDescription)
        }
        struct VersionOnly: Decodable { let version: Int }
        let version: Int
        do {
            version = try JSONDecoder().decode(VersionOnly.self, from: data).version
        } catch {
            throw .unreadable(String(describing: error))
        }
        guard version == RouteConfig.currentVersion else {
            // Best effort: show what we can, never write.
            let config = (try? JSONDecoder().decode(RouteConfig.self, from: data)) ?? RouteConfig(version: version)
            return LoadedConfig(config: config, isReadOnly: true)
        }
        let config: RouteConfig
        do {
            config = try JSONDecoder().decode(RouteConfig.self, from: data)
        } catch {
            throw .unreadable(String(describing: error))
        }
        try config.validate()
        return LoadedConfig(config: config, isReadOnly: false)
    }

    public func save(_ config: RouteConfig) throws(ConfigError) {
        guard config.version == RouteConfig.currentVersion else { throw .readOnly(version: config.version) }
        try config.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(config).write(to: url, options: .atomic)
        } catch {
            throw .unreadable(error.localizedDescription)
        }
    }
}
