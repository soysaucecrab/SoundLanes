import CoreAudio
import Synchronization

/// State shared between the IOProc and the rest of the program.
/// Lives in manually allocated memory so the IOProc touches only a raw pointer — no ARC, no locks.
public struct RouteMeters: ~Copyable {
    /// `Float` bit pattern of the linear gain (0...1).
    let volumeBits: Atomic<UInt32>
    /// `Float` bit pattern of the input peak since the last reading. Non-negative floats order like their bits.
    let peakBits: Atomic<UInt32>
    let cycles: Atomic<UInt64>
    /// Cycles where the tap buffer was missing (NULL or empty), i.e. we output silence.
    let missingInputCycles: Atomic<UInt64>

    init(volume: Float) {
        volumeBits = Atomic(volume.bitPattern)
        peakBits = Atomic(0)
        cycles = Atomic(0)
        missingInputCycles = Atomic(0)
    }
}

/// Values fixed for the lifetime of one IOProc. Captured by value in the IO block.
struct IOContext: @unchecked Sendable {
    let meters: UnsafeMutablePointer<RouteMeters>
    /// Index of the tap's buffer in the input `AudioBufferList`.
    let tapBufferIndex: Int
    /// The tap delivers stereo as two mono buffers (`tapBufferIndex`, `tapBufferIndex + 1`).
    let tapIsSplitStereo: Bool
}

enum IORenderer {
    /// Builds the IO block outside any actor so it carries no isolation and no class references.
    static func makeBlock(_ context: IOContext) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            render(context, input: input, output: output)
        }
    }

    /// Real-time render: tap (input) → device (output). No allocation, locks, logging or ARC (SPEC §4.4).
    /// Mono sources are duplicated to both channels; output channels beyond the first two are silenced;
    /// a mono output device receives the average of left and right.
    @inline(__always)
    static func render(
        _ context: IOContext,
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>
    ) {
        let meters = context.meters
        meters.pointee.cycles.wrappingAdd(1, ordering: .relaxed)
        let gain = Float(bitPattern: meters.pointee.volumeBits.load(ordering: .relaxed))

        var left: UnsafePointer<Float>?
        var right: UnsafePointer<Float>?
        var sourceStride = 0
        var sourceFrames = 0

        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        if context.tapBufferIndex < inputs.count {
            let buffer = inputs[context.tapBufferIndex]
            if let data = buffer.mData, buffer.mNumberChannels > 0, buffer.mDataByteSize > 0 {
                let channels = Int(buffer.mNumberChannels)
                let samples = UnsafePointer(data.assumingMemoryBound(to: Float.self))
                left = samples
                right = channels >= 2 ? samples + 1 : samples
                sourceStride = channels
                sourceFrames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                if context.tapIsSplitStereo, channels == 1, context.tapBufferIndex + 1 < inputs.count {
                    let second = inputs[context.tapBufferIndex + 1]
                    if let secondData = second.mData, second.mNumberChannels == 1 {
                        right = UnsafePointer(secondData.assumingMemoryBound(to: Float.self))
                        sourceFrames = min(sourceFrames, Int(second.mDataByteSize) / MemoryLayout<Float>.size)
                    }
                }
            }
        }
        if left == nil { meters.pointee.missingInputCycles.wrappingAdd(1, ordering: .relaxed) }

        let outputs = UnsafeMutableAudioBufferListPointer(output)
        var totalOutputChannels = 0
        for index in 0..<outputs.count { totalOutputChannels += Int(outputs[index].mNumberChannels) }
        let monoOutput = totalOutputChannels == 1

        var peak: Float = 0
        var channelBase = 0
        for index in 0..<outputs.count {
            let buffer = outputs[index]
            let channels = Int(buffer.mNumberChannels)
            defer { channelBase += channels }
            guard let data = buffer.mData, channels > 0 else { continue }
            let out = data.assumingMemoryBound(to: Float.self)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            var copied = 0
            if let left, let right {
                copied = min(frames, sourceFrames)
                for frame in 0..<copied {
                    let l = left[frame * sourceStride]
                    let r = right[frame * sourceStride]
                    peak = max(peak, abs(l), abs(r))
                    for channel in 0..<channels {
                        let global = channelBase + channel
                        let sample: Float = monoOutput ? (l + r) * 0.5 : global == 0 ? l : global == 1 ? r : 0
                        out[frame * channels + channel] = sample * gain
                    }
                }
            }
            if copied < frames {
                (out + copied * channels).initialize(repeating: 0, count: (frames - copied) * channels)
            }
        }
        if peak > 0 { meters.pointee.peakBits.max(peak.bitPattern, ordering: .relaxed) }
    }
}
