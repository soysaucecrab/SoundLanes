import AppKit
import SwiftUI

@main
struct SoundLanesApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: delegate.model)
        } label: {
            Image(systemName: delegate.model.isRouting ? "hifispeaker.2.fill" : "hifispeaker.2")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var signalSources: [any DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // SIGTERM/SIGINT go through normal termination so routes are torn down (CLAUDE.md).
        signalSources = [SIGTERM, SIGINT].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }
            source.resume()
            return source
        }
        Task {
            if CommandLine.arguments.contains("--demo") {
                model.loadDemo()
            } else {
                await model.start()
            }
            if let index = CommandLine.arguments.firstIndex(of: "--capture-menu"), index + 1 < CommandLine.arguments.count {
                await captureMenu(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// Development aid (`open SoundLanes.app --args --capture-menu <png>`): renders the menu content in an
    /// off-screen window and saves it. Real AppKit controls are drawn; nothing on screen is captured.
    private func captureMenu(to url: URL) async {
        let host = NSHostingView(rootView: MenuView(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.contentView = host
        try? await Task.sleep(for: .seconds(2))  // let MenuView's refresh task load devices and apps
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// `terminate:` may be called from inside a main-queue block (signal handler, MainActor task). AppKit then
    /// spins a nested run loop while the main queue stays occupied, so the teardown must not need the main actor,
    /// and the reply is delivered through the run loop instead of the main queue.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let teardown = model.detachForShutdown()
        Task.detached {
            await teardown()
            let mainLoop = CFRunLoopGetMain()
            CFRunLoopPerformBlock(mainLoop, CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
            }
            CFRunLoopWakeUp(mainLoop)
        }
        return .terminateLater
    }
}
