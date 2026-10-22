import AppKit
import CoreAudio
import RouteCore
import SwiftUI

/// The menu bar window: a card per app with a device menu, volume and a live level meter.
struct MenuView: View {
    @Bindable var model: AppModel
    @State private var loginItem = LoginItem()

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)
            Divider()
            Group {
                switch model.mode {
                case .starting:
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(24)
                case .blocked(let owner):
                    blocked(owner).padding(14)
                case .failed(let message):
                    Notice(symbol: "exclamationmark.triangle.fill", tint: .red, title: "시작하지 못했습니다", detail: message)
                        .padding(14)
                case .active:
                    content
                }
            }
            Divider()
            footer
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 380)
        // Refresh only while the window is open; the engine keeps routing when it is closed.
        .task {
            while !Task.isCancelled {
                await model.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                await model.refreshStatuses()
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("SoundLanes").font(.system(size: 14, weight: .semibold))
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let device = model.defaultDevice {
                HStack(spacing: 4) {
                    Image(systemName: DeviceSymbol.name(for: device))
                    Text(device.name).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: Capsule())
                .help("시스템 기본 출력")
                .frame(maxWidth: 150, alignment: .trailing)
            }
        }
    }

    private var summary: String {
        switch model.runningCount {
        case 0: model.config.routes.isEmpty ? "앱을 골라 출력 장치를 지정하세요" : "지금 라우팅 중인 앱 없음"
        case let count: "앱 \(count)개를 따로 출력하는 중"
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let items = model.items
        let routed = items.filter { model.rule(for: $0) != nil }
        let playing = items.filter { model.rule(for: $0) == nil && $0.isPlaying }
        let others = items.filter { model.rule(for: $0) == nil && !$0.isPlaying }

        VStack(alignment: .leading, spacing: 10) {
            if model.needsPermission {
                Notice(symbol: "lock.shield.fill", tint: .orange, title: "오디오 캡처 권한이 필요합니다",
                       detail: "시스템 설정 > 개인정보 보호 및 보안 > 화면 및 시스템 오디오 녹음에서 SoundLanes를 켜 주세요.",
                       action: ("시스템 설정 열기", {
                           NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                       }))
            }
            if model.isReadOnly {
                Notice(symbol: "lock.fill", tint: .orange, title: "읽기 전용",
                       detail: "설정 파일 버전을 알 수 없어 변경 내용을 저장하지 않습니다.")
            }
            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        section("설정한 앱", routed)
                        section("재생 중", playing)
                        section("소리를 내지 않는 앱", others)
                    }
                }
                .frame(maxHeight: 560)
                .fixedSize(horizontal: false, vertical: true)
            }
            if model.hiddenAppCount > 0 || model.showAllApps {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { model.showAllApps.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.showAllApps ? "소리를 내지 않는 앱 숨기기" : "소리를 내지 않는 앱 \(model.hiddenAppCount)개 보기")
                        Image(systemName: model.showAllApps ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption)
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
            }
            if let error = model.lastError {
                Notice(symbol: "exclamationmark.triangle.fill", tint: .red, title: "저장하지 못했습니다", detail: error)
            }
        }
        .padding(10)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [AppItem]) -> some View {
        if !items.isEmpty {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.top, 4)
            ForEach(items) { item in
                AppCard(model: model, item: item)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.tertiary)
            Text("지금 소리를 내는 앱이 없습니다").font(.callout)
            Text("앱에서 소리를 재생하면 여기에 나타납니다.").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    private func blocked(_ owner: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Notice(symbol: "terminal.fill", tint: .blue, title: "다른 곳에서 라우팅을 적용 중입니다",
                   detail: "\(owner)이(가) 실행 중입니다. 터미널의 soundlanes run을 종료한 뒤 다시 시도하세요.")
            Button("다시 시도") { Task { await model.retry() } }
                .controlSize(.small)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle(isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) })) {
                Text("로그인 시 실행").font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help(loginItem.message ?? "Mac에 로그인하면 SoundLanes를 자동으로 실행합니다")
            Spacer()
            Button {
                NSWorkspace.shared.open(ConfigStore.defaultDirectory)
            } label: {
                Image(systemName: "folder")
            }
            .help("설정 폴더 열기")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("SoundLanes 종료 (라우팅이 해제됩니다)")
            .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .foregroundStyle(.secondary)
    }
}

// MARK: - App card

private struct AppCard: View {
    let model: AppModel
    let item: AppItem
    @State private var dragVolume: Float?
    @State private var isHovering = false

    var body: some View {
        let rule = model.rule(for: item)
        let status = model.status(for: item)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: AppIcons.icon(for: item.bundleID))
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    StatusLine(phase: rule == nil ? nil : (status?.phase ?? .noProcesses),
                               status: status, isPlaying: item.isPlaying,
                               followsDefault: rule?.device.isFollowDefault ?? false)
                }
                Spacer(minLength: 6)
                DeviceMenu(model: model, item: item, rule: rule)
            }
            if rule != nil || item.isPlaying {
                let volume = dragVolume ?? rule?.volume ?? 1
                HStack(spacing: 8) {
                    Image(systemName: "speaker.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: Binding(
                            get: { Double(volume) },
                            set: {
                                dragVolume = Float($0)
                                model.setVolume(Float($0), for: item, commit: false)
                            }),
                        in: 0...1,
                        onEditingChanged: { editing in
                            guard !editing else { return }
                            if let dragVolume { model.setVolume(dragVolume, for: item, commit: true) }
                            dragVolume = nil
                        })
                        .controlSize(.mini)
                    Text("\(Int((volume * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .trailing)
                }
                .padding(.leading, 40)
            }
            if let rule {
                if status?.phase == .running {
                    LevelMeter(peak: status?.inputPeak ?? 0)
                        .padding(.leading, 40)
                        .padding(.trailing, 42)
                }
                if let warning = AppPresets.warning(for: rule.app) {
                    Label(warning, systemImage: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 40)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rule != nil ? Color.accentColor.opacity(0.09) : Color.primary.opacity(isHovering ? 0.05 : 0)))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(rule != nil ? Color.accentColor.opacity(0.18) : .clear))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovering)
    }
}

