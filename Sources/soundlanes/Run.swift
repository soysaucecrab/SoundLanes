import ArgumentParser
import Foundation
import RouteCore

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "저장된 규칙을 포그라운드에서 적용합니다. Ctrl+C로 정리 후 종료합니다.")

    func run() async throws {
        let owner = "soundlanes run"
        let lock = try acquireRunLock(owner: owner)
        let store = ConfigStore()
        let loaded = try store.load()
        if loaded.isReadOnly { print("※ \(ConfigError.readOnly(version: loaded.config.version).description)") }

        let system = CoreAudioSystem()
        system.removeStaleRoutes()
        let engine = RouteEngine(system: system)
        let book = RuleBook(loaded.config.routes)

        let server = try ControlServer { request in
            switch request.command {
            case .status:
                return ControlResponse(ok: true, owner: owner, routes: await engine.status())
            case .reload:
                do {
                    let rules = try store.load().config.routes
                    await book.set(rules)
                    await engine.setRules(rules)
                    print("설정을 다시 읽었습니다: 규칙 \(rules.count)개")
                    return ControlResponse(ok: true, owner: owner)
                } catch {
                    return ControlResponse(ok: false, owner: owner, error: String(describing: error))
                }
            }
        }
        let printer = Task {
            for await event in engine.events {
                let rule = await book.rule(event.ruleID)
                print(describe(event.kind, deviceName: rule?.device.name ?? "?", appLabel: rule?.app.bundleID))
            }
        }

        let stop = StopRequests()
        do {
            try await engine.start(rules: loaded.config.routes)
        } catch {
            await engine.stop()
            server.stop()
            throw error
        }
        print(loaded.config.routes.isEmpty
            ? "저장된 규칙이 없습니다. 다른 터미널에서 soundlanes add로 추가하면 바로 적용됩니다."
            : "규칙 \(loaded.config.routes.count)개를 적용합니다. 상태: soundlanes status, 종료: Ctrl+C")

        let reason = await stop.wait()
        await engine.stop()
        server.stop()
        await printer.value
        withExtendedLifetime(lock) {}
        if case .signal(let number) = reason {
            print("\n\(signalName(number)) 수신: 모든 라우트를 정리했습니다.")
        }
    }
}

/// Rule lookup for printing events; updated on reload.
actor RuleBook {
    private var rules: [UUID: RouteRule]

    init(_ rules: [RouteRule]) { self.rules = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) }) }

    func set(_ newRules: [RouteRule]) { rules = Dictionary(uniqueKeysWithValues: newRules.map { ($0.id, $0) }) }

    func rule(_ id: UUID) -> RouteRule? { rules[id] }
}

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "실행 중인 인스턴스의 라우트 상태를 보여줍니다.")

    func run() throws {
        let response: ControlResponse
        do {
            response = try ControlClient.send(ControlRequest(.status))
        } catch let error as ControlError {
            throw CLIError(message: error.description, code: ExitStatus.general)
        }
        guard response.ok, let routes = response.routes else {
            throw CLIError(message: response.error ?? "상태를 가져오지 못했습니다.", code: ExitStatus.general)
        }
        print("실행 중: \(response.owner ?? "SoundLanes")")
        guard !routes.isEmpty else {
            print("규칙이 없습니다.")
            return
        }
        var table = Table("앱", "장치", "상태", "프로세스", "추가 지연", "입력 레벨", "IO 주기", "메시지")
        for route in routes {
            table.add(route.bundleID, route.device.name, route.phase.label, String(route.processCount),
                      route.extraLatencyMilliseconds.map { String(format: "%+.0f ms", $0) } ?? "",
                      route.inputPeak.map { $0 > 0 ? String(format: "%.1f dBFS", 20 * log10($0)) : "무음" } ?? "",
                      route.ioCycles.map(String.init) ?? "",
                      route.message ?? "")
        }
        print(table.render())
        if routes.contains(where: { $0.phase == .noPermission }) {
            print("\n※ " + permissionMessage())
        }
    }
}
