import ArgumentParser
import Dispatch
import Foundation
import RouteCore

struct Once: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "설정을 저장하지 않고 앱 하나를 장치 하나로 바로 라우팅합니다. Ctrl+C로 정리 후 종료합니다.")

    @Argument(help: "번들 ID 또는 앱 이름 (예: com.google.Chrome, Chrome)")
    var app: String

    @Argument(help: "장치 UID 또는 이름 일부 (예: AirPods)")
    var device: String

    @Flag(name: .long, help: "1초마다 입력 레벨을 표시합니다.")
    var meter = false

    @Flag(name: .long, help: "출력 장치의 입력(마이크) 스트림을 끄지 않습니다. M0 음질 비교용입니다.")
    var keepDeviceInput = false

    func run() async throws {
        let lock = try acquireRunLock(owner: "soundlanes once")
        let system = CoreAudioSystem(keepDeviceInput: keepDeviceInput)
        system.removeStaleRoutes()

        let processes = try ProcessCatalog.processes()
        let bundleID = try resolveApp(app, processes: processes)
        let target = try resolveDevice(device, devices: try DeviceCatalog.outputDevices())
        let appName = processes.first(where: { $0.appBundleID == bundleID })?.appName ?? bundleID
        let rule = RouteRule(
            app: AppRule(bundleID: bundleID, extraBundleIDs: AppPresets.defaultExtraBundleIDs(for: bundleID)),
            device: DeviceRef(uid: target.uid, name: target.name))

        print("\(appName) (\(bundleID)) → \(target.name) 라우팅을 시작합니다. 종료하려면 Ctrl+C를 누르세요.")
        if let warning = AppPresets.warning(for: rule.app) { print("  ※ \(warning)") }
        if target.isBluetooth, !keepDeviceInput {
            print("  Bluetooth 장치입니다. 마이크 스트림을 꺼서 고음질 모드를 유지하도록 시도합니다.")
        }
        print("  처음 실행하면 권한 확인 창이 뜰 수 있습니다. 응답할 때까지 시작이 멈춰 있습니다.")

        let engine = RouteEngine(system: system)
        let stop = StopRequests()
        let printer = Task {
            for await event in engine.events {
                print(describe(event.kind, deviceName: target.name))
                if case .started(_, let diagnostics?) = event.kind {
                    printDiagnostics(diagnostics)
                    Task { await checkSampleRateDrop(device: target, before: diagnostics.deviceSampleRateBefore) }
                }
            }
        }
        let monitor = Task { await monitorLevels(engine, ruleID: rule.id, stop: stop) }
        do {
            try await engine.start(rules: [rule])
        } catch {
            await engine.stop()
            throw error
        }

        let reason = await stop.wait()
        monitor.cancel()
        await engine.stop()
        await printer.value
        withExtendedLifetime(lock) {}
        switch reason {
        case .signal(let number):
            print("\n\(signalName(number)) 수신: 라우트를 정리했습니다. 소리는 기본 출력으로 돌아갑니다.")
        case .permissionDenied:
            throw CLIError(message: permissionMessage(), code: ExitStatus.permissionDenied)
        }
    }

    private func printDiagnostics(_ d: RouteDiagnostics) {
        print("  탭 포맷: \(formatRate(d.tapSampleRate)), \(d.tapChannels)채널\(d.tapInterleaved ? "" : " (non-interleaved)")")
        print("  출력 장치 샘플레이트: \(formatRate(d.deviceSampleRateBefore)) → 시작 직후 \(formatRate(d.deviceSampleRateAfter))")
        print("  aggregate 샘플레이트: \(formatRate(d.aggregateSampleRate)), 출력 \(d.aggregateOutputChannels)채널")
        print("  aggregate 입력 스트림 \(d.aggregateInputStreams)개 (장치 입력 \(d.deviceInputStreams)개, 끈 것 \(d.disabledInputStreams)개, 탭 버퍼 위치 \(d.tapBufferIndex))")
        if d.tapSampleRate != d.deviceSampleRateAfter {
            print("  ※ 탭과 출력 장치의 샘플레이트가 다릅니다. 소리의 높낮이·속도가 정상인지 확인해 주세요 (SPEC §13-2).")
        }
    }

    /// Bluetooth headsets drop to 16/24 kHz when they switch to the call (HFP) profile.
    private func checkSampleRateDrop(device: OutputDevice, before: Double) async {
        try? await Task.sleep(for: .seconds(2))
        guard let now = try? DeviceCatalog.describe(device.object).sampleRate, now != before else { return }
        print("  ※ \(device.name)의 샘플레이트가 \(formatRate(before)) → \(formatRate(now))로 바뀌었습니다. 통화 모드(저음질)로 바뀌었을 수 있습니다.")
    }

    private func monitorLevels(_ engine: RouteEngine, ruleID: UUID, stop: StopRequests) async {
        var silentSeconds = 0
        var hinted = false
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            if await engine.status().first?.phase == .noPermission {
                stop.request(.permissionDenied)
                return
            }
            guard let reading = await engine.takeReading(for: ruleID) else { silentSeconds = 0; continue }
            if meter {
                let db = reading.peak > 0 ? 20 * log10(reading.peak) : -.infinity
                let level = db.isFinite ? String(format: "%6.1f dBFS", db) : "  무음    "
                print("  레벨 \(level)  IO 주기 \(reading.cycles)  탭 버퍼 없음 \(reading.missingInputCycles)")
            }
            silentSeconds = reading.peak > 0 ? 0 : silentSeconds + 1
            if silentSeconds == 5, !hinted {
                hinted = true
                print("  ※ 5초 동안 입력이 무음입니다. 앱이 실제로 재생 중인지 확인해 주세요.")
            }
        }
    }
}

