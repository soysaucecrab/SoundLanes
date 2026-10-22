import CoreAudio
import Foundation
import os

/// Keeps one app → device route in line with the hardware (used by `soundlanes once`).
/// All routing state changes happen on this actor. Listener callbacks only signal it,
/// and it reconciles once after a 200 ms debounce (SPEC §4.2).
/// M2's `RouteEngine` generalizes this to many routes behind the `AudioSystem` protocol.
public actor RouteSession {
    public enum Event: Sendable {
        case started(processes: [AudioProcess], diagnostics: RouteDiagnostics?)
        case updated(processes: [AudioProcess], method: UpdateMethod)
        case inactive(RoutePlan.InactiveReason)
        case failed(message: String, retryIn: Duration)
    }

    public enum UpdateMethod: Sendable {
        case inPlace
        /// In-place update was refused; the route was rebuilt. Carries the refusal.
        case recreated(updateError: String)
    }

    public nonisolated let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation

    private let rule: AppRule
    private let appName: String
    private let deviceUID: String
    private let keepDeviceInput: Bool
    private let listenerQueue = DispatchQueue(label: "com.zinu.soundlanes.listeners")
    private let log = Logger(subsystem: "com.zinu.soundlanes", category: "RouteSession")

    private var route: TapRoute?
    private var listeners: [PropertyListener] = []
    private var lastInactive: RoutePlan.InactiveReason?
    private var failures = 0
    private var retryAt: ContinuousClock.Instant?
    private var pending: Task<Void, Never>?
    private var isStopped = false

    public init(rule: AppRule, appName: String, deviceUID: String, keepDeviceInput: Bool = false) {
        self.rule = rule
        self.appName = appName
        self.deviceUID = deviceUID
        self.keepDeviceInput = keepDeviceInput
        (events, continuation) = AsyncStream.makeStream(of: Event.self)
    }

    public func start() throws {
        let selectors = [
            kAudioHardwarePropertyProcessObjectList,
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
        ]
        for selector in selectors {
            listeners.append(try AudioObject.system.addListener(selector, queue: listenerQueue) { [weak self] _ in
                self?.noteChange()
            })
        }
        reconcile()
    }

    /// Tears everything down. Safe to call more than once.
    public func stop() {
        isStopped = true
        pending?.cancel()
        pending = nil
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        route?.stop()
        route = nil
        continuation.finish()
    }

    public func takeReading() -> MeterReading? { route?.takeReading() }

    nonisolated func noteChange() {
        Task { await self.scheduleReconcile(after: .milliseconds(200)) }
    }

    private func scheduleReconcile(after delay: Duration) {
        guard !isStopped else { return }
        pending?.cancel()
        pending = Task {
            guard (try? await Task.sleep(for: delay)) != nil else { return }
            self.reconcile()
        }
    }

    private func reconcile() {
        guard !isStopped else { return }
        let devices: [OutputDevice]
        let processes: [AudioProcess]
        do {
            devices = try DeviceCatalog.outputDevices()
            processes = try ProcessCatalog.processes()
        } catch {
            log.error("reading hardware state failed: \(String(describing: error), privacy: .public)")
            scheduleReconcile(after: .seconds(1))
            return
        }
        let plan = RoutePlanner.plan(
            rule: rule, deviceUID: deviceUID,
            availableDeviceUIDs: Set(devices.map(\.uid)),
            defaultOutputUID: devices.first(where: \.isDefault)?.uid,
            processes: processes)
        let matched = AppMatcher.select(rule, from: processes)

        switch plan {
        case .inactive(let reason):
            route?.stop()
            route = nil
            failures = 0
            retryAt = nil
            if lastInactive != reason {
                lastInactive = reason
                continuation.yield(.inactive(reason))
            }

        case .active(let objects):
            lastInactive = nil
            if let route {
                guard route.processes != objects else { return }
                do {
                    try route.updateProcesses(objects)
                    continuation.yield(.updated(processes: matched, method: .inPlace))
                } catch {
                    log.notice("in-place tap update refused, recreating: \(String(describing: error), privacy: .public)")
                    route.stop()
                    self.route = nil
                    if create(objects, devices: devices, matched: matched, announce: false) {
                        continuation.yield(.updated(processes: matched, method: .recreated(updateError: String(describing: error))))
                    }
                }
            } else {
                if let retryAt, ContinuousClock.now < retryAt { return }
                create(objects, devices: devices, matched: matched, announce: true)
            }
        }
    }

    @discardableResult
    private func create(_ objects: [AudioObject], devices: [OutputDevice], matched: [AudioProcess], announce: Bool) -> Bool {
        guard let device = devices.first(where: { $0.uid == deviceUID }) else { return false }
        let newRoute = TapRoute(appName: appName, device: device, processes: objects, keepDeviceInput: keepDeviceInput)
        do {
            try newRoute.start()
            route = newRoute
            failures = 0
            retryAt = nil
            if announce { continuation.yield(.started(processes: matched, diagnostics: newRoute.diagnostics)) }
            return true
        } catch {
            failures += 1
            // Backoff 1s, 2s, 4s … capped at 30s (SPEC §4.3).
            let delay = Duration.seconds(min(1 << min(failures - 1, 5), 30))
            retryAt = ContinuousClock.now + delay
            continuation.yield(.failed(message: String(describing: error), retryIn: delay))
            scheduleReconcile(after: delay)
            return false
        }
    }
}
