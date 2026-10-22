import ArgumentParser
import Foundation
import RouteCore

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "규칙을 추가하거나 같은 앱의 규칙을 바꿉니다.")

    @Argument(help: "번들 ID 또는 앱 이름 (예: com.google.Chrome, Chrome)")
    var app: String

    @Argument(help: "장치 UID 또는 이름 일부 (예: AirPods). default는 기본 출력을 따르며 음량만 조절합니다.")
    var device: String

    @Option(help: "볼륨 0.0~1.0")
    var volume: Float = 1

    func validate() throws {
        guard (0...1).contains(volume) else { throw ValidationError("볼륨은 0.0에서 1.0 사이여야 합니다.") }
    }

    func run() throws {
        let bundleID = try resolveApp(app, processes: try ProcessCatalog.processes())
        let target: DeviceRef
        if ["default", "기본"].contains(device.lowercased()) {
            target = .followDefault
        } else {
            let found = try resolveDevice(device, devices: try DeviceCatalog.outputDevices())
            target = DeviceRef(uid: found.uid, name: found.name)
        }
        let store = ConfigStore()
        var config = try writableConfig(store)
        let rule = RouteRule(
            app: AppRule(bundleID: bundleID, extraBundleIDs: AppPresets.defaultExtraBundleIDs(for: bundleID)),
            device: target, volume: volume)
        config.upsert(rule)
        try store.save(config)
        print("규칙 저장: \(bundleID) → \(target.displayName) (볼륨 \(Int((volume * 100).rounded()))%)")
        if let warning = AppPresets.warning(for: rule.app) { print("※ \(warning)") }
        notifyRunner()
    }
}

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "규칙을 삭제합니다.")

    @Argument(help: "번들 ID 또는 앱 이름")
    var app: String

    func run() throws {
        let store = ConfigStore()
        var config = try writableConfig(store)
        let bundleID: String
        if config.rule(forBundleID: app) != nil {
            bundleID = app
        } else {
            bundleID = try resolveApp(app, processes: try ProcessCatalog.processes())
        }
        guard let removed = config.remove(bundleID: bundleID) else {
            throw CLIError.badArgument("'\(app)'에 대한 규칙이 없습니다. 규칙 목록: soundlanes list")
        }
        try store.save(config)
        print("규칙 삭제: \(removed.app.bundleID) → \(removed.device.displayName)")
        notifyRunner()
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "저장된 규칙을 보여줍니다.")

    func run() throws {
        let loaded = try ConfigStore().load()
        if loaded.isReadOnly { print("※ \(ConfigError.readOnly(version: loaded.config.version).description)") }
        guard !loaded.config.routes.isEmpty else {
            print("저장된 규칙이 없습니다. 추가: soundlanes add <앱> <장치>")
            return
        }
        var table = Table("사용", "앱", "장치", "장치 UID", "볼륨")
        for rule in loaded.config.routes {
            table.add(rule.enabled ? "예" : "아니오",
                      ([rule.app.bundleID] + rule.app.extraBundleIDs).joined(separator: ", "),
                      rule.device.displayName, rule.device.uid, "\(Int((rule.volume * 100).rounded()))%")
        }
        print(table.render())
    }
}

func writableConfig(_ store: ConfigStore) throws -> RouteConfig {
    let loaded = try store.load()
    guard !loaded.isReadOnly else { throw ConfigError.readOnly(version: loaded.config.version) }
    return loaded.config
}

/// Tells a running app or `soundlanes run` to re-read the config.
func notifyRunner() {
    do {
        let response = try ControlClient.send(ControlRequest(.reload))
        if response.ok {
            print("실행 중인 \(response.owner ?? "SoundLanes")에 바로 적용했습니다.")
        } else {
            print("※ 실행 중인 인스턴스가 설정을 다시 읽지 못했습니다: \(response.error ?? "알 수 없는 오류")")
        }
    } catch ControlError.notRunning {
        print("적용하려면 SoundLanes 앱이나 soundlanes run을 실행하세요.")
    } catch {
        print("※ \(error)")
    }
}
