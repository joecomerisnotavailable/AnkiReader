import Foundation

extension StoredZIP {
    /// Reads archives written by this app. Other ZIP compression methods are rejected.
    public static func entries(_ data: Data) throws -> [String: Data] {
        var cursor = 0, result: [String: Data] = [:]
        func integer(_ offset: Int, _ length: Int) throws -> Int {
            guard offset >= 0, offset + length <= data.count else { throw StorageError.invalidArchive("Truncated backup") }
            return (0..<length).reduce(0) { $0 | (Int(data[offset+$1]) << ($1*8)) }
        }
        while try integer(cursor, 4) == 0x04034b50 {
            let flags = try integer(cursor+6, 2), method = try integer(cursor+8, 2)
            let crc = try integer(cursor+14, 4), size = try integer(cursor+18, 4), unpacked = try integer(cursor+22, 4)
            let nameLength = try integer(cursor+26, 2), extraLength = try integer(cursor+28, 2)
            let start = cursor+30, body = start+nameLength+extraLength, end = body+size
            guard method == 0, flags & 9 == 0, size == unpacked, end <= data.count, nameLength > 0 else { throw StorageError.invalidArchive("Unsupported or damaged backup ZIP") }
            guard let name = String(data: data[start..<start+nameLength], encoding: .utf8),
                  !name.hasPrefix("/"), !name.contains("\\"), !name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }), result[name] == nil else { throw StorageError.invalidArchive("Invalid or duplicate backup path") }
            let content = Data(data[body..<end])
            guard checksum(content) == UInt32(crc) else { throw StorageError.invalidArchive("Backup checksum failed for \(name)") }
            result[name] = content; cursor = end
        }
        guard try integer(cursor, 4) == 0x02014b50 else { throw StorageError.invalidArchive("Backup directory missing") }
        return result
    }
}

public enum LibraryBackup {
    private struct Manifest: Codable { var version = 1; var state: LibraryState }
    public static func create(state: LibraryState, root: URL, destination: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var entries: [(String, Data)] = [("manifest.json", try encoder.encode(Manifest(state: state)))]
        let paths = Set(state.captures.filter { $0.photoRemoved != true }.map(\.imagePath) + state.exports.map(\.path))
        for path in paths.sorted() {
            guard safe(path) else { throw StorageError.invalidArchive("Invalid library media path") }
            entries.append(("files/"+path, try Data(contentsOf: root.appendingPathComponent(path))))
        }
        try StoredZIP.archive(entries).write(to: destination, options: .atomic)
    }
    /// Stage files in a new directory. The caller commits the state transaction only
    /// after every file is validated and written; existing library files are untouched.
    public static func stageRestore(archive: URL, root: URL) throws -> LibraryState {
        let entries = try StoredZIP.entries(Data(contentsOf: archive))
        guard let manifest = entries["manifest.json"] else { throw StorageError.invalidArchive("Backup manifest missing") }
        let decoded = try JSONDecoder().decode(Manifest.self, from: manifest)
        guard decoded.version == 1, decoded.state.version == 1 else { throw StorageError.invalidArchive("Unsupported backup version") }
        var state = decoded.state
        let prefix = "restored/"+UUID().uuidString+"/"
        let paths = Set(state.captures.filter { $0.photoRemoved != true }.map(\.imagePath) + state.exports.map(\.path))
        // Validate every reference before writing anything.
        for path in paths { guard safe(path), entries["files/"+path] != nil else { throw StorageError.invalidArchive("Missing or invalid backup media") } }
        let staged = root.appendingPathComponent(prefix)
        do {
            for path in paths {
                let url = staged.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try entries["files/"+path]!.write(to: url, options: .atomic)
            }
            for i in state.captures.indices {
                state.captures[i].imagePath = prefix+state.captures[i].imagePath
                if state.captures[i].status == .processing { state.captures[i].status = .pending }
            }
            for i in state.exports.indices { state.exports[i].path = prefix+state.exports[i].path }
            return state
        } catch { try? FileManager.default.removeItem(at: staged); throw error }
    }
    private static func safe(_ path: String) -> Bool {
        !path.hasPrefix("/") && !path.contains("\\") && !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0 == "." || $0.isEmpty }
    }
}