private struct StatusLine: View {
    /// Nil when the app has no rule.
    let phase: RouteStatus.Phase?
    let status: RouteStatus?
    let isPlaying: Bool
    var followsDefault = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help(status?.message ?? text)
    }

    private var text: String {
        guard let phase else { return isPlaying ? "기본 출력으로 재생 중" : "소리 없음" }
        switch phase {
        case .running where followsDefault:
            return "기본 출력 · 음량 조절 중"
        case .deviceIsDefault where followsDefault:
            return "기본 출력으로 재생"
        case .running:
            if let extra = status?.extraLatencyMilliseconds, extra >= 20 {
                return "라우팅 중 · 지연 +\(Int(extra.rounded())) ms"
            }
            return "라우팅 중"
        case .deviceMissing: return "장치 연결 대기 · 지금은 기본 출력"
        case .deviceIsDefault: return "기본 출력과 같은 장치"
        case .noProcesses: return "앱이 소리를 내면 라우팅"
        case .failed: return "실패 · 자동으로 다시 시도"
        case .noPermission: return "오디오 캡처 권한 필요"
        case .disabled: return "꺼짐"
        }
    }

    private var color: Color {
        guard let phase else { return isPlaying ? .green.opacity(0.6) : .gray.opacity(0.5) }
        switch phase {
        case .running: return .green
        case .failed, .noPermission: return .red
        case .deviceMissing: return .orange
        default: return .gray
        }
    }
}

/// A compact device chooser showing the current device's icon and name.
private struct DeviceMenu: View {
    let model: AppModel
    let item: AppItem
    let rule: RouteRule?

    private static let followDefault = ""

    var body: some View {
        let selection = Binding<String>(
            get: { rule?.device.uid ?? Self.followDefault },
            set: { model.setDevice($0 == Self.followDefault ? nil : $0, for: item) })
        Menu {
            Picker("출력 장치", selection: selection) {
                Label("기본 출력 따름", systemImage: "arrow.uturn.backward").tag(Self.followDefault)
                Divider()
                ForEach(model.devices, id: \.uid) { device in
                    Label(device.isDefault ? "\(device.name) (기본)" : device.name,
                          systemImage: DeviceSymbol.name(for: device))
                        .tag(device.uid)
                }
                if let rule, !rule.device.isFollowDefault, model.device(uid: rule.device.uid) == nil {
                    Label("\(rule.device.name) (연결 안 됨)", systemImage: "speaker.slash").tag(rule.device.uid)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                Text(title).lineLimit(1)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .tint(rule.map { $0.device.isFollowDefault } == false ? .accentColor : nil)
        .controlSize(.small)
        .frame(maxWidth: 150, alignment: .trailing)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var title: String {
        guard let rule, !rule.device.isFollowDefault else { return "기본 출력" }
        return model.device(uid: rule.device.uid)?.name ?? rule.device.name
    }

    private var symbol: String {
        guard let rule, !rule.device.isFollowDefault else { return "arrow.uturn.backward" }
        return model.device(uid: rule.device.uid).map(DeviceSymbol.name(for:)) ?? "speaker.slash"
    }
}

/// Horizontal level bar for the tapped app audio (dBFS, -60...0).
private struct LevelMeter: View {
    let peak: Float

    var body: some View {
        GeometryReader { proxy in
            let fraction = CGFloat(level)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .orange],
                                         startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) {
                        Capsule().frame(width: proxy.size.width * fraction)
                    }
            }
        }
        .frame(height: 4)
        .animation(.easeOut(duration: 0.2), value: level)
        .accessibilityLabel("입력 레벨")
    }

    private var level: Float {
        guard peak > 0 else { return 0 }
        return min(max((20 * log10(peak) + 60) / 60, 0), 1)
    }
}

private struct Notice: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.system(size: 15))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.0, action: action.1)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// SF Symbol for a device, by name and transport.
enum DeviceSymbol {
    static func name(for device: OutputDevice) -> String {
        let lowered = device.name.lowercased()
        if lowered.contains("airpods max") { return "airpodsmax" }
        if lowered.contains("airpods pro") { return "airpodspro" }
        if lowered.contains("airpods") { return "airpods" }
        switch device.transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        case kAudioDeviceTransportTypeBuiltIn: return "laptopcomputer"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
        case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt: return "hifispeaker"
        case kAudioDeviceTransportTypeVirtual: return "waveform"
        case kAudioDeviceTransportTypeAggregate: return "square.stack.3d.up"
        default: return "speaker.wave.2"
        }
    }
}
