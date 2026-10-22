import CoreAudio
import Foundation

/// Everything `RouteEngine` needs to know about the hardware at one moment.
public struct HardwareState: Sendable {
    public var devices: [OutputDevice]
    public var processes: [AudioProcess]

    public init(devices: [OutputDevice], processes: [AudioProcess]) {
        self.devices = devices
        self.processes = processes
    }

    public var defaultOutput: OutputDevice? { devices.first(where: \.isDefault) }
}

/// A running route as the engine sees it. `TapRoute` is the real implementation.
public protocol ActiveRoute: AnyObject {
    var deviceUID: String { get }
    var processes: [AudioObject] { get }
    var volume: Float { get set }
    var diagnostics: RouteDiagnostics? { get }
    /// Retarget to a new process set; throws if this must be done by recreating the route.
    func updateProcesses(_ processes: [AudioObject]) throws
    func takeReading(resetPeak: Bool) -> MeterReading
    func stop()
}

public protocol Cancellable: AnyObject, Sendable {
    func cancel()
}

/// The engine's only window onto Core Audio, so tests can substitute a fake (SPEC §12.1).
public protocol AudioSystem: Sendable {
    func currentState() throws -> HardwareState
    /// Creates and starts a route. On failure nothing is left behind.
    func makeRoute(appName: String, device: OutputDevice, processes: [AudioObject], volume: Float) throws -> any ActiveRoute
    /// Calls `onChange` (on an arbitrary queue) when processes, devices or the default output change.
    func watchChanges(_ onChange: @escaping @Sendable () -> Void) throws -> any Cancellable
    /// Deletes aggregates left by an earlier run (SPEC §10).
    func removeStaleRoutes()
}

extension TapRoute: ActiveRoute {}

public struct CoreAudioSystem: AudioSystem {
    /// Leave output-device input streams enabled (M0 comparison only).
    public var keepDeviceInput: Bool

    public init(keepDeviceInput: Bool = false) {
        self.keepDeviceInput = keepDeviceInput
    }

    public func currentState() throws -> HardwareState {
        HardwareState(devices: try DeviceCatalog.outputDevices(), processes: try ProcessCatalog.processes())
    }

    public func makeRoute(appName: String, device: OutputDevice, processes: [AudioObject], volume: Float) throws -> any ActiveRoute {
        let route = TapRoute(appName: appName, device: device, processes: processes, volume: volume,
                             keepDeviceInput: keepDeviceInput)
        try route.start()
        return route
    }

    public func watchChanges(_ onChange: @escaping @Sendable () -> Void) throws -> any Cancellable {
        let queue = DispatchQueue(label: "com.zinu.soundlanes.listeners")
        let group = ListenerGroup()
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultOutputDevice] {
            do {
                group.add(try AudioObject.system.addListener(selector, queue: queue) { _ in onChange() })
            } catch {
                group.cancel()
                throw error
            }
        }
        return group
    }

    public func removeStaleRoutes() {
        TapRoute.removeStaleAggregates()
    }
}

final class ListenerGroup: Cancellable, @unchecked Sendable {
    // Mutated only during setup (before it is shared) and in cancel(), both on the engine actor.
    private var listeners: [PropertyListener] = []

    func add(_ listener: PropertyListener) { listeners.append(listener) }

    func cancel() {
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
    }
}
