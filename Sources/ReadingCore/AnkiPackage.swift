import Foundation
import CryptoKit

/// ZIP method 0 (stored), supported by Anki without third-party compression code.
public enum StoredZIP {
    public static func archive(_ entries: [(String, Data)]) throws -> Data {
        guard entries.count < Int(UInt16.max) else { throw StorageError.invalidArchive("Too many archive files") }
        var output = Data(), central = Data()
        func number<T: FixedWidthInteger>(_ value: T) -> Data {
            var n = value.littleEndian; return withUnsafeBytes(of: &n) { Data($0) }
        }
        for (name, data) in entries {
            let filename = Data(name.utf8)
            guard data.count < Int(UInt32.max), output.count < Int(UInt32.max), filename.count < Int(UInt16.max) else {
                throw StorageError.invalidArchive("Archive exceeds the supported size")
            }
            let offset = UInt32(output.count), size = UInt32(data.count), crc = checksum(data)
            output += number(UInt32(0x04034b50)); output += number(UInt16(20)); output += number(UInt16(0x800))
            output += number(UInt16(0)); output += number(UInt16(0)); output += number(UInt16(33))
            output += number(crc); output += number(size); output += number(size)
            output += number(UInt16(filename.count)); output += number(UInt16(0)); output += filename; output += data
            central += number(UInt32(0x02014b50)); central += number(UInt16(20)); central += number(UInt16(20))
            central += number(UInt16(0x800)); central += number(UInt16(0)); central += number(UInt16(0)); central += number(UInt16(33))
            central += number(crc); central += number(size); central += number(size); central += number(UInt16(filename.count))
            central += number(UInt16(0)); central += number(UInt16(0)); central += number(UInt16(0)); central += number(UInt16(0))
            central += number(UInt32(0)); central += number(offset); central += filename
        }
        let start = UInt32(output.count); output += central
        output += number(UInt32(0x06054b50)); output += number(UInt16(0)); output += number(UInt16(0))
        output += number(UInt16(entries.count)); output += number(UInt16(entries.count))
        output += number(UInt32(central.count)); output += number(start); output += number(UInt16(0))
        return output
    }
    static func checksum(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        return crc ^ 0xffffffff
    }
}

