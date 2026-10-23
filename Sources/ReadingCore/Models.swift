import Foundation

public struct Region: Codable, Hashable, Sendable {
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x=x; self.y=y; self.width=width; self.height=height }
}
public struct TextLine: Codable, Identifiable, Hashable, Sendable {
    public var id: String = UUID().uuidString
    public var text: String
    public var region: Region
    public var confidence: Double?
    public var elements: [TextElementGeometry]?
    public var corners: [ImagePoint]?
    public var isRuby: Bool = false
    public init(text: String, region: Region, confidence: Double? = nil) { self.text=text; self.region=region; self.confidence=confidence }
}
public struct Recognition: Codable, Sendable {
    public var engine: String
    public var lines: [TextLine]
    public var rawLines: [TextLine]?
    public var elapsed: Double
    public var text: String { lines.filter { !$0.isRuby }.map(\.text).joined() }
    public init(engine: String, lines: [TextLine], elapsed: Double) { self.engine=engine; self.lines=lines; self.elapsed=elapsed }
}
public struct ReadingSession: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var title: String
    public var source: String
    public var started: Date
    public var lastCapture: Date
    public var completed = false
    public init(source: String, now: Date = Date()) { self.source=source; self.started=now; self.lastCapture=now; self.title=source.isEmpty ? now.formatted(date:.abbreviated,time:.shortened) : source }
}
public enum CaptureStatus: String, Codable, Sendable { case pending, processing, ready, failed }
public enum ReviewMark:String,Codable,Sendable { case selected, known, unknown }
public struct PageCapture: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var sessionID: String
    public var imagePath: String
    public var fingerprint: String
    public var created = Date()
    public var status: CaptureStatus = .pending
    public var recognition: Recognition?
    public var correctedText: String?
    public var layout: String?
    public var photoRemoved: Bool?
    public var processingVersion: String?
    public var reviewCompleted: Bool?
    public var excludedLexemeIDs: Set<String>?
    public var reviewMarks: [String:ReviewMark]?
    public var error: String?
    public var text: String { correctedText ?? recognition?.text ?? "" }
    public init(sessionID: String, imagePath: String, fingerprint: String) { self.sessionID=sessionID; self.imagePath=imagePath; self.fingerprint=fingerprint }
}
public struct Lexeme: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var expression: String
    public var reading: String
    public var definitions: [String]
    public var commonness: Double
    public var partOfSpeech: String
    public var dictionaryID: String?
    public var uncertain: Bool?
    public init(id: String, expression: String, reading: String = "", definitions: [String] = [], commonness: Double = 0.2, partOfSpeech: String = "", dictionaryID: String? = nil) { self.id=id; self.expression=expression; self.reading=reading; self.definitions=definitions; self.commonness=commonness; self.partOfSpeech=partOfSpeech; self.dictionaryID=dictionaryID }
}
public struct Occurrence: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var captureID: String
    public var lexemeID: String
    public var surface: String
    /// Unicode scalar offsets into the capture's effective text, never UTF-8 byte offsets.
    public var start: Int
    public var end: Int
    public var lineIDs: [String]
    public var sentence: String
    public var fragment: Bool
    public var confidence: Double?
    public var exampleStart: Int?
    public var exampleEnd: Int?
    public var manualExample: Bool?
    public var selected = false
    public var corrected = false
    public init(captureID: String, lexemeID: String, surface: String, start: Int, end: Int, lineIDs: [String] = [], sentence: String, fragment: Bool, confidence: Double? = nil) {
        self.captureID=captureID; self.lexemeID=lexemeID; self.surface=surface; self.start=start; self.end=end; self.lineIDs=lineIDs; self.sentence=sentence; self.fragment=fragment; self.confidence=confidence
    }
}
public struct Knowledge: Codable, Sendable {
    public var imported = false
    public var override: Bool?
    public var isKnown: Bool { override ?? imported }
    public init(imported: Bool = false, override: Bool? = nil) { self.imported=imported; self.override=override }
}
public struct RetainedWord: Codable, Identifiable, Sendable {
    public var id: String { lexeme.id }
    public var guid = UUID().uuidString
    public var lexeme: Lexeme
    public var occurrenceID: String
    public var example: String
    public var surface: String
    public var source: String
    public var retainedAt = Date()
    public var modifiedAt = Date()
    public init(lexeme: Lexeme, occurrence: Occurrence, source: String) { self.lexeme=lexeme; self.occurrenceID=occurrence.id; self.example=occurrence.sentence; self.surface=occurrence.surface; self.source=source }
}
public struct ExportRecord: Codable, Identifiable, Sendable {
    public var id = UUID().uuidString
    public var created = Date()
    public var path: String
    public var lexemeIDs: [String]
    public init(path: String, lexemeIDs: [String]) { self.path=path; self.lexemeIDs=lexemeIDs }
}
public struct FieldMapping: Codable, Sendable {
    public var word: Int
    public var reading: Int?
    public init(word: Int, reading: Int?) { self.word=word; self.reading=reading }
}
public struct LibraryState: Codable, Sendable {
    public var version = 1
    public var sessions: [ReadingSession] = []
    public var captures: [PageCapture] = []
    public var lexemes: [String: Lexeme] = [:]
    public var occurrences: [Occurrence] = []
    public var knowledge: [String: Knowledge] = [:]
    public var retained: [String: RetainedWord] = [:]
    /// Preserve Anki identity if a removed word is collected again later.
    public var retainedGUIDs: [String:String]?
    public var exports: [ExportRecord] = []
    public var rememberedExpressions: [String: String] = [:]
    public var mappings: [String: FieldMapping] = [:]
    public var lastSource = ""
    public var basicWords: Set<String> = ["これ","それ","あれ","ここ","そこ","私","あなた","ある","いる","する","なる","できる","です","ます","今日","明日","昨日","人","日","月","年","一","二","三"]
    public init() {}
    public mutating func session(source: String, now: Date = Date()) -> String {
        if let i = sessions.indices.last(where: { !sessions[$0].completed && sessions[$0].source == source && now.timeIntervalSince(sessions[$0].lastCapture) < 1800 }) {
            sessions[i].lastCapture=now; return sessions[i].id
        }
        let s=ReadingSession(source:source,now:now); sessions.append(s); return s.id
    }
    public mutating func finish(sessionIDs: Set<String>) {
        let pages=Set(captures.filter{sessionIDs.contains($0.sessionID)}.map(\.id))
        finishPhotos(pages)
        for i in sessions.indices where sessionIDs.contains(sessions[i].id) { sessions[i].completed=true }
    }
    public mutating func importKnown(_ items: [Lexeme]) {
        for item in items { lexemes[item.id]=item; var k=knowledge[item.id] ?? Knowledge(); k.imported=true; knowledge[item.id]=k }
    }
}
