// Plays `silence` seconds of silence, then a sine tone for `seconds`, on the default output.
// Has its own bundle ID (com.zinu.soundlanes.tonetest) so SoundLanes can route it.
// usage: tone-player <silence> <seconds> <frequency> <amplitude> [outputDeviceUID]
import AVFoundation
import CoreAudio

let args = CommandLine.arguments.dropFirst().prefix(4).compactMap(Double.init)
let (silence, seconds, frequency, amplitude) = (args[0], args[1], args[2], args[3])
let engine = AVAudioEngine()
let player = AVAudioPlayerNode()
let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
engine.attach(player)
engine.connect(player, to: engine.mainMixerNode, format: format)
let frames = AVAudioFrameCount((silence + seconds) * 48_000)
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
buffer.frameLength = frames
let toneStart = Int(silence * 48_000)
for channel in 0..<2 {
    let samples = buffer.floatChannelData![channel]
    for frame in 0..<Int(frames) {
        samples[frame] = frame < toneStart ? 0 : Float(amplitude * sin(2 * .pi * frequency * Double(frame) / 48_000))
    }
}
if CommandLine.arguments.count > 5 {
    var cfUID = CommandLine.arguments[5] as CFString
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    _ = withUnsafePointer(to: &cfUID) {
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                   UInt32(MemoryLayout<CFString>.size), $0, &size, &deviceID)
    }
    AudioUnitSetProperty(engine.outputNode.audioUnit!, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                         &deviceID, UInt32(MemoryLayout<AudioObjectID>.size))
}
try engine.start()
player.scheduleBuffer(buffer)
player.play()
Thread.sleep(forTimeInterval: silence + seconds + 0.2)
engine.stop()
