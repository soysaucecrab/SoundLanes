import Foundation
import os

/// What a rule is doing right now, for `status`, the menu bar app and the control socket.
public struct RouteStatus: Codable, Hashable, Sendable, Identifiable {
    public enum Phase: String, Codable, Sendable {
        case disabled
        case deviceMissing
        case deviceIsDefault
        case noProcesses
        case running
        case failed
        /// IO never started: the HAL refuses to read the tap without audio-capture permission (SPEC §3.4).
        case noPermission

        /// Short Korean label for UI and CLI.
        public var label: String {
            switch self {
            case .disabled: "꺼짐"
            case .deviceMissing: "장치 연결 안 됨"
            case .deviceIsDefault: "기본 출력과 같음"
            case .noProcesses: "재생 대기"
            case .running: "라우팅 중"
            case .failed: "실패"
            case .noPermission: "권한 없음"
            }
        }
    }

    public var id: UUID
    public var bundleID: String
    public var device: DeviceRef
    public var volume: Float
    public var phase: Phase
    public var processCount: Int
    public var message: String?
    /// Output device latency minus the default output's latency (SPEC §7.1). Nil when not routing.
    public var extraLatencyMilliseconds: Double?
    /// Peak of the tapped app audio since the previous `status()` call (linear, before volume). Nil when not routing.
    public var inputPeak: Float?
    /// IOProc cycles and cycles without tap data since the route started. Nil when not routing.
    public var ioCycles: UInt64?
    public var missingInputCycles: UInt64?
}

