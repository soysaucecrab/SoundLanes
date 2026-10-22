import ArgumentParser
import RouteCore

struct Apps: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "오디오를 쓰는 프로세스 목록을 보여줍니다.")

    @Flag(name: .long, help: "소리를 내고 있지 않은 프로세스도 보여줍니다.")
    var all = false

    func run() throws {
        let processes = try ProcessCatalog.processes()
            .filter { all || $0.isRunningOutput }
            .sorted { ($0.appName.lowercased(), $0.bundleID, $0.pid) < ($1.appName.lowercased(), $1.bundleID, $1.pid) }
        guard !processes.isEmpty else {
            print(all ? "오디오 프로세스가 없습니다." : "지금 소리를 내는 앱이 없습니다. 전체 목록: soundlanes apps --all")
            return
        }
        var table = Table("앱", "번들 ID", "PID", "재생 중")
        for process in processes {
            table.add(
                process.appName,
                process.bundleID.isEmpty ? "(없음)" : process.bundleID,
                String(process.pid),
                process.isRunningOutput ? "예" : "")
        }
        print(table.render())
    }
}
