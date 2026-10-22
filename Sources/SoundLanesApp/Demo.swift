import CoreAudio
import Foundation
import RouteCore

extension AppModel {
    /// Development aid (`--demo`): fills the menu with example apps and devices for screenshots.
    /// No lock, engine or Core Audio objects are created.
    func loadDemo() {
        let speakers = OutputDevice(object: AudioObject(1), uid: "demo-speakers", name: "MacBook Pro Speakers", isDefault: true,
                                    sampleRate: 48_000, latencyFrames: 800, transportType: kAudioDeviceTransportTypeBuiltIn,
                                    inputStreamCount: 0)
        let airPods = OutputDevice(object: AudioObject(2), uid: "demo-airpods", name: "AirPods Pro", isDefault: false,
                                   sampleRate: 48_000, latencyFrames: 7_680, transportType: kAudioDeviceTransportTypeBluetooth,
                                   inputStreamCount: 1)
        let display = OutputDevice(object: AudioObject(3), uid: "demo-display", name: "Studio Display", isDefault: false,
                                   sampleRate: 48_000, latencyFrames: 960, transportType: kAudioDeviceTransportTypeUSB,
                                   inputStreamCount: 0)

        func app(_ id: UInt32, _ bundleID: String, _ name: String, playing: Bool) -> AudioProcess {
            AudioProcess(object: AudioObject(id), pid: pid_t(id), bundleID: bundleID, isRunningOutput: playing,
                         appName: name, appBundleID: bundleID)
        }
        let chrome = RouteRule(app: AppRule(bundleID: "com.google.Chrome"),
                               device: DeviceRef(uid: airPods.uid, name: airPods.name))
        let music = RouteRule(app: AppRule(bundleID: "com.apple.Music"),
                              device: DeviceRef(uid: display.uid, name: display.name), volume: 0.8)
        let slack = RouteRule(app: AppRule(bundleID: "com.tinyspeck.slackmacgap"), device: .followDefault, volume: 0.35)

        func status(_ rule: RouteRule, _ phase: RouteStatus.Phase, peak: Float? = nil, extra: Double? = nil) -> RouteStatus {
            RouteStatus(id: rule.id, bundleID: rule.app.bundleID, device: rule.device, volume: rule.volume, phase: phase,
                        processCount: phase == .running ? 1 : 0, message: nil, extraLatencyMilliseconds: extra,
                        inputPeak: peak, ioCycles: nil, missingInputCycles: nil)
        }

        applyDemo(
            devices: [speakers, airPods, display],
            processes: [
                app(10, "com.google.Chrome", "Google Chrome", playing: true),
                app(11, "com.apple.Music", "Music", playing: true),
                app(12, "com.tinyspeck.slackmacgap", "Slack", playing: true),
                app(13, "com.apple.podcasts", "Podcasts", playing: true),
                app(14, "com.apple.Safari", "Safari", playing: false),
                app(15, "com.kakao.KakaoTalkMac", "KakaoTalk", playing: false),
                app(16, "com.hnc.Discord", "Discord", playing: false),
            ],
            config: RouteConfig(routes: [chrome, music, slack]),
            statuses: [
                status(chrome, .running, peak: 0.42, extra: 143),
                status(music, .running, peak: 0.6),
                status(slack, .running, peak: 0.12),
            ])
    }
}
