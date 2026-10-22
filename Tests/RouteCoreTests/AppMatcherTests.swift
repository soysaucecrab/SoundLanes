import Foundation
import Testing
@testable import RouteCore

private func process(_ id: UInt32, _ bundleID: String, app: String = "App", appBundleID: String? = nil) -> AudioProcess {
    AudioProcess(object: AudioObject(id), pid: pid_t(id), bundleID: bundleID, isRunningOutput: true,
                 appName: app, appBundleID: appBundleID ?? bundleID)
}

@Suite struct AppMatcherTests {
    let chrome = AppRule(bundleID: "com.google.Chrome")

    @Test func matchesExactAndHelpers() {
        #expect(AppMatcher.matches(chrome, bundleID: "com.google.Chrome"))
        #expect(AppMatcher.matches(chrome, bundleID: "com.google.Chrome.helper"))
        #expect(AppMatcher.matches(chrome, bundleID: "com.google.Chrome.helper.Renderer"))
    }

    @Test func rejectsSiblingPrefixes() {
        #expect(!AppMatcher.matches(chrome, bundleID: "com.google.ChromeBeta"))
        #expect(!AppMatcher.matches(chrome, bundleID: "com.google"))
        #expect(!AppMatcher.matches(chrome, bundleID: "com.google.Chromium.helper"))
    }

    @Test func ignoresCase() {
        #expect(AppMatcher.matches(chrome, bundleID: "COM.GOOGLE.CHROME.HELPER"))
    }

    @Test func processesWithoutBundleIDNeverMatch() {
        #expect(!AppMatcher.matches(chrome, bundleID: ""))
        #expect(!AppMatcher.matches(AppRule(bundleID: ""), bundleID: ""))
        #expect(!AppMatcher.matches(AppRule(bundleID: ""), bundleID: "com.google.Chrome"))
    }

    @Test func extraBundleIDs() {
        let safari = AppRule(bundleID: "com.apple.Safari", extraBundleIDs: ["com.apple.WebKit.GPU"])
        #expect(AppMatcher.matches(safari, bundleID: "com.apple.WebKit.GPU"))
        #expect(!AppMatcher.matches(safari, bundleID: "com.apple.WebKit.WebContent"))
    }

    @Test func selectKeepsOnlyMatches() {
        let all = [process(1, "com.google.Chrome"), process(2, "com.google.Chrome.helper"),
                   process(3, "com.apple.Music"), process(4, "")]
        #expect(AppMatcher.select(chrome, from: all).map(\.object.id) == [1, 2])
    }
}

@Suite struct RoutePlannerTests {
    let rule = AppRule(bundleID: "com.google.Chrome")
    let processes = [process(7, "com.google.Chrome.helper"), process(3, "com.google.Chrome"), process(9, "com.apple.Music")]

    @Test func activeWithSortedMatches() {
        let plan = RoutePlanner.plan(rule: rule, deviceUID: "airpods", availableDeviceUIDs: ["airpods", "speaker"],
                                     defaultOutputUID: "speaker", processes: processes)
        #expect(plan == .active(processes: [AudioObject(3), AudioObject(7)], deviceUID: "airpods"))
    }

    @Test func deviceDisconnectedDeactivates() {  // S2
        let plan = RoutePlanner.plan(rule: rule, deviceUID: "airpods", availableDeviceUIDs: ["speaker"],
                                     defaultOutputUID: "speaker", processes: processes)
        #expect(plan == .inactive(.deviceMissing))
    }

    @Test func deviceIsDefaultNeedsNoTap() {  // S6
        let plan = RoutePlanner.plan(rule: rule, deviceUID: "airpods", availableDeviceUIDs: ["airpods", "speaker"],
                                     defaultOutputUID: "airpods", processes: processes)
        #expect(plan == .inactive(.deviceIsDefault))
    }

    @Test func reducedVolumeOnDefaultOutputStillTaps() {
        let plan = RoutePlanner.plan(rule: rule, deviceUID: "airpods", volume: 0.5, availableDeviceUIDs: ["airpods"],
                                     defaultOutputUID: "airpods", processes: processes)
        #expect(plan == .active(processes: [AudioObject(3), AudioObject(7)], deviceUID: "airpods"))
    }

    @Test func followDefaultTargetsCurrentDefault() {
        let full = RoutePlanner.plan(rule: rule, deviceUID: DeviceRef.followDefault.uid, availableDeviceUIDs: ["speaker"],
                                     defaultOutputUID: "speaker", processes: processes)
        #expect(full == .inactive(.deviceIsDefault))
        let quieter = RoutePlanner.plan(rule: rule, deviceUID: DeviceRef.followDefault.uid, volume: 0.3,
                                        availableDeviceUIDs: ["speaker"], defaultOutputUID: "speaker", processes: processes)
        #expect(quieter == .active(processes: [AudioObject(3), AudioObject(7)], deviceUID: "speaker"))
    }

    @Test func noMatchingProcesses() {
        let plan = RoutePlanner.plan(rule: AppRule(bundleID: "com.spotify.client"), deviceUID: "airpods",
                                     availableDeviceUIDs: ["airpods"], defaultOutputUID: "speaker", processes: processes)
        #expect(plan == .inactive(.noProcesses))
    }
}

@Suite struct ResolutionTests {
    let processes = [
        process(1, "com.google.Chrome", app: "Google Chrome"),
        process(2, "com.google.Chrome.helper", app: "Google Chrome", appBundleID: "com.google.Chrome"),
        process(3, "com.apple.Music", app: "Music"),
        process(4, "com.apple.MusicRecognition", app: "Music Recognition"),
    ]

    @Test func appByNameMapsHelpersToOuterApp() {
        guard case .found(let id) = ProcessCatalog.resolveApp("chrome", in: processes) else { Issue.record(); return }
        #expect(id == "com.google.Chrome")
    }

    @Test func exactNameBeatsSubstring() {
        guard case .found(let id) = ProcessCatalog.resolveApp("music", in: processes) else { Issue.record(); return }
        #expect(id == "com.apple.Music")
    }

    @Test func ambiguousName() {
        guard case .ambiguous(let ids) = ProcessCatalog.resolveApp("mus", in: processes) else { Issue.record(); return }
        #expect(ids == ["com.apple.Music", "com.apple.MusicRecognition"])
    }

    @Test func unknownBundleIDIsAcceptedForLaterLaunch() {
        guard case .found(let id) = ProcessCatalog.resolveApp("com.spotify.client", in: processes) else { Issue.record(); return }
        #expect(id == "com.spotify.client")
        guard case .notFound = ProcessCatalog.resolveApp("Spotify", in: processes) else { Issue.record(); return }
    }
}

@Suite struct FourCharCodeTests {
    @Test func printable() {
        #expect(fourCharCode(OSStatus(bitPattern: 0x216F_626A)) == "'!obj'")
        #expect(CoreAudioError(OSStatus(bitPattern: 0x216F_626A), "Op").code == "'!obj'")
    }

    @Test func nonPrintableFallsBackToDecimal() {
        #expect(fourCharCode(-50) == "-50")
    }
}
