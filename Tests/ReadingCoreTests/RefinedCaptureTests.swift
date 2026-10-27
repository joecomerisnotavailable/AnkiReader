import XCTest
@testable import ReadingCore

final class RefinedCaptureTests: XCTestCase {
    private func data<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    private func line(_ text: String) -> TextLine {
        var line = TextLine(text: text, region: Region(x: 0.3, y: 0.1, width: 0.05, height: 0.8))
        line.corners = TermGeometry.rectangle(line.region)
        line.elements = [TextElementGeometry(text: text, start: 0, end: text.unicodeScalars.count, corners: line.corners!)]
        return line
    }
    private func fixture() -> LibraryState {
        var state = LibraryState()
        let session = state.session(source: "Novel")
        var page = PageCapture(sessionID: session, imagePath: "page.jpg", fingerprint: "page")
        page.status = .ready; page.layout = "Vertical"
        page.recognition = Recognition(engine: "ML Kit", lines: [line("注目をめている。")], elapsed: 0.1)
        page.recognition?.rawLines = [line("immutable raw OCR")]
        page.textRevision = 4; page.dismissedParsingSuggestions = ["old suggestion"]
        state.captures = [page]
        var offset = 0
        for (surface, id) in [("注目", "notice"), ("を", "particle"), ("めている", "old-verb"), ("。", "period")] {
            let word = Lexeme(id: id, expression: surface)
            state.lexemes[id] = word
            var occurrence = Occurrence(captureID: page.id, lexemeID: id, surface: surface,
                start: offset, end: offset + surface.unicodeScalars.count,
                lineIDs: [page.recognition!.lines[0].id], sentence: page.text, fragment: false)
            occurrence.selected = id == "old-verb"
            state.occurrences.append(occurrence)
            offset = occurrence.end
        }
        return state
    }
    private func analysis(_ state: LibraryState, parts: [(String, String)] = [("注目", "notice"), ("を", "particle"), ("集めている", "gather"), ("。", "period")]) -> AnalyzedPage {
        let page = state.captures[0], text = parts.map(\.0).joined()
        var result = AnalyzedPage(recognition: Recognition(engine: "refined", lines: [line(text)], elapsed: 0.2), lexemes: [], occurrences: [])
        var offset = 0
        for (surface, id) in parts {
            result.lexemes.append(Lexeme(id: id, expression: surface))
            result.occurrences.append(Occurrence(captureID: page.id, lexemeID: id, surface: surface,
                start: offset, end: offset + surface.unicodeScalars.count,
                lineIDs: [result.recognition.lines[0].id], sentence: text, fragment: false))
            offset += surface.unicodeScalars.count
        }
        return result
    }
    func testInsertionPreservesSelectionsStableIdentitiesAndRawOCR() throws {
        var state = fixture()
        let before = state, id = state.captures[0].id
        let unrelated = Occurrence(captureID: "another-page", lexemeID: "notice", surface: "注目", start: 0, end: 2, sentence: "注目。", fragment: false)
        state.occurrences.append(unrelated)
        try state.applyRefinement(analysis(state), captureID: id)
        XCTAssertEqual(state.captures[0].text, "注目を集めている。")
        XCTAssertEqual(state.captures[0].textRevision, 5)
        XCTAssertNil(state.captures[0].dismissedParsingSuggestions)
        XCTAssertEqual(state.captures[0].recognition?.rawLines, before.captures[0].recognition?.rawLines)
        let updated = state.occurrences.filter { $0.captureID == id }
        XCTAssertEqual(updated.map(\.surface), ["注目", "を", "集めている", "。"])
        XCTAssertEqual(updated.map(\.selected), [false, false, true, false])
        XCTAssertEqual(updated[0].id, before.occurrences[0].id)
        XCTAssertEqual(updated[1].id, before.occurrences[1].id)
        XCTAssertEqual(updated[3].id, before.occurrences[3].id)
        XCTAssertNotEqual(updated[2].id, before.occurrences[2].id)
        XCTAssertEqual(updated[3].start, 8)
        for item in updated {
            XCTAssertEqual(JapaneseText.slice(state.captures[0].text, item.start, item.end), item.surface)
            XCTAssertEqual(item.sentence, state.captures[0].text)
        }
        XCTAssertEqual(try data(state.occurrences.first { $0.captureID == "another-page" }!), try data(unrelated))
        XCTAssertEqual(state.captures[0].reviewMarks?["gather"], .selected)
    }
    func testGlobalKnowledgeStaysWithOriginalLexicalIdentity() throws {
        var state = fixture()
        state.occurrences[2].selected = false
        state.knowledge = ["old-verb": Knowledge(imported: true, override: false), "notice": Knowledge(override: true)]
        state.captures[0].reviewMarks = ["old-verb": .unknown, "notice": .known]
        state.captures[0].excludedLexemeIDs = ["old-verb", "notice"]
        let knowledge = try data(state.knowledge)
        try state.applyRefinement(analysis(state), captureID: state.captures[0].id)
        XCTAssertEqual(try data(state.knowledge), knowledge)
        XCTAssertNil(state.knowledge["gather"])
        XCTAssertNil(state.captures[0].reviewMarks?["gather"])
        XCTAssertNil(state.captures[0].reviewMarks?["old-verb"])
        XCTAssertEqual(state.captures[0].reviewMarks?["notice"], .known)
        XCTAssertEqual(state.captures[0].excludedLexemeIDs, ["notice"])
        XCTAssertFalse(state.occurrences.contains { $0.selected })
    }
    func testRetainedCardsExportsAndBackupRoundTripRemainIntact() throws {
        var state = fixture()
        let old = state.occurrences[2]
        state.retained[old.lexemeID] = RetainedWord(lexeme: state.lexemes[old.lexemeID]!, occurrence: old, source: "Novel")
        state.exports = [ExportRecord(path: "exports/snapshot.apkg", lexemeIDs: [old.lexemeID])]
        state.retainedGUIDs = [old.lexemeID: "persistent-guid"]
        let retained = try data(state.retained), exports = try data(state.exports), guids = state.retainedGUIDs
        try state.applyRefinement(analysis(state), captureID: state.captures[0].id)
        XCTAssertEqual(try data(state.retained), retained)
        XCTAssertEqual(try data(state.exports), exports)
        XCTAssertEqual(state.retainedGUIDs, guids)
        let restored = try JSONDecoder().decode(LibraryState.self, from: data(state))
        XCTAssertEqual(try data(restored.captures), try data(state.captures))
        XCTAssertEqual(try data(restored.occurrences), try data(state.occurrences))
        XCTAssertEqual(try data(restored.retained), retained)
        XCTAssertEqual(try data(restored.exports), exports)
        XCTAssertEqual(restored.basicWords, state.basicWords)
        XCTAssertEqual(restored.retained[old.lexemeID]?.example, "注目をめている。")
    }
    func testManualTextMapsBoundariesAndExamplesRejectWithoutMutation() throws {
        let protectors: [(inout LibraryState) -> Void] = [
            { $0.captures[0].correctedText = $0.captures[0].text },
            { $0.captures[0].sourceMap = [SourceSpan(0, 1)] },
            { $0.captures[0].corrections = [TextCorrection(before: "無", after: "悔", method: .typing, source: SourceSpan(0, 1), start: 0, end: 1, revision: 1)] },
            { $0.occurrences[0].corrected = true },
            { $0.occurrences[0].manualExample = true; $0.occurrences[0].sentence = "My 注目 example" },
            { $0.captures[0].status = .processing }
        ]
        for protect in protectors {
            var state = fixture(); let proposal = analysis(state)
            protect(&state)
            let before = try data(state), id = state.captures[0].id
            XCTAssertFalse(state.canRefineCapture(id))
            XCTAssertThrowsError(try state.applyRefinement(proposal, captureID: id))
            XCTAssertEqual(try data(state), before)
        }
        var state = fixture()
        XCTAssertFalse(state.canRefineCapture("missing"))
        XCTAssertThrowsError(try state.applyRefinement(analysis(state), captureID: "missing"))
    }
    func testSubstitutionOrDeletionRejectsAtomically() throws {
        for parts in [[("注意", "attention"), ("を", "particle"), ("めている", "old-verb"), ("。", "period")], [("注目", "notice"), ("めている", "old-verb"), ("。", "period")]] {
            var state = fixture(); let before = try data(state)
            XCTAssertThrowsError(try state.applyRefinement(analysis(state, parts: parts), captureID: state.captures[0].id))
            XCTAssertEqual(try data(state), before)
        }
    }
    func testGeometryOnlyRefinementKeepsIDsAndCapturesLegacyRawLines() throws {
        var state = fixture()
        state.captures[0].recognition?.rawLines = nil
        let originalLines = state.captures[0].recognition!.lines, originalIDs = state.occurrences.map(\.id)
        let parts = state.occurrences.map { ($0.surface, $0.lexemeID) }
        var proposal = analysis(state, parts: parts)
        proposal.recognition.rawLines = [line("replacement must not become original OCR")]
        proposal.recognition.lines[0].elements?[0].corners[0].y = 0.12
        try state.applyRefinement(proposal, captureID: state.captures[0].id)
        XCTAssertEqual(state.occurrences.map(\.id), originalIDs)
        XCTAssertEqual(state.captures[0].recognition?.rawLines, originalLines)
        XCTAssertEqual(state.captures[0].recognition?.lines[0].elements?[0].corners[0].y, 0.12)
    }
    private func chunk(_ text: String, from: Double = 0, to: Double = 1) -> RecognitionRefinement.Chunk {
        let q = TermGeometry.slice(line(text).corners!, from: from, to: to, vertical: true)
        let cells = (0..<text.count).map { TermGeometry.slice(q, from: Double($0)/Double(text.count), to: Double($0+1)/Double(text.count), vertical: true) }
        return .init(text: text, from: from, to: to, cells: cells, estimatedCellCount: Double(text.count))
    }
    func testDuplicateChunksAndWhitespaceCannotDuplicateOrDeleteText() {
        let original = line("注目をめている")
        let retry = chunk("注目を集めている")
        let duplicate = RecognitionRefinement.refine(line: original, chunks: [retry, retry], vertical: true)
        XCTAssertEqual(duplicate, original)
        let spaced = line("注目を めている")
        XCTAssertEqual(RecognitionRefinement.refine(line: spaced, chunks: [retry], vertical: true), spaced)
    }
    func testUntouchedMissingElementGeometryUsesOriginalOffsets() throws {
        var original = line("注目をめている新鋭")
        // Only the first occurrence had an SDK element. The untouched tail must
        // retain its old line-derived location when 集 is inserted before it.
        original.elements = [TextElementGeometry(text: "注目", start: 0, end: 2,
            corners: TermGeometry.slice(original.corners!, from: 0, to: 2.0/9, vertical: true))]
        let refined = RecognitionRefinement.refine(line: original,
            chunks: [chunk("注目を集めている", from: 0, to: 7.0/9)], vertical: true)
        XCTAssertEqual(refined.text, "注目を集めている新鋭")
        let tail = try XCTUnwrap(refined.elements?.first { $0.text == "新鋭" })
        XCTAssertEqual(tail.start, 8); XCTAssertEqual(tail.end, 10)
        let expected = TermGeometry.slice(original.corners!, from: 7.0/9, to: 1, vertical: true)
        for (actual, wanted) in zip(tail.corners, expected) {
            XCTAssertEqual(actual.x, wanted.x, accuracy: 1e-12)
            XCTAssertEqual(actual.y, wanted.y, accuracy: 1e-12)
        }
    }
}
