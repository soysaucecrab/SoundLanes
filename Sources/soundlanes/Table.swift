/// Plain-text table that aligns columns by terminal display width (Hangul and CJK count as 2).
struct Table {
    let headers: [String]
    var rows: [[String]] = []

    init(_ headers: String...) { self.headers = headers }

    mutating func add(_ cells: String...) { rows.append(cells) }

    func render() -> String {
        let all = [headers] + rows
        let widths = headers.indices.map { column in all.map { displayWidth($0[column]) }.max() ?? 0 }
        return all.map { row in
            row.indices.map { column in
                let cell = row[column]
                let isLast = column == row.count - 1
                return isLast ? cell : cell + String(repeating: " ", count: widths[column] - displayWidth(cell))
            }.joined(separator: "  ")
        }.joined(separator: "\n")
    }
}

func displayWidth(_ text: String) -> Int {
    text.unicodeScalars.reduce(0) { width, scalar in
        switch scalar.value {
        case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
             0xFE30...0xFE4F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F300...0x1FAFF:
            width + 2
        case 0x0300...0x036F, 0x200B...0x200F, 0xFE00...0xFE0F:
            width
        default:
            width + 1
        }
    }
}