/// Without audio-capture permission the HAL accepts `AudioDeviceStart` but never runs IO
/// (coreaudiod logs "Client is not granted access to the tap.").
func permissionMessage() -> String {
    let terminal = ProcessInfo.processInfo.environment["TERM_PROGRAM"].map { "터미널 앱(\($0))" } ?? "터미널 앱"
    return """
        오디오 캡처 권한이 없어 앱 소리를 가져올 수 없습니다.
        터미널에서 실행하면 권한은 \(terminal)에 적용됩니다. SoundLanes 앱을 쓰거나, 다음 위치에 그 앱을 추가한 뒤 다시 실행해 주세요:
          시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음 > 시스템 오디오 녹음만
        """
}

func describe(_ kind: RouteEngine.EventKind, deviceName: String, appLabel: String? = nil) -> String {
    let prefix = appLabel.map { "[\($0)] " } ?? ""
    let body: String = switch kind {
    case .started(let processes, _):
        "라우팅 중 → \(deviceName): \(describe(processes))"
    case .updated(let processes, .inPlace):
        "대상 프로세스 변경 → 탭 설명을 그대로 갱신함: \(describe(processes))"
    case .updated(let processes, .recreated(let reason)):
        "대상 프로세스 변경 → 탭 갱신이 거부되어 다시 만듦 (\(reason)): \(describe(processes))"
    case .inactive(.deviceMissing):
        "대기 중: \(deviceName)이(가) 연결되어 있지 않습니다. 소리는 기본 출력으로 나갑니다."
    case .inactive(.deviceIsDefault):
        "대기 중: \(deviceName)이(가) 이미 기본 출력이라 탭을 만들지 않습니다."
    case .inactive(.noProcesses):
        "대기 중: 일치하는 오디오 프로세스가 없습니다. 앱에서 소리를 재생하면 자동으로 시작합니다."
    case .inactive(let phase):
        "대기 중: \(phase.label)"
    case .failed(let message, let retryIn):
        "실패: \(message). \(retryIn.components.seconds)초 뒤 다시 시도합니다."
    }
    return prefix + body
}

private func describe(_ processes: [AudioProcess]) -> String {
    processes.map { "\($0.bundleID) (PID \($0.pid))" }.joined(separator: ", ")
}

func signalName(_ number: Int32) -> String { number == SIGTERM ? "SIGTERM" : "Ctrl+C" }

func acquireRunLock(owner: String) throws -> InstanceLock {
    guard let lock = try InstanceLock.acquire(owner: owner) else {
        let holder = InstanceLock.currentOwner() ?? "다른 프로세스"
        throw CLIError(message: "이미 라우팅을 적용 중인 인스턴스가 있습니다 (\(holder)). 하나만 실행할 수 있습니다.",
                       code: ExitStatus.general)
    }
    return lock
}

func resolveApp(_ query: String, processes: [AudioProcess]) throws -> String {
    switch ProcessCatalog.resolveApp(query, in: processes) {
    case .found(let bundleID):
        return bundleID
    case .notFound:
        throw CLIError.badArgument("'\(query)'와 일치하는 앱이 없습니다. 오디오를 쓰는 앱 목록: soundlanes apps --all")
    case .ambiguous(let candidates):
        throw CLIError.badArgument("'\(query)'와 일치하는 앱이 여러 개입니다. 번들 ID로 지정해 주세요:\n"
            + candidates.map { "  \($0)" }.joined(separator: "\n"))
    }
}

func resolveDevice(_ query: String, devices: [OutputDevice]) throws -> OutputDevice {
    switch DeviceCatalog.resolve(query, in: devices) {
    case .found(let device):
        return device
    case .notFound:
        throw CLIError.badArgument("'\(query)'와 일치하는 출력 장치가 없습니다. 장치 목록: soundlanes devices")
    case .ambiguous(let candidates):
        throw CLIError.badArgument("'\(query)'와 일치하는 장치가 여러 개입니다. UID로 지정해 주세요:\n"
            + candidates.map { "  \($0.name)  \($0.uid)" }.joined(separator: "\n"))
    }
}

enum StopReason: Sendable {
    case signal(Int32)
    case permissionDenied
}

/// Collects reasons to stop: SIGINT/SIGTERM or an internal request.
/// The default signal handlers are disabled so cleanup always runs.
final class StopRequests: Sendable {
    private let stream: AsyncStream<StopReason>
    private let continuation: AsyncStream<StopReason>.Continuation
    private let sources: [any DispatchSourceSignal]

    init() {
        let (stream, continuation) = AsyncStream.makeStream(of: StopReason.self)
        self.stream = stream
        self.continuation = continuation
        sources = [SIGINT, SIGTERM].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { continuation.yield(.signal(number)) }
            source.resume()
            return source
        }
    }

    func request(_ reason: StopReason) { continuation.yield(reason) }

    func wait() async -> StopReason {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next() ?? .signal(SIGTERM)
    }
}
