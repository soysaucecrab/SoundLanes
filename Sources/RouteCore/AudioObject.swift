import CoreAudio
import Foundation

/// A failed Core Audio call. `status` is the raw `OSStatus`; `operation` names the API that failed.
public struct CoreAudioError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public let operation: String

    public init(_ status: OSStatus, _ operation: String) {
        self.status = status
        self.operation = operation
    }

    /// Four-character form such as `'!obj'`, or the decimal value when it is not printable.
    public var code: String { fourCharCode(status) }

    public var description: String { "Core Audio 오류: \(operation) 실패 (\(code), \(status))" }
}

/// Formats an `OSStatus`/`FourCharCode` as `'abcd'` when all four bytes are printable ASCII.
public func fourCharCode(_ status: OSStatus) -> String {
    let value = UInt32(bitPattern: status)
    let bytes = [24, 16, 8, 0].map { UInt8((value >> UInt32($0)) & 0xFF) }
    guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return String(status) }
    return "'" + String(decoding: bytes, as: UTF8.self) + "'"
}

@inline(__always)
func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws(CoreAudioError) {
    guard status == noErr else { throw CoreAudioError(status, operation()) }
}

// MARK: - AudioObject

/// Thin, typed wrapper over `AudioObjectGetPropertyData` and friends.
/// Every other file must go through this type instead of calling the C API directly.
public struct AudioObject: Hashable, Sendable, CustomStringConvertible {
    public let id: AudioObjectID

    public init(_ id: AudioObjectID) { self.id = id }

    public static let system = AudioObject(AudioObjectID(kAudioObjectSystemObject))
    public static let unknown = AudioObject(AudioObjectID(kAudioObjectUnknown))

    public var isUnknown: Bool { id == AudioObjectID(kAudioObjectUnknown) }
    public var description: String { "AudioObject(\(id))" }

    public func has(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> Bool {
        var address = Self.address(selector, scope)
        return AudioObjectHasProperty(id, &address)
    }

    /// Reads a fixed-size value (integers, `Float64`, `AudioStreamBasicDescription`, ...).
    public func read<T: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        as type: T.Type = T.self
    ) throws(CoreAudioError) -> T {
        try readValue(selector, scope: scope, qualifier: nil, qualifierSize: 0)
    }

