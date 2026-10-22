import ArgumentParser
import CoreAudio
import Foundation
import RouteCore

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "출력 장치 목록을 보여줍니다.")

    func run() throws {
        var table = Table("기본", "이름", "UID", "샘플레이트", "지연", "연결")
        for device in try DeviceCatalog.outputDevices() {
            table.add(
                device.isDefault ? "*" : "",
                device.name,
                device.uid,
                formatRate(device.sampleRate),
                String(format: "%.1f ms", device.latencyMilliseconds),
                transportName(device.transportType))
        }
        print(table.render())
    }
}

func formatRate(_ rate: Double) -> String {
    rate.truncatingRemainder(dividingBy: 1000) == 0
        ? "\(Int(rate / 1000)) kHz"
        : String(format: "%.1f kHz", rate / 1000)
}

func transportName(_ type: UInt32) -> String {
    switch type {
    case kAudioDeviceTransportTypeBuiltIn: "내장"
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "Bluetooth"
    case kAudioDeviceTransportTypeUSB: "USB"
    case kAudioDeviceTransportTypeHDMI: "HDMI"
    case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
    case kAudioDeviceTransportTypeAirPlay: "AirPlay"
    case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
    case kAudioDeviceTransportTypeAggregate: "Aggregate"
    case kAudioDeviceTransportTypeVirtual: "가상"
    default: "기타"
    }
}
