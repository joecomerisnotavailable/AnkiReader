import XCTest
@testable import ReadingCore

final class WorkflowTests: XCTestCase {
    func testTextImportHandlesQuotedMultilineAndDoesNotReadSentenceWords() throws {
        let file = try AnkiTextFile("#separator:Tab\n#html:true\n#columns:Word\tReading\tSentence\n\"<ruby>薄明<rt>はくめい</rt></ruby>\"\tはくめい\t\"文の中に\n別の語\"\n")
        XCTAssertEqual(file.rows.count, 1)
        XCTAssertEqual(file.columns, ["Word", "Reading", "Sentence"])
        XCTAssertEqual(JapaneseText.clean(file.rows[0][0]), "薄明")
        XCTAssertEqual(file.rows[0][2], "文の中に\n別の語")
    }
    func testLayoutKeepsNarrowBodySentenceAndRemovesContainedDuplicate() {
        let body = TextLine(text: "になった。休日がなくなった。", region: Region(x: 0.8, y: 0.1, width: 0.025, height: 0.7))
        let full = TextLine(text: "本を読んだ。次の頁。", region: Region(x: 0.6, y: 0.1, width: 0.07, height: 0.8))
        let duplicate = TextLine(text: "本を読んだ。", region: Region(x: 0.6, y: 0.1, width: 0.07, height: 0.4))
        let third = TextLine(text: "新しい言葉。", region: Region(x: 0.4, y: 0.1, width: 0.07, height: 0.7))
        let lines = PageLayoutRepair.ordered([third, duplicate, body, full], vertical: true)
        XCTAssertEqual(lines.map(\.id), [body.id, full.id, third.id])
        XCTAssertFalse(lines[0].isRuby)
    }
    func testReprocessingPreservesCorrectionAndSelection() {
        var state = LibraryState(); let session = state.session(source: "Book")
        let capture = PageCapture(sessionID: session, imagePath: "page.jpg", fingerprint: "1")
        state.captures = [capture]
        var old = Occurrence(captureID: capture.id, lexemeID: "local:1", surface: "薄明", start: 0, end: 2, sentence: "薄明。", fragment: false)
        old.corrected = true; old.selected = true; state.occurrences = [old]
        let automatic = Occurrence(captureID: capture.id, lexemeID: "dict:1", surface: "薄", start: 0, end: 1, sentence: "薄明。", fragment: false)
        state.apply(AnalyzedPage(recognition: Recognition(engine: "fixture", lines: [], elapsed: 0), lexemes: [], occurrences: [automatic]), captureID: capture.id)
        XCTAssertEqual(state.occurrences.count, 1); XCTAssertEqual(state.occurrences[0].id, old.id)
        XCTAssertTrue(state.occurrences[0].selected); XCTAssertEqual(state.captures[0].status, .ready)
    }
    func testExportFixtureAndStableGuid() throws {
        let word = Lexeme(id: "fixture:1", expression: "薄明", reading: "はくめい", definitions: ["twilight <dawn> & dusk"], dictionaryID: "123")
        let occurrence = Occurrence(captureID: "page", lexemeID: word.id, surface: "薄明", start: 0, end: 2, sentence: "薄明の中を歩いた。", fragment: true)
        var retained = RetainedWord(lexeme: word, occurrence: occurrence, source: "Test book")
        retained.guid = "reading-test-persistent-guid"
        retained.modifiedAt = Date(timeIntervalSince1970: 1792500000)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/fixtures")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AnkiPackage.generate(words: [retained], destination: directory.appendingPathComponent("reading.apkg"))
        try AnkiPackage.generate(words: [retained], destination: directory.appendingPathComponent("reading-again.apkg"))
        XCTAssertTrue(AnkiPackage.markedExample(retained).contains("<b>薄明</b>"))
        XCTAssertEqual(AnkiPackage.html("<&>"), "&lt;&amp;&gt;")
    }
}