public enum AnkiPackage {
    public static let modelID: Int64 = 1792500000001
    public static let deckID: Int64 = 1792500000002
    public static func html(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "<br>").replacingOccurrences(of: "\u{1f}", with: " ")
    }
    public static func markedExample(_ word: RetainedWord) -> String {
        guard !word.surface.isEmpty, let range = word.example.range(of: word.surface) else { return html(word.example) }
        return html(String(word.example[..<range.lowerBound])) + "<b>" + html(word.surface) + "</b>" + html(String(word.example[range.upperBound...]))
    }
    public static func generate(words: [RetainedWord], destination: URL) throws {
        guard !words.isEmpty else { throw StorageError.invalidArchive("Select and retain words before exporting") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let collection = root.appendingPathComponent("collection.anki2")
        try writeCollection(words.sorted { $0.guid < $1.guid }, to: collection)
        let data = try StoredZIP.archive([("collection.anki2", Data(contentsOf: collection)), ("media", Data("{}".utf8))])
        try data.write(to: destination, options: .atomic)
    }
    private static func writeCollection(_ words: [RetainedWord], to url: URL) throws {
        let db = try Database(url: url)
        try db.execute("PRAGMA journal_mode=DELETE;")
        try db.execute("""
        CREATE TABLE col(id integer PRIMARY KEY,crt integer NOT NULL,mod integer NOT NULL,scm integer NOT NULL,ver integer NOT NULL,dty integer NOT NULL,usn integer NOT NULL,ls integer NOT NULL,conf text NOT NULL,models text NOT NULL,decks text NOT NULL,dconf text NOT NULL,tags text NOT NULL);
        CREATE TABLE notes(id integer PRIMARY KEY,guid text NOT NULL,mid integer NOT NULL,mod integer NOT NULL,usn integer NOT NULL,tags text NOT NULL,flds text NOT NULL,sfld integer NOT NULL,csum integer NOT NULL,flags integer NOT NULL,data text NOT NULL);
        CREATE TABLE cards(id integer PRIMARY KEY,nid integer NOT NULL,did integer NOT NULL,ord integer NOT NULL,mod integer NOT NULL,usn integer NOT NULL,type integer NOT NULL,queue integer NOT NULL,due integer NOT NULL,ivl integer NOT NULL,factor integer NOT NULL,reps integer NOT NULL,lapses integer NOT NULL,left integer NOT NULL,odue integer NOT NULL,odid integer NOT NULL,flags integer NOT NULL,data text NOT NULL);
        CREATE TABLE revlog(id integer PRIMARY KEY,cid integer NOT NULL,usn integer NOT NULL,ease integer NOT NULL,ivl integer NOT NULL,lastIvl integer NOT NULL,factor integer NOT NULL,time integer NOT NULL,type integer NOT NULL);
        CREATE TABLE graves(usn integer NOT NULL,oid integer NOT NULL,type integer NOT NULL);
        CREATE INDEX ix_notes_usn ON notes(usn); CREATE INDEX ix_cards_usn ON cards(usn);
        CREATE INDEX ix_revlog_usn ON revlog(usn); CREATE INDEX ix_cards_nid ON cards(nid);
        CREATE INDEX ix_cards_sched ON cards(did,queue,due); CREATE INDEX ix_revlog_cid ON revlog(cid);
        CREATE INDEX ix_notes_csum ON notes(csum);
        """)
        func json(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self) }
        let fields = ["Word", "Reading", "Definition", "Example", "Source", "AppID", "Attribution"]
        let model: [String: Any] = ["id": modelID, "name": "Reading Companion", "type": 0, "mod": 1792500000, "usn": -1,
            "sortf": 0, "did": deckID, "latexPre": "", "latexPost": "", "latexsvg": false, "vers": [], "tags": [],
            "css": ".card { font-family: -apple-system, sans-serif; font-size: 22px; text-align: left; line-height: 1.7; } .word {font-size: 34px;} .source {font-size:14px; color:#777;} b {color:#28715b;}",
            "flds": fields.enumerated().map { ["name": $0.element, "ord": $0.offset, "sticky": false, "rtl": false, "font": "Arial", "size": 20] as [String: Any] },
            "tmpls": [["name": "Reading", "ord": 0, "did": NSNull(), "bqfmt": "", "bafmt": "",
                "qfmt": "<div class='word'>{{Word}}</div><details><summary>Context</summary>{{Example}}</details>",
                "afmt": "<div class='word'>{{Word}}</div><div>{{Reading}}</div><hr id=answer><div>{{Definition}}</div><p>{{Example}}</p><div class='source'>{{Source}}<br>{{Attribution}}</div>"]],
            "req": [[0, "all", [0]]]]
        let deck: [String: Any] = ["id": deckID, "name": "Reading Companion", "mod": 1792500000, "usn": -1, "desc": "Vocabulary encountered while reading", "dyn": 0, "collapsed": false, "browserCollapsed": false, "conf": 1, "extendNew": 0, "extendRev": 0, "newToday": [0,0], "revToday": [0,0], "lrnToday": [0,0], "timeToday": [0,0]]
        try db.execute("INSERT INTO col VALUES(1,?, ?,0,11,0,-1,0,?,?,?,?,?)", values: ["1792454400", String(Int(Date().timeIntervalSince1970 * 1000)), "{}", try json([String(modelID): model]), try json([String(deckID): deck]), "{}", "{}"])
        try db.transaction {
            var used = Set<Int64>()
            for (position, word) in words.enumerated() {
                // A deterministic 52-bit ID is exactly representable by Anki's JSON clients.
                let digest = SHA256.hash(data: Data(word.guid.utf8))
                var id = digest.prefix(7).reduce(Int64(0)) { ($0 << 8) | Int64($1) } & 0xfffffffffffff
                while used.contains(id) { id += 1 }; used.insert(id)
                let modified = String(Int(word.modifiedAt.timeIntervalSince1970))
                let attribution = word.lexeme.dictionaryID == nil ? "User-defined expression" : "JMdict / EDRDG, CC BY-SA 4.0 · https://www.edrdg.org/edrdg/licence.html"
                let values = [html(word.lexeme.expression), html(word.lexeme.reading), word.lexeme.definitions.map(html).joined(separator: "<br>"), markedExample(word), html(word.source), html(word.guid), html(attribution)]
                let checksum = Insecure.SHA1.hash(data: Data(word.lexeme.expression.utf8)).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                try db.execute("INSERT INTO notes VALUES(?,?,?,?,-1,'',?,?,?,0,'')", values: [String(id), word.guid, String(modelID), modified, values.joined(separator: "\u{1f}"), word.lexeme.expression, String(checksum)])
                try db.execute("INSERT INTO cards VALUES(?,?,?,0,?,-1,0,0,?,0,2500,0,0,0,0,0,0,'')", values: [String(id), String(id), String(deckID), modified, String(position+1)])
            }
        }
    }
}
