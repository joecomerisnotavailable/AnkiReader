import Foundation
import CryptoKit

public enum DictionaryVersions {
    private static func manifest(_ root: URL) -> URL { root.appendingPathComponent("dictionaries/versions.json") }
    public static func versions(root: URL) throws -> [String] {
        let url = manifest(root)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        guard names.allSatisfy({ $0.range(of: "^[a-f0-9]{64}\\.sqlite$", options: .regularExpression) != nil }) else { throw StorageError.invalidArchive("Invalid dictionary version manifest") }
        return names
    }
    public static func current(root: URL, bundled: URL) throws -> URL {
        guard let name = try versions(root: root).last else { return bundled }
        return root.appendingPathComponent("dictionaries/"+name)
    }
    public static func install(source: URL, root: URL) throws {
        let bytes = try Data(contentsOf: source, options: .mappedIfSafe)
        guard bytes.count < 500_000_000 else { throw StorageError.invalidArchive("Dictionary is too large") }
        let name = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()+".sqlite"
        let directory = root.appendingPathComponent("dictionaries")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(UUID().uuidString+".sqlite")
        defer { try? FileManager.default.removeItem(at: staging) }
        try bytes.write(to: staging, options: .atomic)
        try validate(staging)
        let destination = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: staging, to: destination) }
        var names = try versions(root: root)
        if names.last != name { names.append(name) }
        try JSONEncoder().encode(names).write(to: manifest(root), options: .atomic)
    }
    public static func rollback(root: URL) throws {
        var names = try versions(root: root)
        guard !names.isEmpty else { return }; names.removeLast()
        try JSONEncoder().encode(names).write(to: manifest(root), options: .atomic)
    }
    private static func validate(_ url: URL) throws {
        let db = try Database(url: url, readOnly: true)
        guard try db.rows("PRAGMA integrity_check").first?.first == "ok" else { throw StorageError.invalidArchive("Dictionary integrity check failed") }
        let count = try db.rows("SELECT COUNT(*) FROM entries").first?.first ?? "0"
        guard (Int(count) ?? 0) > 1000 else { throw StorageError.invalidArchive("Expected a complete JMdict index") }
        _ = try db.rows("SELECT id,expression,reading,definitions,commonness,pos FROM entries LIMIT 1")
        _ = try db.rows("SELECT form,entry_id FROM forms LIMIT 1")
        let metadata = try db.rows("SELECT key,value FROM metadata")
        guard metadata.contains(where: { $0[0] == "source_sha256" && $0[1].count == 64 }),
              metadata.contains(where: { $0[0] == "license" && $0[1].contains("edrdg.org") }) else { throw StorageError.invalidArchive("Missing dictionary source version or EDRDG attribution") }
    }
}
