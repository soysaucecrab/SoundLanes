import AppKit
import Observation
import os
import RouteCore

/// An app the user can route: one row in the menu.
struct AppItem: Identifiable, Hashable {
    var id: String { bundleID.lowercased() }
    let bundleID: String
    let name: String
    var isPlaying: Bool
}

/// State behind the menu bar UI. Owns the engine, the run lock and the control socket.
@MainActor @Observable
final class AppModel {
    enum Mode: Equatable {
        case starting
        case active
        /// Another runner (`soundlanes run`) holds the lock.
        case blocked(owner: String)
        case failed(String)
    }

    private(set) var mode = Mode.starting
    private(set) var config = RouteConfig()
    private(set) var isReadOnly = false
    private(set) var devices: [OutputDevice] = []
    private(set) var statuses: [UUID: RouteStatus] = [:]
    private var processes: [AudioProcess] = []
    var showAllApps = false
    var lastError: String?

    private let store = ConfigStore()
    private let system = CoreAudioSystem()
    private var engine: RouteEngine?
    private var lock: InstanceLock?
    private var server: ControlServer?
    private var eventsTask: Task<Void, Never>?
    private let log = Logger(subsystem: "com.zinu.soundlanes", category: "App")
    private static let ownerName = "SoundLanes 앱"

    var isRouting: Bool { statuses.values.contains { $0.phase == .running } }
    var needsPermission: Bool { statuses.values.contains { $0.phase == .noPermission } }

    // MARK: Lifecycle

    func start() async {
        guard mode != .active else { return }
        do {
            guard let lock = try InstanceLock.acquire(owner: Self.ownerName) else {
                mode = .blocked(owner: InstanceLock.currentOwner() ?? "다른 프로세스")
                return
            }
            self.lock = lock
            let loaded = try store.load()
            config = loaded.config
            isReadOnly = loaded.isReadOnly

            await Task.detached { [system] in system.removeStaleRoutes() }.value
            let engine = RouteEngine(system: system)
            self.engine = engine
            server = try ControlServer { [weak self] request in
                await self?.handle(request) ?? ControlResponse(ok: false, error: "shutting down")
            }
            eventsTask = Task { [weak self] in
                for await _ in engine.events { await self?.refreshStatuses() }
            }
            try await engine.start(rules: config.routes)
            mode = .active
            await refresh()
        } catch {
            log.error("start failed: \(String(describing: error), privacy: .public)")
            mode = .failed(String(describing: error))
        }
    }

    /// Tries again after another runner has quit.
    func retry() async {
        mode = .starting
        await start()
    }

    /// Hands the running resources to the caller for teardown off the main actor (see `AppDelegate`).
    /// Order: engine (routes) first, then the control socket, then the run lock.
    func detachForShutdown() -> @Sendable () async -> Void {
        eventsTask?.cancel()
        let engine = engine, server = server, lock = lock
        self.engine = nil
        self.server = nil
        self.lock = nil
        return {
            await engine?.stop()
            server?.stop()
            withExtendedLifetime(lock) {}
        }
    }

    // MARK: Refresh

    /// Re-reads devices, processes and route status. Core Audio is queried off the main thread.
    func refresh() async {
        let state = await Task.detached { [system] in try? system.currentState() }.value
        if let state {
            devices = state.devices.sorted { ($0.isDefault ? 0 : 1, $0.name) < ($1.isDefault ? 0 : 1, $1.name) }
            processes = state.processes
        }
        await refreshStatuses()
    }

    func refreshStatuses() async {
        guard let engine else { return }
        statuses = Dictionary(uniqueKeysWithValues: await engine.status().map { ($0.id, $0) })
    }

    // MARK: Rows

    var items: [AppItem] {
        allItems()
            .filter { showAllApps || $0.isPlaying || rule(for: $0) != nil }
            .sorted { lhs, rhs in
                let left = (rule(for: lhs) == nil ? 1 : 0, lhs.isPlaying ? 0 : 1, lhs.name.lowercased())
                let right = (rule(for: rhs) == nil ? 1 : 0, rhs.isPlaying ? 0 : 1, rhs.name.lowercased())
                return left < right
            }
    }

    /// Apps that use audio but are hidden because they are silent and unrouted.
    var hiddenAppCount: Int { showAllApps ? 0 : allItems().count - items.count }

