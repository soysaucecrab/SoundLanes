import ArgumentParser
import Foundation
import RouteCore

@main
struct SoundLanes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "soundlanes",
        abstract: "앱별로 오디오 출력 장치를 지정합니다.",
        version: "0.1.0",
        subcommands: [Devices.self, Apps.self, Add.self, Remove.self, List.self, Run.self, Status.self, Once.self]
    )

    /// Custom entry point so exit codes follow SPEC §9 (`2` for bad arguments instead of 64)
    /// and our own errors are printed in Korean.
    static func main() async {
        do {
            var command = try parseAsRoot()
            if var asyncCommand = command as? AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
        } catch let error as CLIError {
            printError(error.message)
            Foundation.exit(error.code)
        } catch let error as CoreAudioError {
            printError(error.description)
            Foundation.exit(ExitStatus.general)
        } catch let error as RouteError {
            printError(error.description)
            Foundation.exit(ExitStatus.general)
        } catch let error as ConfigError {
            printError(error.description)
            Foundation.exit(ExitStatus.general)
        } catch let error as ControlError {
            printError(error.description)
            Foundation.exit(ExitStatus.general)
        } catch {
            if exitCode(for: error) == .validationFailure {
                FileHandle.standardError.write(Data((fullMessage(for: error) + "\n").utf8))
                Foundation.exit(ExitStatus.badArgument)
            }
            exit(withError: error)
        }
    }
}

enum ExitStatus {
    static let success: Int32 = 0
    static let general: Int32 = 1
    static let badArgument: Int32 = 2
    static let permissionDenied: Int32 = 3
}

struct CLIError: Error {
    let message: String
    let code: Int32

    static func badArgument(_ message: String) -> CLIError { CLIError(message: message, code: ExitStatus.badArgument) }
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data("오류: \(message)\n".utf8))
}