    /// Reads a fixed-size value using a qualifier (e.g. a `pid_t` for `TranslatePIDToProcessObject`).
    public func read<T: BitwiseCopyable, Q: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        qualifier: Q,
        as type: T.Type = T.self
    ) throws(CoreAudioError) -> T {
        var qualifier = qualifier
        return try withUnsafePointer(to: &qualifier) { (pointer) throws(CoreAudioError) -> T in
            try readValue(selector, scope: scope, qualifier: pointer, qualifierSize: UInt32(MemoryLayout<Q>.size))
        }
    }

    private func readValue<T: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        qualifier: UnsafeRawPointer?,
        qualifierSize: UInt32
    ) throws(CoreAudioError) -> T {
        var address = Self.address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: MemoryLayout<T>.size, alignment: MemoryLayout<T>.alignment)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: MemoryLayout<T>.size)
        try check(
            AudioObjectGetPropertyData(id, &address, qualifierSize, qualifier, &size, buffer),
            "AudioObjectGetPropertyData(\(fourCharCode(OSStatus(bitPattern: selector))))")
        return buffer.load(as: T.self)
    }

    /// Reads a variable-length array property (object lists, stream lists, ...).
    public func readArray<T: BitwiseCopyable>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of type: T.Type = T.self
    ) throws(CoreAudioError) -> [T] {
        var address = Self.address(selector, scope)
        let name = fourCharCode(OSStatus(bitPattern: selector))
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size),
                  "AudioObjectGetPropertyDataSize(\(name))")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        var status: OSStatus = noErr
        let result = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
            status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer.baseAddress!)
            initialized = status == noErr ? Int(size) / MemoryLayout<T>.stride : 0
        }
        try check(status, "AudioObjectGetPropertyData(\(name))")
        return result
    }

    /// Reads a `CFString` property. The HAL returns it retained, so we take ownership.
    public func readString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws(CoreAudioError) -> String {
        var address = Self.address(selector, scope)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        try check(status, "AudioObjectGetPropertyData(\(fourCharCode(OSStatus(bitPattern: selector))))")
        return value.map { $0.takeRetainedValue() as String } ?? ""
    }

    /// Writes a value whose in-memory representation is the property data.
    /// For Objective-C objects (e.g. `CATapDescription`) this passes a pointer to the reference, as the HAL expects.
    public func write<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        value: T
    ) throws(CoreAudioError) {
        var value = value
        let status = withUnsafePointer(to: &value) {
            writeRaw(selector, scope: scope, data: UnsafeRawPointer($0), size: UInt32(MemoryLayout<T>.size))
        }
        try check(status, "AudioObjectSetPropertyData(\(fourCharCode(OSStatus(bitPattern: selector))))")
    }

    /// Writes raw bytes, for variable-length structs such as `AudioHardwareIOProcStreamUsage`.
    public func write(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        bytes: UnsafeRawPointer,
        size: Int
    ) throws(CoreAudioError) {
        try check(writeRaw(selector, scope: scope, data: bytes, size: UInt32(size)),
                  "AudioObjectSetPropertyData(\(fourCharCode(OSStatus(bitPattern: selector))))")
    }

    private func writeRaw(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        data: UnsafeRawPointer,
        size: UInt32
    ) -> OSStatus {
        var address = Self.address(selector, scope)
        return AudioObjectSetPropertyData(id, &address, 0, nil, size, data)
    }

    /// Registers a listener. The callback only receives the selector; it must hand off work, not do it.
    public func addListener(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        queue: DispatchQueue,
        onChange: @escaping @Sendable (AudioObjectPropertySelector) -> Void
    ) throws(CoreAudioError) -> PropertyListener {
        let listener = PropertyListener(object: self, address: Self.address(selector, scope), onChange: onChange)
        var address = listener.address
        try check(AudioObjectAddPropertyListenerBlock(id, &address, queue, listener.block),
                  "AudioObjectAddPropertyListenerBlock(\(fourCharCode(OSStatus(bitPattern: selector))))")
        listener.queue = queue
        return listener
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

/// A registered property listener. Call `cancel()` (or drop it) to unregister.
public final class PropertyListener: @unchecked Sendable {
    let object: AudioObject
    let address: AudioObjectPropertyAddress
    let block: AudioObjectPropertyListenerBlock
    var queue: DispatchQueue?

    init(object: AudioObject, address: AudioObjectPropertyAddress,
         onChange: @escaping @Sendable (AudioObjectPropertySelector) -> Void) {
        self.object = object
        self.address = address
        self.block = Self.makeBlock(onChange)
        // `queue` is set only after registration succeeds, so a failed add never triggers a remove.
    }

    private nonisolated static func makeBlock(
        _ onChange: @escaping @Sendable (AudioObjectPropertySelector) -> Void
    ) -> AudioObjectPropertyListenerBlock {
        { count, addresses in
            for index in 0..<Int(count) { onChange(addresses[index].mSelector) }
        }
    }

    public func cancel() {
        guard let queue else { return }
        self.queue = nil
        var address = address
        // Removal fails only if the object is already gone, which is fine during teardown.
        _ = AudioObjectRemovePropertyListenerBlock(object.id, &address, queue, block)
    }

    deinit { cancel() }
}

// MARK: - Hardware-level calls

/// Wrappers for the non-property Core Audio calls (taps, aggregate devices, IOProcs).
public enum AudioHardware {
    public static func createProcessTap(_ description: CATapDescription) throws(CoreAudioError) -> AudioObject {
        var tapID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tapID), "AudioHardwareCreateProcessTap")
        return AudioObject(tapID)
    }

    public static func destroyProcessTap(_ tap: AudioObject) throws(CoreAudioError) {
        try check(AudioHardwareDestroyProcessTap(tap.id), "AudioHardwareDestroyProcessTap")
    }

    public static func createAggregateDevice(_ description: [String: Any]) throws(CoreAudioError) -> AudioObject {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID),
                  "AudioHardwareCreateAggregateDevice")
        return AudioObject(deviceID)
    }

    public static func destroyAggregateDevice(_ device: AudioObject) throws(CoreAudioError) {
        try check(AudioHardwareDestroyAggregateDevice(device.id), "AudioHardwareDestroyAggregateDevice")
    }

    /// `queue == nil` runs the block directly on the HAL's real-time IO thread.
    public static func createIOProc(
        on device: AudioObject,
        queue: DispatchQueue? = nil,
        block: @escaping AudioDeviceIOBlock
    ) throws(CoreAudioError) -> AudioDeviceIOProcID {
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, queue, block),
                  "AudioDeviceCreateIOProcIDWithBlock")
        guard let procID else { throw CoreAudioError(kAudioHardwareUnspecifiedError, "AudioDeviceCreateIOProcIDWithBlock") }
        return procID
    }

    public static func destroyIOProc(_ procID: AudioDeviceIOProcID, on device: AudioObject) throws(CoreAudioError) {
        try check(AudioDeviceDestroyIOProcID(device.id, procID), "AudioDeviceDestroyIOProcID")
    }

    public static func start(_ device: AudioObject, procID: AudioDeviceIOProcID) throws(CoreAudioError) {
        try check(AudioDeviceStart(device.id, procID), "AudioDeviceStart")
    }

    public static func stop(_ device: AudioObject, procID: AudioDeviceIOProcID) throws(CoreAudioError) {
        try check(AudioDeviceStop(device.id, procID), "AudioDeviceStop")
    }
}
