import CoreAudio
import Foundation
import os

/// Errors raised while setting up a route that are not plain Core Audio failures.
public enum RouteError: Error, CustomStringConvertible, Sendable {
    case unsupportedTapFormat(String)
    case unsupportedOutputFormat(String)
    case deviceNotFound(uid: String)

    public var description: String {
        switch self {
        case .unsupportedTapFormat(let format): "지원하지 않는 탭 포맷입니다: \(format)"
        case .unsupportedOutputFormat(let format): "지원하지 않는 출력 장치 포맷입니다: \(format)"
        case .deviceNotFound(let uid): "출력 장치를 찾을 수 없습니다: \(uid)"
        }
    }
}

/// What we learned while building a route. Answers the M0 questions in SPEC §13.
public struct RouteDiagnostics: Sendable {
    public var tapSampleRate: Double
    public var tapChannels: Int
    public var tapInterleaved: Bool
    public var deviceSampleRateBefore: Double
    public var deviceSampleRateAfter: Double
    public var aggregateSampleRate: Double
    public var deviceInputStreams: Int
    public var aggregateInputStreams: Int
    public var aggregateOutputChannels: Int
    /// Device input streams disabled for our IOProc so Bluetooth headsets can stay in A2DP (SPEC §6).
    public var disabledInputStreams: Int
    public var tapBufferIndex: Int
}

public struct MeterReading: Sendable {
    public var peak: Float
    public var cycles: UInt64
    public var missingInputCycles: UInt64
    /// `kAudioDevicePropertyDeviceIsRunning` of the aggregate.
    public var isRunning: Bool
}

/// One tap + one private aggregate + one IOProc (SPEC §4.3).
/// Create order: tap → aggregate → IOProc → start. Teardown is the exact reverse.
public final class TapRoute {
    public let id = UUID()
    public let deviceUID: String
    public private(set) var processes: [AudioObject]
    public private(set) var diagnostics: RouteDiagnostics?

    private let appName: String
    private let deviceName: String
    private let tapUUID = UUID()
    private let keepDeviceInput: Bool
    private var tap = AudioObject.unknown
    private var aggregate = AudioObject.unknown
    private var procID: AudioDeviceIOProcID?
    private var isStarted = false
    private let meters: UnsafeMutablePointer<RouteMeters>
    private let log = Logger(subsystem: "com.zinu.soundlanes", category: "TapRoute")

    /// - Parameter keepDeviceInput: leave the output device's own input streams enabled (M0 comparison only).
    public init(appName: String, device: OutputDevice, processes: [AudioObject], volume: Float = 1,
                keepDeviceInput: Bool = false) {
        self.appName = appName
        self.deviceUID = device.uid
        self.deviceName = device.name
        self.processes = processes
        self.keepDeviceInput = keepDeviceInput
        meters = .allocate(capacity: 1)
        meters.initialize(to: RouteMeters(volume: Self.clampVolume(volume)))
    }

    deinit {
        stop()
        meters.deinitialize(count: 1)
        meters.deallocate()
    }

    public var aggregateUID: String { DeviceCatalog.aggregateUIDPrefix + id.uuidString }

    public var volume: Float {
        get { Float(bitPattern: meters.pointee.volumeBits.load(ordering: .relaxed)) }
        set { meters.pointee.volumeBits.store(Self.clampVolume(newValue).bitPattern, ordering: .relaxed) }
    }

    /// Returns the peak since the previous reset; `resetPeak` starts a new measurement window.
    public func takeReading(resetPeak: Bool = true) -> MeterReading {
        let peakBits = resetPeak
            ? meters.pointee.peakBits.exchange(0, ordering: .relaxed)
            : meters.pointee.peakBits.load(ordering: .relaxed)
        return MeterReading(
            peak: Float(bitPattern: peakBits),
            cycles: meters.pointee.cycles.load(ordering: .relaxed),
            missingInputCycles: meters.pointee.missingInputCycles.load(ordering: .relaxed),
            isRunning: ((try? aggregate.read(kAudioDevicePropertyDeviceIsRunning, as: UInt32.self)) ?? 0) != 0)
    }

