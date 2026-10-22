import CoreAudio
import Foundation
import Testing
@testable import RouteCore

private final class FakeRoute: ActiveRoute {
    let deviceUID: String
    var processes: [AudioObject]
    var volume: Float
    var diagnostics: RouteDiagnostics? { nil }
    var refuseUpdates: Bool
    var cycles: UInt64 = 100
    var isRunning = true
    private(set) var isStopped = false

    init(deviceUID: String, processes: [AudioObject], volume: Float, refuseUpdates: Bool) {
        self.deviceUID = deviceUID
        self.processes = processes
        self.volume = volume
        self.refuseUpdates = refuseUpdates
    }

    func updateProcesses(_ processes: [AudioObject]) throws {
        if refuseUpdates { throw CoreAudioError(kAudioHardwareIllegalOperationError, "update") }
        self.processes = processes
    }

    func takeReading(resetPeak: Bool) -> MeterReading {
        MeterReading(peak: 0, cycles: cycles, missingInputCycles: 0, isRunning: isRunning)
    }

    func stop() { isStopped = true }
}

private final class FakeSystem: AudioSystem, @unchecked Sendable {
    var state: HardwareState
    var routes: [FakeRoute] = []
    var failCreation = false
    var refuseUpdates = false

    init(state: HardwareState) { self.state = state }

    var live: [FakeRoute] { routes.filter { !$0.isStopped } }

    func currentState() throws -> HardwareState { state }

    func makeRoute(appName: String, device: OutputDevice, processes: [AudioObject], volume: Float) throws -> any ActiveRoute {
        if failCreation { throw CoreAudioError(OSStatus(bitPattern: 0x216F_626A), "create") }
        let route = FakeRoute(deviceUID: device.uid, processes: processes, volume: volume, refuseUpdates: refuseUpdates)
        routes.append(route)
        return route
    }

    func watchChanges(_ onChange: @escaping @Sendable () -> Void) throws -> any Cancellable { NoopCancellable() }
    func removeStaleRoutes() {}
}

private final class NoopCancellable: Cancellable { func cancel() {} }

private func device(_ uid: String, isDefault: Bool = false, latency: UInt32 = 480) -> OutputDevice {
    OutputDevice(object: AudioObject(UInt32(abs(uid.hashValue) % 10_000)), uid: uid, name: uid, isDefault: isDefault,
                 sampleRate: 48_000, latencyFrames: latency, transportType: 0, inputStreamCount: 0)
}

private func process(_ id: UInt32, _ bundleID: String) -> AudioProcess {
    AudioProcess(object: AudioObject(id), pid: pid_t(id), bundleID: bundleID, isRunningOutput: true,
                 appName: "Chrome", appBundleID: "com.google.Chrome")
}

private let chromeToAirPods = RouteRule(
    app: AppRule(bundleID: "com.google.Chrome"), device: DeviceRef(uid: "airpods", name: "AirPods"))

private func makeEngine(_ system: FakeSystem, rules: [RouteRule] = [chromeToAirPods]) async throws -> RouteEngine {
    let engine = RouteEngine(system: system, permissionGrace: .zero)
    try await engine.start(rules: rules)
    return engine
}

private func standardState() -> HardwareState {
    HardwareState(devices: [device("speaker", isDefault: true, latency: 480), device("airpods", latency: 9_600)],
                  processes: [process(10, "com.google.Chrome.helper"), process(20, "com.apple.Music")])
}

@Suite struct RouteEngineTests {
    @Test func startsRouteForMatchingProcesses() async throws {
        let system = FakeSystem(state: standardState())
        let engine = try await makeEngine(system)
        #expect(system.live.count == 1)
        #expect(system.live[0].processes == [AudioObject(10)])
        let status = await engine.status()
        #expect(status.first?.phase == .running)
        #expect(status.first?.extraLatencyMilliseconds == 190)  // (9600 - 480) / 48 kHz
    }

