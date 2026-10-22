import CoreAudio
import Foundation

/// An output-capable audio device as seen at one point in time.
public struct OutputDevice: Hashable, Sendable {
    public let object: AudioObject
    public let uid: String
    public let name: String
    public let isDefault: Bool
    public let sampleRate: Double
    /// Device + safety offset + first stream latency, in frames.
    public let latencyFrames: UInt32
    public let transportType: UInt32
    public let inputStreamCount: Int

    public init(object: AudioObject, uid: String, name: String, isDefault: Bool, sampleRate: Double,
                latencyFrames: UInt32, transportType: UInt32, inputStreamCount: Int) {
        self.object = object
        self.uid = uid
        self.name = name
        self.isDefault = isDefault
        self.sampleRate = sampleRate
        self.latencyFrames = latencyFrames
        self.transportType = transportType
        self.inputStreamCount = inputStreamCount
    }

    public var latencyMilliseconds: Double {
        sampleRate > 0 ? Double(latencyFrames) / sampleRate * 1000 : 0
    }

    public var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth || transportType == kAudioDeviceTransportTypeBluetoothLE
    }

    public var isAggregate: Bool { transportType == kAudioDeviceTransportTypeAggregate }
}

public enum DeviceCatalog {
    /// Aggregate devices we create carry this UID prefix (SPEC §3.3, §10).
    public static let aggregateUIDPrefix = "com.zinu.soundlanes."

    public static func defaultOutputDevice() throws(CoreAudioError) -> AudioObject {
        AudioObject(try AudioObject.system.read(kAudioHardwarePropertyDefaultOutputDevice, as: AudioObjectID.self))
    }

    /// All devices with at least one output stream, excluding our own aggregates.
    public static func outputDevices() throws(CoreAudioError) -> [OutputDevice] {
        let defaultID = try defaultOutputDevice()
        var result: [OutputDevice] = []
        for id in try AudioObject.system.readArray(kAudioHardwarePropertyDevices, of: AudioObjectID.self) {
            let object = AudioObject(id)
            // A device can vanish between listing and querying; skip it rather than failing the whole list.
            guard let device = try? describe(object, defaultID: defaultID),
                  !device.uid.hasPrefix(aggregateUIDPrefix) else { continue }
            if try outputStreams(of: object).isEmpty { continue }
            result.append(device)
        }
        return result
    }

    public static func describe(_ object: AudioObject, defaultID: AudioObject? = nil) throws(CoreAudioError) -> OutputDevice {
        let streams = try outputStreams(of: object)
        var latency: UInt32 = try object.read(kAudioDevicePropertyLatency, scope: kAudioObjectPropertyScopeOutput)
        latency += try object.read(kAudioDevicePropertySafetyOffset, scope: kAudioObjectPropertyScopeOutput, as: UInt32.self)
        if let first = streams.first {
            latency += (try? first.read(kAudioStreamPropertyLatency, as: UInt32.self)) ?? 0
        }
        let resolvedDefault = if let defaultID { defaultID } else { try defaultOutputDevice() }
        return OutputDevice(
            object: object,
            uid: try object.readString(kAudioDevicePropertyDeviceUID),
            name: try object.readString(kAudioObjectPropertyName),
            isDefault: object == resolvedDefault,
            sampleRate: try object.read(kAudioDevicePropertyNominalSampleRate, as: Float64.self),
            latencyFrames: latency,
            transportType: (try? object.read(kAudioDevicePropertyTransportType, as: UInt32.self)) ?? 0,
            inputStreamCount: try inputStreams(of: object).count
        )
    }

    public static func outputStreams(of device: AudioObject) throws(CoreAudioError) -> [AudioObject] {
        try device.readArray(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput, of: AudioObjectID.self)
            .map(AudioObject.init)
    }

    public static func inputStreams(of device: AudioObject) throws(CoreAudioError) -> [AudioObject] {
        try device.readArray(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput, of: AudioObjectID.self)
            .map(AudioObject.init)
    }

    /// Every device object currently known to the HAL, including aggregates.
    public static func allDeviceObjects() throws(CoreAudioError) -> [AudioObject] {
        try AudioObject.system.readArray(kAudioHardwarePropertyDevices, of: AudioObjectID.self).map(AudioObject.init)
    }

    /// Resolves a CLI argument to one device: exact UID first, then case-insensitive name substring.
    public static func resolve(_ query: String, in devices: [OutputDevice]) -> Resolution<OutputDevice> {
        if let exact = devices.first(where: { $0.uid == query }) { return .found(exact) }
        let exactName = devices.filter { $0.name.compare(query, options: .caseInsensitive) == .orderedSame }
        if exactName.count == 1 { return .found(exactName[0]) }
        let partial = devices.filter { $0.name.range(of: query, options: .caseInsensitive) != nil }
        switch partial.count {
        case 0: return .notFound
        case 1: return .found(partial[0])
        default: return .ambiguous(partial)
        }
    }
}

public enum Resolution<Value> {
    case found(Value)
    case notFound
    case ambiguous([Value])
}

extension Resolution: Sendable where Value: Sendable {}