    private func allItems() -> [AppItem] {
        var byID: [String: AppItem] = [:]
        for process in processes {
            let bundleID: String
            if let owner = config.routes.first(where: { AppMatcher.matches($0.app, bundleID: process.bundleID) }) {
                // Processes a rule already covers (helpers, Safari's WebKit GPU process) belong to that rule's row.
                bundleID = owner.app.bundleID
            } else if process.isApp {
                bundleID = process.appBundleID
            } else if AppPresets.displayName(for: process.bundleID) != nil {
                bundleID = process.bundleID
            } else {
                continue
            }
            guard !bundleID.isEmpty else { continue }
            let key = bundleID.lowercased()
            let name = AppPresets.displayName(for: bundleID)
                ?? (bundleID.caseInsensitiveCompare(process.appBundleID) == .orderedSame ? process.appName : AppIcons.name(for: bundleID))
            var item = byID[key] ?? AppItem(bundleID: bundleID, name: name, isPlaying: false)
            item.isPlaying = item.isPlaying || process.isRunningOutput
            byID[key] = item
        }
        for rule in config.routes where byID[rule.app.bundleID.lowercased()] == nil {
            byID[rule.app.bundleID.lowercased()] = AppItem(
                bundleID: rule.app.bundleID, name: AppIcons.name(for: rule.app.bundleID), isPlaying: false)
        }
        return Array(byID.values)
    }

    func rule(for item: AppItem) -> RouteRule? { config.rule(forBundleID: item.bundleID) }

    func status(for item: AppItem) -> RouteStatus? { rule(for: item).flatMap { statuses[$0.id] } }

    // MARK: Editing

    /// `uid == nil` removes the rule so the app follows the default output again.
    func setDevice(_ uid: String?, for item: AppItem) {
        var updated = config
        if let uid {
            let name = devices.first(where: { $0.uid == uid })?.name ?? rule(for: item)?.device.name ?? uid
            var rule = rule(for: item) ?? RouteRule(
                app: AppRule(bundleID: item.bundleID, extraBundleIDs: AppPresets.defaultExtraBundleIDs(for: item.bundleID)),
                device: DeviceRef(uid: uid, name: name))
            rule.device = DeviceRef(uid: uid, name: name)
            rule.enabled = true
            updated.upsert(rule)
        } else {
            updated.remove(bundleID: item.bundleID)
        }
        apply(updated)
    }

    /// Live gain change while dragging; `commit` saves to disk when the drag ends.
    func setVolume(_ volume: Float, for item: AppItem, commit: Bool) {
        guard var rule = rule(for: item) else { return }
        rule.volume = volume
        config.upsert(rule)
        Task { await engine?.setVolume(volume, for: rule.id) }
        if commit { save(config) }
    }

    private func apply(_ updated: RouteConfig) {
        guard save(updated) else { return }
        Task {
            await engine?.setRules(updated.routes)
            await refreshStatuses()
        }
    }

    @discardableResult
    private func save(_ updated: RouteConfig) -> Bool {
        guard !isReadOnly else {
            lastError = ConfigError.readOnly(version: config.version).description
            return false
        }
        do {
            try store.save(updated)
            config = updated
            lastError = nil
            return true
        } catch {
            lastError = String(describing: error)
            return false
        }
    }

    private func reloadFromDisk() async throws {
        let loaded = try store.load()
        config = loaded.config
        isReadOnly = loaded.isReadOnly
        await engine?.setRules(config.routes)
        await refresh()
    }

    // MARK: Control socket

    private func handle(_ request: ControlRequest) async -> ControlResponse {
        switch request.command {
        case .status:
            return ControlResponse(ok: true, owner: Self.ownerName, routes: await engine?.status() ?? [])
        case .reload:
            do {
                try await reloadFromDisk()
                return ControlResponse(ok: true, owner: Self.ownerName)
            } catch {
                return ControlResponse(ok: false, owner: Self.ownerName, error: String(describing: error))
            }
        }
    }
}

/// App names and icons by bundle ID, cached.
@MainActor
enum AppIcons {
    private static var icons: [String: NSImage] = [:]

    static func name(for bundleID: String) -> String {
        if let preset = AppPresets.displayName(for: bundleID) { return preset }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    static func icon(for bundleID: String) -> NSImage {
        if let cached = icons[bundleID] { return cached }
        let lookup = bundleID == AppPresets.webKitGPU ? "com.apple.Safari" : bundleID
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: lookup) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
        }
        image.size = NSSize(width: 20, height: 20)
        icons[bundleID] = image
        return image
    }
}