    @Test func deviceDisconnectRemovesRouteAndReconnectRestores() async throws {  // S2
        let system = FakeSystem(state: standardState())
        let engine = try await makeEngine(system)
        system.state.devices.removeAll { $0.uid == "airpods" }
        await engine.reconcile()
        #expect(system.live.isEmpty)
        #expect(await engine.status().first?.phase == .deviceMissing)

        system.state = standardState()
        await engine.reconcile()
        #expect(system.live.count == 1)
    }

    @Test func helperAddedUpdatesTapInPlace() async throws {
        let system = FakeSystem(state: standardState())
        let engine = try await makeEngine(system)
        system.state.processes.append(process(11, "com.google.Chrome.helper"))
        await engine.reconcile()
        #expect(system.routes.count == 1)
        #expect(system.live[0].processes == [AudioObject(10), AudioObject(11)])
    }

    @Test func refusedUpdateRecreatesTap() async throws {
        let system = FakeSystem(state: standardState())
        system.refuseUpdates = true
        let engine = try await makeEngine(system)
        system.state.processes.append(process(11, "com.google.Chrome.helper"))
        await engine.reconcile()
        #expect(system.routes.count == 2)
        #expect(system.routes[0].isStopped)
        #expect(system.live.map(\.processes) == [[AudioObject(10), AudioObject(11)]])
    }

    @Test func deviceIsDefaultNeedsNoTap() async throws {  // S6
        var state = standardState()
        state.devices = [device("speaker"), device("airpods", isDefault: true)]
        let system = FakeSystem(state: state)
        let engine = try await makeEngine(system)
        #expect(system.routes.isEmpty)
        #expect(await engine.status().first?.phase == .deviceIsDefault)
    }

    @Test func appQuitAndRelaunchRestartsRoute() async throws {  // S3
        let system = FakeSystem(state: standardState())
        let engine = try await makeEngine(system)
        system.state.processes.removeAll { $0.bundleID.hasPrefix("com.google.Chrome") }
        await engine.reconcile()
        #expect(system.live.isEmpty)
        #expect(await engine.status().first?.phase == .noProcesses)

        system.state.processes.append(process(30, "com.google.Chrome.helper"))
        await engine.reconcile()
        #expect(system.live.map(\.processes) == [[AudioObject(30)]])
    }

    @Test func disabledAndRemovedRulesStopRoutes() async throws {
        let system = FakeSystem(state: standardState())
        let engine = try await makeEngine(system)
        var disabled = chromeToAirPods
        disabled.enabled = false
        await engine.setRules([disabled])
        #expect(system.live.isEmpty)
        #expect(await engine.status().first?.phase == .disabled)

        await engine.setRules([chromeToAirPods])
        #expect(system.live.count == 1)
        await engine.setRules([])
        #expect(system.live.isEmpty)
        #expect(await engine.status().isEmpty)
    }

    @Test func changingDeviceRecreatesOnNewDevice() async throws {
        var state = standardState()
        state.devices.append(device("dac"))
        let system = FakeSystem(state: state)
        let engine = try await makeEngine(system)
        var moved = chromeToAirPods
        moved.device = DeviceRef(uid: "dac", name: "DAC")
        await engine.setRules([moved])
        #expect(system.live.map(\.deviceUID) == ["dac"])
    }

    @Test func volumeChangeDoesNotRecreate() async throws {
        let system = FakeSystem(state: standardState())
        let engine = try await makeEngine(system)
        var quieter = chromeToAirPods
        quieter.volume = 0.25
        await engine.setRules([quieter])
        #expect(system.routes.count == 1)
        #expect(system.live[0].volume == 0.25)
    }

    @Test func failureBacksOffAndKeepsOtherRules() async throws {
        let system = FakeSystem(state: standardState())
        system.failCreation = true
        let engine = try await makeEngine(system)
        #expect(await engine.status().first?.phase == .failed)
        #expect(await engine.status().first?.message?.contains("'!obj'") == true)

        system.failCreation = false
        await engine.reconcile()  // still inside the 1s backoff window
        #expect(system.routes.isEmpty)
    }

