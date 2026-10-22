import AppKit
import CoreAudio
import RouteCore
import SwiftUI

/// The menu bar window. Laid out like Control Center's sound module and a regular menu:
/// plain rows, native pop-up buttons and sliders, menu-item style actions at the bottom.
struct MenuView: View {
    @Bindable var model: AppModel
    @State private var loginItem = LoginItem()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            switch model.mode {
            case .starting:
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(20)
            case .blocked(let owner):
                blocked(owner)
            case .failed(let message):
                NoticeRow(symbol: "exclamationmark.triangle", color: .red, text: "시작하지 못했습니다. \(message)")
            case .active:
                content
            }
            MenuSeparator()
            footer
                .padding(.bottom, 5)
        }
        .padding(.horizontal, 5)
        .frame(width: 330)
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("SoundLanes").font(.system(size: 13, weight: .semibold))
            if let device = model.defaultDevice {
                Text("기본 출력: \(device.name)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        let items = model.items
        let routed = items.filter { model.rule(for: $0) != nil }
        let playing = items.filter { model.rule(for: $0) == nil && $0.isPlaying }
        let others = items.filter { model.rule(for: $0) == nil && !$0.isPlaying }

        if model.needsPermission {
            NoticeRow(symbol: "exclamationmark.triangle", color: .orange,
                      text: "오디오 녹음 권한이 없어 소리를 옮기지 못하고 있습니다.",
                      action: ("시스템 설정 열기…", {
                          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                      }))
        }
        if model.isReadOnly {
            NoticeRow(symbol: "lock", color: .secondary, text: "설정 파일 버전을 알 수 없어 변경 내용을 저장하지 않습니다.")
        }
        if let error = model.lastError {
            NoticeRow(symbol: "exclamationmark.triangle", color: .red, text: error)
        }
        if items.isEmpty {
            Text("소리를 내는 앱이 없습니다")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section("설정한 앱", routed)
                    section("재생 중", playing)
                    section("조용한 앱", others)
                }
            }
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
        }
        if model.hiddenAppCount > 0 || model.showAllApps {
            MenuItem(model.showAllApps ? "조용한 앱도 보기" : "조용한 앱도 보기 (\(model.hiddenAppCount))",
                     checked: model.showAllApps) {
                model.showAllApps.toggle()
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [AppItem]) -> some View {
        if !items.isEmpty {
            MenuSeparator()
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
            ForEach(items) { item in
                AppRow(model: model, item: item)
            }
        }
    }

    private func blocked(_ owner: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            NoticeRow(symbol: "terminal", color: .secondary,
                      text: "\(owner)이(가) 이미 라우팅을 적용 중입니다. 그쪽을 종료한 뒤 다시 시도하세요.")
            MenuItem("다시 시도", checked: false) { Task { await model.retry() } }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 0) {
            MenuItem("로그인 시 실행", checked: loginItem.isEnabled) {
                loginItem.setEnabled(!loginItem.isEnabled)
            }
            .help(loginItem.message ?? "")
            MenuItem("설정 폴더 열기…", checked: false) {
                NSWorkspace.shared.open(ConfigStore.defaultDirectory)
            }
            MenuItem("SoundLanes 종료", checked: false, shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

// MARK: - App row

private struct AppRow: View {
    let model: AppModel
    let item: AppItem
    @State private var dragVolume: Float?
    @State private var isHovering = false

    var body: some View {
        let rule = model.rule(for: item)
        let status = model.status(for: item)
        let detail = Self.detail(rule: rule, status: status)
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(nsImage: AppIcons.icon(for: item.bundleID))
                    .resizable()
                    .frame(width: 20, height: 20)
                Text(item.name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                Spacer(minLength: 6)
                DevicePicker(model: model, item: item, rule: rule)
            }
            if rule != nil || item.isPlaying {
                let volume = dragVolume ?? rule?.volume ?? 1
                HStack(spacing: 6) {
                    Image(systemName: Self.speakerSymbol(volume: volume, peak: status?.inputPeak))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, alignment: .leading)
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
                        .controlSize(.small)
                        .help("음량 \(Int((volume * 100).rounded()))%")
                }
                .padding(.leading, 28)
            }
            if let detail {
                Text(detail.text)
                    .font(.system(size: 11))
                    .foregroundStyle(detail.isProblem ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 28)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(isHovering ? 0.06 : 0)))
        .onHover { isHovering = $0 }
    }

    /// One line under the row, only when there is something worth saying.
    private static func detail(rule: RouteRule?, status: RouteStatus?) -> (text: String, isProblem: Bool)? {
        guard let rule else { return nil }
        if let warning = AppPresets.warning(for: rule.app) { return (warning, false) }
        switch status?.phase ?? .noProcesses {
        case .running:
            if let extra = status?.extraLatencyMilliseconds, extra >= 50 {
                return ("기본 출력보다 \(Int(extra.rounded())) ms 늦게 들립니다", false)
            }
            return nil
        case .deviceMissing: return ("\(rule.device.displayName) 연결 대기 중. 지금은 기본 출력으로 나갑니다", false)
        case .deviceIsDefault, .noProcesses, .disabled: return nil
        case .failed: return ("옮기지 못했습니다. 잠시 후 다시 시도합니다", true)
        case .noPermission: return ("오디오 녹음 권한이 필요합니다", true)
        }
    }

    /// The speaker icon doubles as a level indicator while the app is routed.
    private static func speakerSymbol(volume: Float, peak: Float?) -> String {
        guard volume > 0 else { return "speaker.slash.fill" }
        guard let peak, peak > 0 else { return "speaker.fill" }
        let db = 20 * log10(peak)
        if db > -12 { return "speaker.wave.3.fill" }
        if db > -24 { return "speaker.wave.2.fill" }
        if db > -48 { return "speaker.wave.1.fill" }
        return "speaker.fill"
    }
}

/// Native pop-up button with the device list.
private struct DevicePicker: View {
    let model: AppModel
    let item: AppItem
    let rule: RouteRule?

    private static let followDefault = ""

    var body: some View {
        Picker("", selection: Binding<String>(
            get: { rule?.device.uid ?? Self.followDefault },
            set: { model.setDevice($0 == Self.followDefault ? nil : $0, for: item) })
        ) {
            Text("기본 출력").tag(Self.followDefault)
            Divider()
            ForEach(model.devices, id: \.uid) { device in
                Label(device.name, systemImage: DeviceSymbol.name(for: device)).tag(device.uid)
            }
            if let rule, !rule.device.isFollowDefault, model.device(uid: rule.device.uid) == nil {
                Label("\(rule.device.name) (연결 안 됨)", systemImage: "speaker.slash").tag(rule.device.uid)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .controlSize(.small)
        .frame(maxWidth: 140)
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Menu building blocks

/// A full-width, menu-item-like button with a hover highlight.
private struct MenuItem: View {
    let title: String
    var checked: Bool?
    var shortcut: String?
    let action: () -> Void
    @State private var isHovering = false

    init(_ title: String, checked: Bool? = nil, shortcut: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.checked = checked
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let checked {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .opacity(checked ? 1 : 0)
                        .frame(width: 12)
                }
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct MenuSeparator: View {
    var body: some View {
        Divider().padding(.horizontal, 9).padding(.vertical, 5)
    }
}

private struct NoticeRow: View {
    let symbol: String
    let color: Color
    let text: String
    var action: (String, () -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol).foregroundStyle(color)
                Text(text).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12))
            if let action {
                Button(action.0, action: action.1)
                    .controlSize(.small)
                    .padding(.leading, 20)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
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
