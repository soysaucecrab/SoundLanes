import CoreAudio
import Testing
@testable import RouteCore

/// Owns an `AudioBufferList` and its sample memory for one test.
private final class TestBufferList {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []

    /// `buffers[i] == nil` produces a NULL `mData` (a disabled stream).
    init(_ buffers: [(channels: Int, samples: [Float]?)]) {
        list = AudioBufferList.allocate(maximumBuffers: buffers.count)
        for (index, buffer) in buffers.enumerated() {
            var data: UnsafeMutableRawPointer?
            var size = 0
            if let samples = buffer.samples {
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: samples.count)
                pointer.initialize(from: samples, count: samples.count)
                storage.append(pointer)
                data = UnsafeMutableRawPointer(pointer)
                size = samples.count * MemoryLayout<Float>.size
            }
            list[index] = AudioBuffer(mNumberChannels: UInt32(buffer.channels), mDataByteSize: UInt32(size), mData: data)
        }
    }

    func samples(_ index: Int) -> [Float] {
        let buffer = list[index]
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(start: buffer.mData!.assumingMemoryBound(to: Float.self), count: count))
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }
}

private final class Meters {
    let pointer = UnsafeMutablePointer<RouteMeters>.allocate(capacity: 1)
    init(volume: Float = 1) { pointer.initialize(to: RouteMeters(volume: volume)) }
    deinit { pointer.deinitialize(count: 1); pointer.deallocate() }
    var peak: Float { Float(bitPattern: pointer.pointee.peakBits.load(ordering: .relaxed)) }
    var missing: UInt64 { pointer.pointee.missingInputCycles.load(ordering: .relaxed) }
}

private func render(_ meters: Meters, _ input: TestBufferList, _ output: TestBufferList,
                    tapIndex: Int = 0, split: Bool = false) {
    let context = IOContext(meters: meters.pointer, tapBufferIndex: tapIndex, tapIsSplitStereo: split)
    IORenderer.render(context, input: UnsafePointer(input.list.unsafePointer), output: output.list.unsafeMutablePointer)
}

@Suite struct IORendererTests {
    @Test func copiesStereoWithGain() {
        let meters = Meters(volume: 0.5)
        let input = TestBufferList([(2, [0.2, -0.4, 0.6, -0.8])])
        let output = TestBufferList([(2, [Float](repeating: 9, count: 4))])
        render(meters, input, output)
        #expect(output.samples(0) == [0.1, -0.2, 0.3, -0.4])
        #expect(meters.peak == 0.8)
    }

    @Test func monoSourceIsDuplicated() {
        let input = TestBufferList([(1, [0.5, 0.25])])
        let output = TestBufferList([(2, [Float](repeating: 9, count: 4))])
        render(Meters(), input, output)
        #expect(output.samples(0) == [0.5, 0.5, 0.25, 0.25])
    }

    @Test func extraOutputChannelsAreSilenced() {
        let input = TestBufferList([(2, [0.1, 0.2])])
        let output = TestBufferList([(4, [Float](repeating: 9, count: 4))])
        render(Meters(), input, output)
        #expect(output.samples(0) == [0.1, 0.2, 0, 0])
    }

    @Test func monoOutputGetsAverage() {
        let input = TestBufferList([(2, [0.2, 0.4])])
        let output = TestBufferList([(1, [9])])
        render(Meters(), input, output)
        #expect(abs(output.samples(0)[0] - 0.3) < 1e-6)
    }

    @Test func nonInterleavedOutputBuffers() {
        let input = TestBufferList([(2, [0.1, 0.2, 0.3, 0.4])])
        let output = TestBufferList([(1, [9, 9]), (1, [9, 9])])
        render(Meters(), input, output)
        #expect(output.samples(0) == [0.1, 0.3])
        #expect(output.samples(1) == [0.2, 0.4])
    }

    @Test func usesTapBufferAfterDisabledDeviceInput() {
        let input = TestBufferList([(1, nil), (2, [0.1, 0.2])])
        let output = TestBufferList([(2, [9, 9])])
        render(Meters(), input, output, tapIndex: 1)
        #expect(output.samples(0) == [0.1, 0.2])
    }

    @Test func splitStereoTap() {
        let input = TestBufferList([(1, [0.1, 0.3]), (1, [0.2, 0.4])])
        let output = TestBufferList([(2, [9, 9, 9, 9])])
        render(Meters(), input, output, split: true)
        #expect(output.samples(0) == [0.1, 0.2, 0.3, 0.4])
    }

    @Test func missingInputProducesSilence() {
        let meters = Meters()
        let input = TestBufferList([(2, nil)])
        let output = TestBufferList([(2, [9, 9, 9, 9])])
        render(meters, input, output)
        #expect(output.samples(0) == [0, 0, 0, 0])
        #expect(meters.missing == 1)
    }

    @Test func shortInputZeroFillsTail() {
        let input = TestBufferList([(2, [0.1, 0.2])])
        let output = TestBufferList([(2, [9, 9, 9, 9])])
        render(Meters(), input, output)
        #expect(output.samples(0) == [0.1, 0.2, 0, 0])
    }
}