    @Test func stalledIOReportsMissingPermission() async throws {
        let system = FakeSystem(state: standardState())
        let engine = try await makeEngine(system)
        system.live[0].cycles = 0
        system.live[0].isRunning = false
        #expect(await engine.status().first?.phase == .noPermission)
    }

    @Test func stopTearsEverythingDown() async throws {
        let system = FakeSystem(state: standardState())
        let engine = try await makeEngine(system)
        await engine.stop()
        #expect(system.live.isEmpty)
    }
}

@Suite struct ConfigTests {
    private func temporaryStore() -> ConfigStore {
        ConfigStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent("soundlanes-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("routes.json"))
    }

    @Test func missingFileIsEmpty() throws {
        let loaded = try temporaryStore().load()
        #expect(loaded.config.routes.isEmpty)
        #expect(!loaded.isReadOnly)
    }

    @Test func roundTripUsesSpecLayout() throws {
        let store = temporaryStore()
        try store.save(RouteConfig(routes: [chromeToAirPods]))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: store.url)) as? [String: Any]
        let route = (json?["routes"] as? [[String: Any]])?.first
        #expect(json?["version"] as? Int == 1)
        #expect((route?["app"] as? [String: Any])?["bundleID"] as? String == "com.google.Chrome")
        #expect((route?["device"] as? [String: Any])?["uid"] as? String == "airpods")
        #expect(try store.load().config.routes == [chromeToAirPods])
    }

    @Test func duplicateAppIsRejected() throws {
        var other = chromeToAirPods
        other.id = UUID()
        other.app.bundleID = "COM.GOOGLE.CHROME"
        #expect(throws: ConfigError.self) { try temporaryStore().save(RouteConfig(routes: [chromeToAirPods, other])) }
    }

    @Test func unknownVersionIsReadOnly() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"version": 2, "routes": []}"#.utf8).write(to: store.url)
        let loaded = try store.load()
        #expect(loaded.isReadOnly)
        #expect(throws: ConfigError.self) { try store.save(loaded.config) }
    }

    @Test func upsertKeepsIDAndRemoveIsCaseInsensitive() {
        var config = RouteConfig(routes: [chromeToAirPods])
        config.upsert(RouteRule(app: AppRule(bundleID: "com.google.chrome"), device: DeviceRef(uid: "dac", name: "DAC")))
        #expect(config.routes.count == 1)
        #expect(config.routes[0].id == chromeToAirPods.id)
        #expect(config.routes[0].device.uid == "dac")
        #expect(config.remove(bundleID: "COM.google.Chrome") != nil)
        #expect(config.routes.isEmpty)
    }
}

@Suite struct ControlSocketTests {
    @Test func requestAndResponseRoundTrip() throws {
        let url = URL(fileURLWithPath: "/tmp/sl-\(UUID().uuidString.prefix(8)).sock")
        let server = try ControlServer(at: url) { request in
            ControlResponse(ok: request.command == .status, owner: "test")
        }
        defer { server.stop() }
        let response = try ControlClient.send(ControlRequest(.status), to: url)
        #expect(response.ok)
        #expect(response.owner == "test")
    }

    @Test func missingServerIsNotRunning() {
        #expect(throws: ControlError.self) {
            try ControlClient.send(ControlRequest(.status), to: URL(fileURLWithPath: "/tmp/sl-missing.sock"))
        }
    }

    @Test func lockIsExclusive() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString).lock")
        let first = try InstanceLock.acquire(owner: "first", at: url)
        #expect(first != nil)
        #expect(try InstanceLock.acquire(owner: "second", at: url) == nil)
        #expect(InstanceLock.currentOwner(at: url)?.hasPrefix("first") == true)
    }
}
