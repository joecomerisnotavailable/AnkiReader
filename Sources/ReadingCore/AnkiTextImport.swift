import Foundation

public struct AnkiTextFile {
    public var rows: [[String]]
    public var columns: [String]
    public var noteType: String
    public init(_ text: String) throws {
        var separator: Character = "\t", body: [String] = [], headers: [String: String] = [:]
        var inHeaders = true
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if inHeaders && line.hasPrefix("#") {
                let parts = line.dropFirst().split(separator: ":", maxSplits: 1)
                if parts.count == 2 { headers[String(parts[0]).lowercased()] = String(parts[1]) }
            } else { inHeaders = false; body.append(String(line)) }
        }
        if let value = headers["separator"]?.lowercased() {
            let separators: [String: Character] = ["tab": "\t", "comma": ",", "semicolon": ";", "pipe": "|", "space": " ", "colon": ":"]
            guard let found = separators[value] else { throw StorageError.invalidArchive("Unsupported text separator: \(value)") }
            separator = found
        }
        noteType = headers["notetype"] ?? "Default"
        columns = headers["columns"]?.split(separator: separator, omittingEmptySubsequences: false).map(String.init) ?? []
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        let chars = Array(body.joined(separator: "\n")); var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "\"" {
                if quoted && i+1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 }
                else if quoted || field.isEmpty { quoted.toggle() }
                else { field.append(c) }
            } else if !quoted && (c == separator || c == "\n") {
                row.append(field); field = ""
                if c == "\n" { if row.contains(where: { !$0.isEmpty }) { rows.append(row) }; row = [] }
            } else { field.append(c) }
            i += 1
        }
        guard !quoted else { throw StorageError.invalidArchive("Unclosed quoted field in text export") }
        row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
        self.rows = rows
        let count = max(columns.count, rows.map(\.count).max() ?? 0)
        while columns.count < count { columns.append("Column \(columns.count+1)") }
    }
}