extension WorkflowTests {
    func testBackupRestoresMediaSelectionsAndExports() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = LibraryState(); let session = state.session(source: "Novel")
        var capture = PageCapture(sessionID: session, imagePath: "image.jpg", fingerprint: "same")
        capture.status = .processing; state.captures = [capture]
        var occurrence = Occurrence(captureID: capture.id, lexemeID: "local:1", surface: "言葉", start: 0, end: 2, sentence: "言葉。", fragment: true)
        occurrence.selected = true; state.occurrences = [occurrence]
        state.knowledge["local:1"] = Knowledge(imported: true, override: false)
        state.exports = [ExportRecord(path: "saved.apkg", lexemeIDs: ["local:1"])]
        try Data("photo".utf8).write(to: root.appendingPathComponent("image.jpg"))
        try Data("package".utf8).write(to: root.appendingPathComponent("saved.apkg"))
        let archive = root.appendingPathComponent("backup.zip")
        try LibraryBackup.create(state: state, root: root, destination: archive)
        let restored = try LibraryBackup.stageRestore(archive: archive, root: root)
        XCTAssertEqual(restored.captures[0].status, .pending)
        XCTAssertTrue(restored.occurrences[0].selected)
        XCTAssertFalse(restored.knowledge["local:1"]!.isKnown)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(restored.captures[0].imagePath)), Data("photo".utf8))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(restored.exports[0].path)), Data("package".utf8))
        XCTAssertNotEqual(restored.captures[0].imagePath, "image.jpg")
    }
    func testBackupRejectsPathTraversalAndCorruption() throws {
        let unsafe = try StoredZIP.archive([("../escape", Data("unsafe".utf8))])
        XCTAssertThrowsError(try StoredZIP.entries(unsafe))
        var corrupt = try StoredZIP.archive([("file", Data("value".utf8))])
        corrupt[34] ^= 0xff
        XCTAssertThrowsError(try StoredZIP.entries(corrupt))
        XCTAssertThrowsError(try StoredZIP.entries(Data([1,2,3])))
    }
    func testTextEditsRejectAmbiguousSelectedAnchorWithoutSaving() throws {
        var state = LibraryState(); let session = state.session(source: "Book")
        var page = PageCapture(sessionID: session, imagePath: "photo", fingerprint: "1")
        page.correctedText = "薄明の空。"; state.captures = [page]
        var occurrence = Occurrence(captureID: page.id, lexemeID: "1", surface: "薄明", start: 0, end: 2, sentence: "薄明の空。", fragment: true)
        occurrence.selected = true; state.occurrences = [occurrence]
        XCTAssertThrowsError(try state.editText(captureID: page.id, text: "薄明。薄明。"))
        try state.editText(captureID: page.id, text: "前文。薄明の空。")
        XCTAssertEqual(state.occurrences[0].start, 3)
        XCTAssertEqual(state.captures[0].status, .pending)
    }
    func testManualMergePreservesSelectedSpanAndContext() throws {
        var state = LibraryState(); let session = state.session(source: "Book")
        var page = PageCapture(sessionID: session, imagePath: "photo", fingerprint: "1")
        page.correctedText = "薄明の空。"; state.captures = [page]
        var first = Occurrence(captureID: page.id, lexemeID: "a", surface: "薄", start: 0, end: 1, sentence: page.text, fragment: true)
        first.selected = true
        let second = Occurrence(captureID: page.id, lexemeID: "b", surface: "明", start: 1, end: 2, sentence: page.text, fragment: true)
        state.occurrences = [first, second]
        try state.replaceSegments(captureID: page.id, start: 0, end: 2, surfaces: ["薄明"], words: [Lexeme(id: "c", expression: "薄明")])
        XCTAssertEqual(state.occurrences.count, 1)
        XCTAssertTrue(state.occurrences[0].selected); XCTAssertTrue(state.occurrences[0].corrected)
        XCTAssertEqual(state.occurrences[0].sentence, "薄明の空。")
    }
}

extension WorkflowTests {
    func testDictionaryUpdateRejectsBadIndexAndCanRollback() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("valid.sqlite")
        do {
            let db = try Database(url: source)
            try db.execute("PRAGMA journal_mode=DELETE; CREATE TABLE entries(id TEXT,expression TEXT,reading TEXT,definitions TEXT,commonness REAL,pos TEXT); CREATE TABLE forms(form TEXT,entry_id TEXT); CREATE TABLE metadata(key TEXT,value TEXT);")
            try db.transaction {
                for i in 0...1000 { try db.execute("INSERT INTO entries VALUES(?,'語','ご','[]',0.5,'名詞')", values: [String(i)]) }
                try db.execute("INSERT INTO metadata VALUES('source_sha256',?)", values: [String(repeating: "a", count: 64)])
                try db.execute("INSERT INTO metadata VALUES('license','https://www.edrdg.org/edrdg/licence.html')")
            }
        }
        try DictionaryVersions.install(source: source, root: root)
        let active = try DictionaryVersions.current(root: root, bundled: source)
        XCTAssertNotEqual(active, source)
        let bad = root.appendingPathComponent("invalid.sqlite")
        try Data("not a database".utf8).write(to: bad)
        XCTAssertThrowsError(try DictionaryVersions.install(source: bad, root: root))
        XCTAssertEqual(try DictionaryVersions.current(root: root, bundled: source), active)
        try DictionaryVersions.rollback(root: root)
        XCTAssertEqual(try DictionaryVersions.current(root: root, bundled: source), source)
    }
    func testNearDuplicatePageUsesProseRatherThanPageShape() {
        let text = (0..<40).map { "第\($0)章の物語を読みながら、新しい言葉を覚える。" }.joined()
        XCTAssertTrue(PageIdentity.samePage(text, text.replacingOccurrences(of: "第0章", with: "第〇章")))
        XCTAssertFalse(PageIdentity.samePage(text, (0..<40).map { "今日は\($0)人の友人と一緒に街を歩いた。" }.joined()))
        XCTAssertFalse(PageIdentity.samePage("短い文。", "短い文。"))
    }
}
