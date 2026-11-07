import Darwin

/// Finds the process macOS holds responsible for another one, e.g. the app behind its
/// `com.apple.WebKit.GPU` XPC process or a helper (SPEC §5.1).
/// Uses `responsibility_get_pid_responsible_for_pid`, a private libsystem function looked up at run time.
/// If it is missing, lookups return nil and matching falls back to bundle IDs.
public enum ResponsibleProcess {
    private typealias Lookup = @convention(c) (pid_t) -> pid_t

    private static let lookup: Lookup? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(symbol, to: Lookup.self)
    }()

    public static var isAvailable: Bool { lookup != nil }

    /// The responsible process, or nil if unknown or the same process.
    public static func pid(for pid: pid_t) -> pid_t? {
        guard let lookup else { return nil }
        let owner = lookup(pid)
        return owner > 0 && owner != pid ? owner : nil
    }
}