/// Keeps the set of running routes in line with the rules and the hardware (SPEC §4.2).
/// All routing state lives on this actor. Change notifications only schedule work;
/// a reconcile runs once per burst after the debounce interval.
public actor RouteEngine {
    public enum EventKind: Sendable {
        case started(processes: [AudioProcess], diagnostics: RouteDiagnostics?)
        case updated(processes: [AudioProcess], method: UpdateMethod)
        case inactive(RouteStatus.Phase)
        case failed(message: String, retryIn: Duration)
    }

    public enum UpdateMethod: Sendable {
        case inPlace
        /// The in-place update was refused; the route was rebuilt. Carries the refusal.
        case recreated(updateError: String)
    }

    public struct Event: Sendable {
        public let ruleID: UUID
        public let kind: EventKind
    }

    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let system: any AudioSystem
    private let debounce: Duration
    private let permissionGrace: Duration
    private let log = Logger(subsystem: "com.zinu.soundlanes", category: "RouteEngine")

    private var rules: [RouteRule] = []
    private var slots: [UUID: Slot] = [:]
    private var lastState: HardwareState?
    private var watcher: (any Cancellable)?
    private var pending: Task<Void, Never>?
    private var isStopped = false

    private struct Slot {
        var route: (any ActiveRoute)?
        var phase: RouteStatus.Phase?
        var processCount = 0
        var message: String?
        var failures = 0
        var retryAt: ContinuousClock.Instant?
        var startedAt: ContinuousClock.Instant?
    }

    public init(system: any AudioSystem, debounce: Duration = .milliseconds(200),
                permissionGrace: Duration = .seconds(2)) {
        self.system = system
        self.debounce = debounce
        self.permissionGrace = permissionGrace
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    /// Starts watching the hardware and applies `rules`.
    public func start(rules: [RouteRule]) throws {
        self.rules = rules
        watcher = try system.watchChanges { [weak self] in self?.noteChange() }
        reconcile()
    }

    /// Stops every route. The engine cannot be restarted.
    public func stop() {
        isStopped = true
        pending?.cancel()
        pending = nil
        watcher?.cancel()
        watcher = nil
        for slot in slots.values { slot.route?.stop() }
        slots.removeAll()
        continuation.finish()
    }

    /// Replaces the rule set and reconciles immediately.
    public func setRules(_ newRules: [RouteRule]) {
        rules = newRules
        reconcile()
    }

    /// Changes one rule's gain on the running route without a reconcile (for live slider updates).
    public func setVolume(_ volume: Float, for ruleID: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        rules[index].volume = volume
        slots[ruleID]?.route?.volume = volume
    }

    public func takeReading(for ruleID: UUID) -> MeterReading? {
        slots[ruleID]?.route?.takeReading(resetPeak: true)
    }

    /// Current state of every rule. Resets the per-route input peak, so poll from one place at a time.
    public func status() -> [RouteStatus] {
        let defaultLatency = lastState?.defaultOutput?.latencyMilliseconds
        return rules.map { rule in
            let slot = slots[rule.id]
            var phase = slot?.phase ?? (rule.enabled ? .noProcesses : .disabled)
            let reading = slot?.route?.takeReading(resetPeak: true)
            if phase == .running, let reading, let startedAt = slot?.startedAt,
               ContinuousClock.now - startedAt >= permissionGrace,
               reading.cycles == 0, !reading.isRunning {
                phase = .noPermission
            }
            var extraLatency: Double?
            if phase == .running, let defaultLatency,
               let device = lastState?.devices.first(where: { $0.uid == rule.device.uid }) {
                extraLatency = device.latencyMilliseconds - defaultLatency
            }
            return RouteStatus(
                id: rule.id, bundleID: rule.app.bundleID, device: rule.device, volume: rule.volume,
                phase: phase, processCount: slot?.processCount ?? 0, message: slot?.message,
                extraLatencyMilliseconds: extraLatency,
                inputPeak: reading?.peak, ioCycles: reading?.cycles, missingInputCycles: reading?.missingInputCycles)
        }
    }

    // MARK: - Reconcile

    nonisolated func noteChange() {
        Task { await self.scheduleReconcile(after: nil) }
    }

    private func scheduleReconcile(after delay: Duration?) {
        guard !isStopped else { return }
        pending?.cancel()
        let delay = delay ?? debounce
        pending = Task {
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            self.reconcile()
        }
    }

    /// One pass over all rules. Internal so tests can drive it without timers.
    func reconcile() {
        guard !isStopped else { return }
        let state: HardwareState
        do {
            state = try system.currentState()
        } catch {
            log.error("reading hardware state failed: \(String(describing: error), privacy: .public)")
            scheduleReconcile(after: .seconds(1))
            return
        }
        lastState = state

        let ruleIDs = Set(rules.map(\.id))
        for (id, slot) in slots where !ruleIDs.contains(id) {
            slot.route?.stop()
            slots[id] = nil
        }
        for rule in rules {
            var slot = slots[rule.id] ?? Slot()
            reconcile(rule, slot: &slot, state: state)
            slots[rule.id] = slot
        }
    }

    private func reconcile(_ rule: RouteRule, slot: inout Slot, state: HardwareState) {
        guard rule.enabled else {
            tearDown(&slot)
            setInactive(.disabled, rule: rule, slot: &slot)
            return
        }
        if let route = slot.route, route.deviceUID != rule.device.uid {
            tearDown(&slot)
        }
        let plan = RoutePlanner.plan(
            rule: rule.app, deviceUID: rule.device.uid,
            availableDeviceUIDs: Set(state.devices.map(\.uid)),
            defaultOutputUID: state.defaultOutput?.uid,
            processes: state.processes)

        switch plan {
        case .inactive(let reason):
            tearDown(&slot)
            let phase: RouteStatus.Phase = switch reason {
            case .deviceMissing: .deviceMissing
            case .deviceIsDefault: .deviceIsDefault
            case .noProcesses: .noProcesses
            }
            setInactive(phase, rule: rule, slot: &slot)

        case .active(let objects):
            let matched = AppMatcher.select(rule.app, from: state.processes)
            if let route = slot.route {
                if route.volume != rule.volume { route.volume = rule.volume }
                guard route.processes != objects else { return }
                do {
                    try route.updateProcesses(objects)
                    slot.processCount = objects.count
                    continuation.yield(Event(ruleID: rule.id, kind: .updated(processes: matched, method: .inPlace)))
                } catch {
                    log.notice("in-place tap update refused, recreating: \(String(describing: error), privacy: .public)")
                    tearDown(&slot)
                    if start(rule, objects: objects, matched: matched, state: state, slot: &slot) {
                        continuation.yield(Event(ruleID: rule.id, kind: .updated(
                            processes: matched, method: .recreated(updateError: String(describing: error)))))
                    }
                }
            } else {
                if let retryAt = slot.retryAt, ContinuousClock.now < retryAt { return }
                if start(rule, objects: objects, matched: matched, state: state, slot: &slot) {
                    continuation.yield(Event(ruleID: rule.id, kind: .started(
                        processes: matched, diagnostics: slot.route?.diagnostics)))
                }
            }
        }
    }

    private func start(_ rule: RouteRule, objects: [AudioObject], matched: [AudioProcess],
                       state: HardwareState, slot: inout Slot) -> Bool {
        guard let device = state.devices.first(where: { $0.uid == rule.device.uid }) else { return false }
        let appName = matched.first(where: { $0.appBundleID.caseInsensitiveCompare(rule.app.bundleID) == .orderedSame })?.appName
            ?? rule.app.bundleID
        do {
            slot.route = try system.makeRoute(appName: appName, device: device, processes: objects, volume: rule.volume)
            slot.phase = .running
            slot.processCount = objects.count
            slot.message = nil
            slot.failures = 0
            slot.retryAt = nil
            slot.startedAt = ContinuousClock.now
            return true
        } catch {
            slot.failures += 1
            // Backoff 1s, 2s, 4s … capped at 30s (SPEC §4.3).
            let delay = Duration.seconds(min(1 << min(slot.failures - 1, 5), 30))
            slot.retryAt = ContinuousClock.now + delay
            slot.phase = .failed
            slot.message = String(describing: error)
            log.error("route for \(rule.app.bundleID, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            continuation.yield(Event(ruleID: rule.id, kind: .failed(message: String(describing: error), retryIn: delay)))
            scheduleReconcile(after: delay)
            return false
        }
    }

    private func tearDown(_ slot: inout Slot) {
        slot.route?.stop()
        slot.route = nil
        slot.startedAt = nil
        slot.processCount = 0
    }

    private func setInactive(_ phase: RouteStatus.Phase, rule: RouteRule, slot: inout Slot) {
        slot.failures = 0
        slot.retryAt = nil
        slot.message = nil
        guard slot.phase != phase else { return }
        slot.phase = phase
        continuation.yield(Event(ruleID: rule.id, kind: .inactive(phase)))
    }
}
