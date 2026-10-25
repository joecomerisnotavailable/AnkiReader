import XCTest
@testable import ReadingCore

final class PageEditingTests:XCTestCase {
    private func fixture(_ text:String="なだにめる。",parts:[String]=["なだ","に","め","る","。"])->LibraryState {
        var s=LibraryState();let session=s.session(source:"Test")
        var page=PageCapture(sessionID:session,imagePath:"page.jpg",fingerprint:"f");page.status = .ready
        page.recognition=Recognition(engine:"saved",lines:[TextLine(text:text,region:Region(x:0.1,y:0.1,width:0.1,height:0.7))],elapsed:0);s.captures=[page]
        var offset=0
        for part in parts { let word=Lexeme(id:part,expression:part);s.lexemes[part]=word;s.occurrences.append(Occurrence(captureID:page.id,lexemeID:part,surface:part,start:offset,end:offset+part.unicodeScalars.count,sentence:text,fragment:false));offset += part.unicodeScalars.count }
        return s
    }
    private func apply(_ command:PageEditCommand,to s:inout LibraryState) throws {
        let p=s.captures[0],result=try PageEditing.segments(page:p,occurrences:s.occurrences,command:command)
        try s.replaceSegments(captureID:p.id,start:result.0.lowerBound,end:result.0.upperBound,surfaces:result.1,words:result.1.map{Lexeme(id:$0,expression:$0)})
        s.reconcilePageDecisions(p.id)
    }
    func testHandwritingInsertionAndSelectedCharacterReplacement() {
        XCTAssertEqual(DraftInsertion.apply("海",to:"泣き",selection:NSRange(location:0,length:1))?.text,"海き")
        XCTAssertEqual(DraftInsertion.apply("海",to:"泣き",selection:NSRange(location:1,length:0))?.text,"泣海き")
        XCTAssertEqual(DraftInsertion.apply("悔",to:"👩‍💻泣き",selection:NSRange(location:"👩‍💻".utf16.count,length:1))?.text,"👩‍💻悔き")
        XCTAssertNil(DraftInsertion.apply("海",to:"泣き",selection:NSRange(location:4,length:1)))
    }
    func testPartialJoinPreservesOutsideFragmentsAndText() throws {
        var s=fixture("あいうえお",parts:["あいう","えお"])
        try apply(.join(1..<4),to:&s)
        XCTAssertEqual(s.occurrences.sorted{$0.start<$1.start}.map(\.surface),["あ","いうえ","お"])
        XCTAssertEqual(s.captures[0].text,"あいうえお")
    }
    func testShatterGraphemesAndRejectMidCharacterJoin() throws {
        var s=fixture("か\u{3099}👩‍💻",parts:["か\u{3099}👩‍💻"])
        let id=s.occurrences[0].id
        XCTAssertThrowsError(try PageEditing.segments(page:s.captures[0],occurrences:s.occurrences,command:.join(1..<2)))
        try apply(.shatter(id),to:&s)
        XCTAssertEqual(s.occurrences.map(\.surface),["か\u{3099}","👩‍💻"])
    }
    func testManualExamplesSurviveJoinAndBlockRetentionUntilRepaired() throws {
        var s=fixture();s.occurrences[0].manualExample=true;s.occurrences[0].sentence="なだ is my manual example";s.occurrences[0].selected=true
        s.occurrences[1].manualExample=true;s.occurrences[1].sentence="に is another manual example"
        try apply(.join(0..<3),to:&s)
        let item=s.occurrences.first{$0.start==0}!
        XCTAssertTrue(item.needsExampleRepair);XCTAssertTrue(item.selected)
        XCTAssertEqual(Set(item.exampleAlternatives!.map(\.text)),["なだ is my manual example","に is another manual example"])
        s.finishPhotos([s.captures[0].id]);XCTAssertTrue(s.retained.isEmpty);XCTAssertNotEqual(s.captures[0].reviewCompleted,true)
        let restored=try JSONDecoder().decode(LibraryState.self,from:JSONEncoder().encode(s))
        XCTAssertEqual(restored.occurrences.first{$0.start==0}?.exampleAlternatives,item.exampleAlternatives)
    }
    func testMissingLiteralTextMaterializedWithoutReprocessing() {
        var s=fixture("あ い",parts:["あ"])
        let original=s.captures[0].recognition
        s.materializePageGaps(s.captures[0].id);s.materializePageGaps(s.captures[0].id)
        XCTAssertEqual(s.occurrences.count,2)
        XCTAssertEqual(s.occurrences.sorted{$0.start<$1.start}.map(\.surface).joined(),"あ い")
        XCTAssertEqual(s.captures[0].recognition?.text,original?.text)
    }
    func testDeletionPreservesBoundariesThenExplicitJoin() throws {
        var s=fixture();let p=s.captures[0],target=s.occurrences[1]
        let preview=CorrectionPreview(pageID:p.id,revision:0,originalPage:p,originalText:p.text,originalOccurrences:s.occurrences,start:target.start,end:target.end,replacement:"",method:.typing,window:target.start..<target.end,occurrences:[],lexemes:[],manualBoundaries:false)
        try s.applyCorrection(preview)
        XCTAssertEqual(s.occurrences.sorted{$0.start<$1.start}.map(\.surface),["なだ","め","る","。"])
        try apply(.join(0..<4),to:&s)
        XCTAssertEqual(s.occurrences.first{$0.start==0}?.surface,"なだめる")
        XCTAssertEqual(CorrectionMapping.source(s.captures[0],start:0,end:4),SourceSpan(0,5))
        XCTAssertEqual(CorrectionMapping.history(s.occurrences.first{$0.start==0}!,page:s.captures[0]).first?.before,"に")
    }
}