    public func start() throws {
        precondition(!isStarted && tap.isUnknown, "TapRoute.start() called twice")
        do {
            try startSteps()
        } catch {
            log.error("route \(self.id, privacy: .public) start failed: \(String(describing: error), privacy: .public)")
            stop()
            throw error
        }
    }

    private func startSteps() throws {
        guard let device = try DeviceCatalog.outputDevices().first(where: { $0.uid == deviceUID }) else {
            throw RouteError.deviceNotFound(uid: deviceUID)
        }

        // 1. Tap
        tap = try AudioHardware.createProcessTap(makeTapDescription(processes))
        let tapFormat = try tap.read(kAudioTapPropertyFormat, as: AudioStreamBasicDescription.self)
        guard Self.isFloat32PCM(tapFormat) else { throw RouteError.unsupportedTapFormat(Self.describe(tapFormat)) }
        log.info("tap \(self.tap.id) created: \(Self.describe(tapFormat), privacy: .public)")

        // 2. Private aggregate: output device as main sub-device, tap as input (SPEC §3.3)
        aggregate = try AudioHardware.createAggregateDevice([
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceNameKey: "SoundLanes \(appName) → \(deviceName)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: deviceUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: deviceUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
            kAudioAggregateDeviceTapAutoStartKey: true,
        ])
        log.info("aggregate \(self.aggregate.id) created: \(self.aggregateUID, privacy: .public)")

        var outputChannels = 0
        for stream in try DeviceCatalog.outputStreams(of: aggregate) {
            let format = try stream.read(kAudioStreamPropertyVirtualFormat, as: AudioStreamBasicDescription.self)
            guard Self.isFloat32PCM(format) else { throw RouteError.unsupportedOutputFormat(Self.describe(format)) }
            outputChannels += Int(format.mChannelsPerFrame)
        }

        // Assumption under test (M0): the aggregate lists sub-device input streams before tap streams.
        let aggregateInputs = try DeviceCatalog.inputStreams(of: aggregate).count
        let deviceInputs = device.inputStreamCount
        let tapBufferIndex = aggregateInputs > deviceInputs ? deviceInputs : 0
        let splitStereo = tapFormat.mChannelsPerFrame == 2
            && tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        // 3. IOProc
        let context = IOContext(meters: meters, tapBufferIndex: tapBufferIndex, tapIsSplitStereo: splitStereo)
        let procID = try AudioHardware.createIOProc(on: aggregate, block: IORenderer.makeBlock(context))
        self.procID = procID

        var disabled = 0
        if !keepDeviceInput, deviceInputs > 0, aggregateInputs > deviceInputs {
            try setInputStreamUsage(procID: procID, total: aggregateInputs, disabledPrefix: deviceInputs)
            disabled = deviceInputs
        }

        // 4. Start
        try AudioHardware.start(aggregate, procID: procID)
        isStarted = true

        diagnostics = RouteDiagnostics(
            tapSampleRate: tapFormat.mSampleRate,
            tapChannels: Int(tapFormat.mChannelsPerFrame),
            tapInterleaved: !splitStereo,
            deviceSampleRateBefore: device.sampleRate,
            deviceSampleRateAfter: (try? device.object.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self)) ?? 0,
            aggregateSampleRate: (try? aggregate.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self)) ?? 0,
            deviceInputStreams: deviceInputs,
            aggregateInputStreams: aggregateInputs,
            aggregateOutputChannels: outputChannels,
            disabledInputStreams: disabled,
            tapBufferIndex: tapBufferIndex)
        log.info("route \(self.id, privacy: .public) running: \(self.processes.count) processes → \(self.deviceUID, privacy: .public)")
    }

    /// Retargets the running tap to a new process set by rewriting its description (SPEC §4.3, §13 Q4).
    /// Throws if the HAL refuses; the caller then recreates the route.
    public func updateProcesses(_ newProcesses: [AudioObject]) throws {
        guard !tap.isUnknown else { return }
        try tap.write(kAudioTapPropertyDescription, value: makeTapDescription(newProcesses))
        processes = newProcesses
        log.info("tap \(self.tap.id) updated in place: \(newProcesses.count) processes")
    }

    /// Idempotent. Reverse order of creation; logs but does not stop on individual failures.
    public func stop() {
        if let procID {
            if isStarted { logFailure { () throws(CoreAudioError) in try AudioHardware.stop(aggregate, procID: procID) } }
            logFailure { () throws(CoreAudioError) in try AudioHardware.destroyIOProc(procID, on: aggregate) }
        }
        isStarted = false
        procID = nil
        if !aggregate.isUnknown {
            logFailure { () throws(CoreAudioError) in try AudioHardware.destroyAggregateDevice(aggregate) }
            aggregate = .unknown
        }
        if !tap.isUnknown {
            logFailure { () throws(CoreAudioError) in try AudioHardware.destroyProcessTap(tap) }
            tap = .unknown
        }
    }

    /// Removes aggregates left by an earlier run (UID prefix match). Returns how many were removed.
    @discardableResult
    public static func removeStaleAggregates() -> Int {
        let log = Logger(subsystem: "com.zinu.soundlanes", category: "TapRoute")
        var removed = 0
        for device in (try? DeviceCatalog.allDeviceObjects()) ?? [] {
            guard let uid = try? device.readString(kAudioDevicePropertyDeviceUID),
                  uid.hasPrefix(DeviceCatalog.aggregateUIDPrefix) else { continue }
            do {
                try AudioHardware.destroyAggregateDevice(device)
                removed += 1
                log.info("removed stale aggregate \(uid, privacy: .public)")
            } catch {
                log.error("failed to remove stale aggregate \(uid, privacy: .public): \(error.description, privacy: .public)")
            }
        }
        return removed
    }

    // MARK: - Private

    private func makeTapDescription(_ processes: [AudioObject]) -> CATapDescription {
        let description = CATapDescription(stereoMixdownOfProcesses: processes.map(\.id))
        description.uuid = tapUUID
        description.name = "SoundLanes \(appName)"
        description.muteBehavior = .mutedWhenTapped
        description.isPrivate = true
        return description
    }

    /// Marks the first `disabledPrefix` input streams as unused by our IOProc.
    private func setInputStreamUsage(procID: AudioDeviceIOProcID, total: Int, disabledPrefix: Int) throws {
        let flagsOffset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let size = flagsOffset + total * MemoryLayout<UInt32>.size
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: max(size, MemoryLayout<AudioHardwareIOProcStreamUsage>.size),
            alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { buffer.deallocate() }
        buffer.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self),
                          toByteOffset: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mIOProc)!,
                          as: UnsafeMutableRawPointer.self)
        buffer.storeBytes(of: UInt32(total),
                          toByteOffset: MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mNumberStreams)!,
                          as: UInt32.self)
        for index in 0..<total {
            buffer.storeBytes(of: index < disabledPrefix ? 0 : 1,
                              toByteOffset: flagsOffset + index * MemoryLayout<UInt32>.size, as: UInt32.self)
        }
        try aggregate.write(kAudioDevicePropertyIOProcStreamUsage, scope: kAudioObjectPropertyScopeInput,
                            bytes: buffer, size: size)
    }

    private func logFailure(_ body: () throws(CoreAudioError) -> Void) {
        do { try body() } catch {
            log.error("teardown step failed: \(error.description, privacy: .public)")
        }
    }

    private static func clampVolume(_ volume: Float) -> Float { min(max(volume, 0), 1) }

    static func isFloat32PCM(_ format: AudioStreamBasicDescription) -> Bool {
        format.mFormatID == kAudioFormatLinearPCM
            && format.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && format.mBitsPerChannel == 32
    }

    static func describe(_ format: AudioStreamBasicDescription) -> String {
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        return "\(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch, \(format.mBitsPerChannel)-bit "
            + (format.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "float" : "int")
            + (interleaved ? ", interleaved" : ", non-interleaved")
            + " (\(fourCharCode(OSStatus(bitPattern: format.mFormatID))))"
    }
}
