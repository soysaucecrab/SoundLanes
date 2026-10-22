import CoreAudio
import Darwin
import Foundation

/// A process known to the HAL as an audio client.
public struct AudioProcess: Hashable, Sendable {
    public let object: AudioObject
    public let pid: pid_t
    /// The process's own bundle ID (for helpers, e.g. `com.google.Chrome.helper`). Empty if none.
    public let bundleID: String
    public let isRunningOutput: Bool
    /// The outermost `.app` bundle containing the executable, e.g. "Google Chrome" for its helpers.
    public let appName: String
    /// Bundle ID of that outermost `.app`, so a helper can be traced back to the app the user knows.
    public let appBundleID: String
    /// The executable lives inside an `.app` bundle (false for daemons and XPC services).
    public let isApp: Bool

    public init(object: AudioObject, pid: pid_t, bundleID: String, isRunningOutput: Bool,
                appName: String, appBundleID: String, isApp: Bool = true) {
        self.object = object
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
        self.appName = appName
        self.appBundleID = appBundleID
        self.isApp = isApp
    }
}

public enum ProcessCatalog {
    /// All audio processes except this one.
    public static func processes() throws(CoreAudioError) -> [AudioProcess] {
        let ownPID = getpid()
        var result: [AudioProcess] = []
        for id in try AudioObject.system.readArray(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self) {
            let object = AudioObject(id)
            // Processes exit between listing and querying; drop those instead of failing.
            guard let pid = try? object.read(kAudioProcessPropertyPID, as: pid_t.self), pid != ownPID else { continue }
            let bundleID = (try? object.readString(kAudioProcessPropertyBundleID)) ?? ""
            let running = ((try? object.read(kAudioProcessPropertyIsRunningOutput, as: UInt32.self)) ?? 0) != 0
            let app = outerApp(of: pid)
            result.append(AudioProcess(
                object: object, pid: pid, bundleID: bundleID, isRunningOutput: running,
                appName: app?.name ?? executableName(of: pid) ?? bundleID,
                appBundleID: app?.bundleID ?? bundleID, isApp: app != nil))
        }
        return result
    }

    /// Resolves a CLI `<app>` argument to a bundle ID.
    /// Accepts an exact bundle ID (even if not running) or a case-insensitive app-name substring.
    public static func resolveApp(_ query: String, in processes: [AudioProcess]) -> Resolution<String> {
        let apps = Dictionary(processes.map { ($0.appBundleID, $0.appName) }, uniquingKeysWith: { first, _ in first })
            .filter { !$0.key.isEmpty }
        if let exact = apps.keys.first(where: { $0.compare(query, options: .caseInsensitive) == .orderedSame }) {
            return .found(exact)
        }
        let exactName = apps.filter { $0.value.compare(query, options: .caseInsensitive) == .orderedSame }
        if exactName.count == 1 { return .found(exactName.keys.first!) }
        let partial = apps.filter { $0.value.range(of: query, options: .caseInsensitive) != nil }.keys.sorted()
        switch partial.count {
        case 0:
            // Looks like a bundle ID: allow routing an app that has not started audio yet.
            return query.contains(".") && !query.contains(" ") ? .found(query) : .notFound
        case 1: return .found(partial[0])
        default: return .ambiguous(partial)
        }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func executableName(of pid: pid_t) -> String? {
        executablePath(of: pid).map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    private static func outerApp(of pid: pid_t) -> (name: String, bundleID: String)? {
        guard let path = executablePath(of: pid),
              let range = path.range(of: ".app/") else { return nil }
        let bundlePath = String(path[..<range.lowerBound]) + ".app"
        let name = URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
        let bundleID = Bundle(path: bundlePath)?.bundleIdentifier ?? ""
        return (name, bundleID)
    }
}
