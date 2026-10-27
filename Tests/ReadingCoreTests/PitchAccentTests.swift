import XCTest
@testable import ReadingCore
final class PitchAccentTests:XCTestCase {
    func testMoraeAndDropIncludingFollowingParticle() {
        XCTAssertEqual(PitchAccent.morae("キョウシツ"),["きょ","う","し","つ"])
        XCTAssertEqual(PitchAccent.morae("がっこう"),["が","っ","こ","う"])
        XCTAssertEqual(PitchAccent.heights(moraCount:3,drop:0),[false,true,true,true])
        XCTAssertEqual(PitchAccent.heights(moraCount:3,drop:3),[false,true,true,false])
        XCTAssertEqual(PitchAccent.heights(moraCount:3,drop:1),[true,false,false,false])
        XCTAssertTrue(PitchAccent.heights(moraCount:3,drop:4).isEmpty)
    }
    func testBundledPitchUsesSpellingAndReading() throws {
        let url=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/dictionary.sqlite")
        guard FileManager.default.fileExists(atPath:url.path) else { throw XCTSkip("Local dictionary required") }
        let index=try PitchIndex(url:url)
        XCTAssertEqual(try index.lookup(expression:"食べる",reading:"たべる").map(\.position),[2])
        XCTAssertTrue(try index.lookup(expression:"食べる",reading:"はる").isEmpty)
    }
    func testCharacterAlternativesRejectSentenceAndPreserveOtherCharacters() {
        XCTAssertNil(CorrectionCandidates.characterReplacement(original:"無恨",offset:0,length:1,candidate:"悔恨のうち"))
        XCTAssertEqual(CorrectionCandidates.characterReplacement(original:"無恨",offset:0,length:1,candidate:"悔"),"悔恨")
    }
}
