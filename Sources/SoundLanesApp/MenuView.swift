import AppKit
import RouteCore
import SwiftUI

/// The menu bar window: one row per app with a device picker and volume slider.
struct MenuView: View {
    @Bindable var model: AppModel
    @State private var loginItem = LoginItem()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            switch model.mode {
            case .starting:
                ProgressView().frame(maxWidth: .infinity)
            case .blocked(let owner):
                blocked(owner)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .active:
                content
            }
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
        .task {
            // Refresh while the window is open; the engine keeps routing when it is closed.
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        HStack {
            Text("SoundLanes").font(.headline)
            Spacer()
            Text("앱별 출력 장치").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.needsPermission { permissionBanner }
        if model.isReadOnly {
            Label("설정 파일 버전을 알 수 없어 읽기 전용입니다.", systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.orange)
        }
        let items = model.items
        if items.isEmpty {
            Text("지금 소리를 내는 앱이 없습니다.\n앱에서 소리를 재생하면 여기에 나타납니다.")
                .font(.callout).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 8)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(items) { item in
                        AppRow(model: model, item: item)
                    }
                }
            }
            .frame(maxHeight: 420)
            .fixedSize(horizontal: false, vertical: true)
        }
        if model.hiddenAppCount > 0 || model.showAllApps {
            Toggle(model.showAllApps ? "소리를 내지 않는 앱 숨기기" : "소리를 내지 않는 앱 \(model.hiddenAppCount)개 더 보기",
                   isOn: $model.showAllApps)
                .toggleStyle(.button).buttonStyle(.link).font(.caption)
        }
        if let error = model.lastError {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("오디오 캡처 권한이 필요합니다", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.bold()).foregroundStyle(.orange)
            Text("시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음에서 SoundLanes를 켜 주세요.")
                .font(.caption).foregroundStyle(.secondary)
            Button("시스템 설정 열기") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            }
            .font(.caption)
        }
        .padding(8)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }

    private func blocked(_ owner: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("다른 곳에서 라우팅을 적용 중입니다 (\(owner)).", systemImage: "info.circle")
            Text("터미널의 soundlanes run을 종료한 뒤 다시 시도해 주세요.").font(.caption).foregroundStyle(.secondary)
            Button("다시 시도") { Task { await model.retry() } }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("로그인 시 실행", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
            if let message = loginItem.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("설정 폴더 열기") {
                    NSWorkspace.shared.open(ConfigStore.defaultDirectory)
                }
                Spacer()
                Button("SoundLanes 종료") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }
}

private struct AppRow: View {
    let model: AppModel
    let item: AppItem
    @State private var volume: Float?

    private static let followDefault = ""

    var body: some View {
        let rule = model.rule(for: item)
        let status = model.status(for: item)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(nsImage: AppIcons.icon(for: item.bundleID))
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.name).lineLimit(1)
                    if item.isPlaying {
                        Text("재생 중").font(.caption2).foregroundStyle(.green)
                    }
                }
                Spacer(minLength: 4)
                devicePicker(rule)
            }
            if let rule {
                HStack(spacing: 6) {
                    Image(systemName: "speaker.fill").font(.caption2).foregroundStyle(.secondary)
                    Slider(
                        value: Binding(get: { Double(volume ?? rule.volume) },
                                       set: { volume = Float($0); model.setVolume(Float($0), for: item, commit: false) }),
                        in: 0...1,
                        onEditingChanged: { editing in
                            if !editing, let volume { model.setVolume(volume, for: item, commit: true) }
                            if !editing { volume = nil }
                        })
                        .controlSize(.mini)
                    Image(systemName: "speaker.wave.3.fill").font(.caption2).foregroundStyle(.secondary)
                }
                .padding(.leading, 28)
                statusLine(rule: rule, status: status)
                    .padding(.leading, 28)
            }
        }
    }

    private func devicePicker(_ rule: RouteRule?) -> some View {
        let selection = Binding<String>(
            get: { rule?.device.uid ?? Self.followDefault },
            set: { model.setDevice($0 == Self.followDefault ? nil : $0, for: item) })
        return Picker("", selection: selection) {
            Text("기본 출력 따름").tag(Self.followDefault)
            Divider()
            ForEach(model.devices, id: \.uid) { device in
                Text(device.isDefault ? "\(device.name) (기본)" : device.name).tag(device.uid)
            }
            if let rule, !model.devices.contains(where: { $0.uid == rule.device.uid }) {
                Text("\(rule.device.name) (연결 안 됨)").tag(rule.device.uid)
            }
        }
        .labelsHidden()
        .frame(width: 150)
        .controlSize(.small)
    }

    @ViewBuilder
    private func statusLine(rule: RouteRule, status: RouteStatus?) -> some View {
        let phase = status?.phase ?? .noProcesses
        HStack(spacing: 4) {
            Circle().fill(color(phase)).frame(width: 6, height: 6)
            Text(detail(phase, status: status)).lineLimit(2)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        if let warning = AppPresets.warning(for: rule.app) {
            Text(warning).font(.caption2).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detail(_ phase: RouteStatus.Phase, status: RouteStatus?) -> String {
        switch phase {
        case .running:
            if let extra = status?.extraLatencyMilliseconds, abs(extra) >= 1 {
                return "라우팅 중 · 기본 출력보다 \(extra > 0 ? "+" : "")\(Int(extra.rounded())) ms"
            }
            return "라우팅 중"
        case .deviceMissing: return "장치가 연결되면 자동으로 라우팅합니다. 지금은 기본 출력으로 나갑니다."
        case .deviceIsDefault: return "이미 기본 출력이라 따로 라우팅하지 않습니다."
        case .noProcesses: return "앱이 소리를 내면 라우팅합니다."
        case .failed: return "실패: \(status?.message ?? "알 수 없는 오류") (자동 재시도)"
        case .noPermission: return "오디오 캡처 권한이 없습니다."
        case .disabled: return "꺼짐"
        }
    }

    private func color(_ phase: RouteStatus.Phase) -> Color {
        switch phase {
        case .running: .green
        case .failed, .noPermission: .red
        case .deviceMissing: .orange
        default: .gray
        }
    }
}
