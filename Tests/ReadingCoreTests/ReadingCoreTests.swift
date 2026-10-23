import XCTest
@testable import ReadingCore

final class ReadingCoreTests:XCTestCase {
    func testNotKnownOverrideSurvivesReimport() {
        var state=LibraryState();let word=Lexeme(id:"1",expression:"薄明",reading:"はくめい")
        state.importKnown([word]);XCTAssertTrue(state.knowledge["1"]!.isKnown)
        state.knowledge["1"]!.override=false;state.importKnown([word])
        XCTAssertFalse(state.knowledge["1"]!.isKnown)
        XCTAssertTrue(state.knowledge["1"]!.imported)
    }
    func testSessionBoundaryAndCompletedSession() {
        var state=LibraryState();let now=Date()
        let first=state.session(source:"Novel",now:now)
        XCTAssertEqual(first,state.session(source:"Novel",now:now.addingTimeInterval(1799)))
        let second=state.session(source:"Novel",now:now.addingTimeInterval(3600))
        XCTAssertNotEqual(first,second)
        state.finish(sessionIDs:[second])
        XCTAssertNotEqual(second,state.session(source:"Novel",now:now.addingTimeInterval(3601)))
    }
    func testFinishingSkipsWithoutMarkingKnownAndFreezesSelectedContext() {
        var state=fixture();state.occurrences[0].selected=true
        let session=state.sessions[0].id
        state.finish(sessionIDs:[session])
        XCTAssertEqual(state.retained["word"]?.example,"薄明の中を歩いた。")
        XCTAssertNil(state.knowledge["word"])
        state.occurrences[0].sentence="変更した文。";state.finish(sessionIDs:[session])
        XCTAssertEqual(state.retained["word"]?.example,"薄明の中を歩いた。")
        XCTAssertTrue(state.sessions[0].completed)
    }
    func testDuplicateImageDoesNotIncreaseRecurrence() {
        var state=fixture();let before=Recommender.ranked(state:state,captureIDs:Set(state.captures.map(\.id)))[0].score
        var duplicate=state.captures[0];duplicate.id="duplicate";state.captures.append(duplicate)
        var occurrence=state.occurrences[0];occurrence.id="second";occurrence.captureID=duplicate.id;state.occurrences.append(occurrence)
        let after=Recommender.ranked(state:state,captureIDs:Set(state.captures.map(\.id)))
        XCTAssertEqual(after.count,1);XCTAssertEqual(before,after[0].score,accuracy:0.00001)
    }
    func testKnownWordsRemainAccessibleAndExplicitSelectionsRemainVisible() {
        var state=fixture();state.knowledge["word"]=Knowledge(override:true)
        let pages=Set(state.captures.map(\.id))
        XCTAssertTrue(Recommender.ranked(state:state,captureIDs:pages).isEmpty)
        XCTAssertEqual(Recommender.ranked(state:state,captureIDs:pages,showAll:true).count,1)
        state.occurrences[0].selected=true
        XCTAssertEqual(Recommender.ranked(state:state,captureIDs:pages).count,1)
    }
    func testScalarOffsetsAndFragments() {
        XCTAssertEqual(JapaneseText.slice("𠮷野で読んだ",0,2),"𠮷野")
        let complete=JapaneseText.example(text:"前文。薄明の中を歩いた。後文。",start:3,end:5)
        XCTAssertEqual(complete.0,"薄明の中を歩いた。");XCTAssertFalse(complete.1)
        XCTAssertTrue(JapaneseText.example(text:"続きの断片",start:2,end:4).1)
    }
    func testRubyAndHTMLImportCleaning() {
        XCTAssertEqual(JapaneseText.clean("<ruby>薄明<rt>はくめい</rt></ruby>&nbsp;"),"薄明")
        XCTAssertEqual(JapaneseText.clean("薄明[はくめい]"),"薄明")
    }
    func testLibraryPersistenceAndRollback() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let url=root.appendingPathComponent("library.sqlite"),store=try LibraryStore(url:url)
        var state=fixture();state.occurrences[0].selected=true;try store.save(state)
        XCTAssertTrue(try LibraryStore(url:url).load().occurrences[0].selected)
        let db=try Database(url:root.appendingPathComponent("transaction.sqlite"))
        try db.execute("CREATE TABLE value(id TEXT PRIMARY KEY)")
        XCTAssertThrowsError(try db.transaction {try db.execute("INSERT INTO value VALUES(?)",values:["first"]);try db.execute("INSERT INTO missing VALUES(1)")})
        XCTAssertTrue(try db.rows("SELECT * FROM value").isEmpty)
    }
    private func fixture()->LibraryState {
        var state=LibraryState();let session=state.session(source:"Novel")
        let capture=PageCapture(sessionID:session,imagePath:"one.jpg",fingerprint:"same-page")
        state.captures=[capture];state.lexemes["word"]=Lexeme(id:"word",expression:"薄明",reading:"はくめい",definitions:["twilight"],commonness:0.5,dictionaryID:"123")
        state.occurrences=[Occurrence(captureID:capture.id,lexemeID:"word",surface:"薄明",start:0,end:2,sentence:"薄明の中を歩いた。",fragment:false)]
        return state
    }
}
