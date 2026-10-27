import XCTest
@testable import ReadingCore

final class ReadingOrderRepairTests:XCTestCase {
    private func line(_ text:String,x:Double,y:Double,height:Double)->TextLine {
        let width=0.025,slope = -0.12
        var result=TextLine(text:text,region:Region(x:x+slope*height,y:y,width:width-slope*height,height:height))
        result.corners=[ImagePoint(x:x,y:y),ImagePoint(x:x+width,y:y),ImagePoint(x:x+width+slope*height,y:y+height),ImagePoint(x:x+slope*height,y:y+height)]
        return result
    }
    func testSkewedShortColumnsDoNotOvertakeLongNeighbors() {
        let first=line("よく",x:0.8,y:0.1,height:0.8),second=line("あた",x:0.75,y:0.1,height:0.8),third=line("たかさ",x:0.7,y:0.1,height:0.3),fourth=line("私",x:0.65,y:0.1,height:0.25)
        XCTAssertEqual(PageLayoutRepair.readingOrder([third,fourth,second,first],vertical:true).map(\.text),["よく","あた","たかさ","私"])
    }
    func testRepairPreservesOriginalOCRAndMappedRegions() throws {
        var s=LibraryState();let session=s.session(source:"test")
        var page=PageCapture(sessionID:session,imagePath:"p",fingerprint:"p")
        page.recognition=Recognition(engine:"saved",lines:[line("たかさ",x:0.7,y:0.1,height:0.3),line("あた",x:0.75,y:0.1,height:0.8)],elapsed:0)
        s.captures=[page]
        s.occurrences=[Occurrence(captureID:page.id,lexemeID:"a",surface:"たかさ",start:0,end:3,sentence:"たかさあた",fragment:true),Occurrence(captureID:page.id,lexemeID:"b",surface:"あた",start:3,end:5,sentence:"たかさあた",fragment:true)]
        XCTAssertTrue(try s.repairReadingOrder(page.id));let repaired=s.captures[0]
        XCTAssertEqual(repaired.text,"あたたかさ");XCTAssertEqual(repaired.recognition?.text,"たかさあた")
        XCTAssertFalse(try s.repairReadingOrder(page.id))
        let joined=Occurrence(captureID:page.id,lexemeID:"joined",surface:"あたたかさ",start:0,end:5,sentence:"あたたかさ",fragment:true)
        XCTAssertEqual(TermGeometry.regions(page:repaired,occurrences:[joined]).count,2)
        XCTAssertEqual(CorrectionMapping.cells(repaired).map(\.start),[3,4,0,1,2])
    }
    func testNoncontiguousSourceRunsDoNotHighlightInterveningText() throws {
        var page=PageCapture(sessionID:"s",imagePath:"p",fingerprint:"p")
        page.recognition=Recognition(engine:"saved",lines:[line("たかさ他",x:0.7,y:0.1,height:0.3),line("前あた",x:0.75,y:0.1,height:0.8)],elapsed:0)
        page.correctedText="前あたたかさ他"
        page.sourceMap=[4,5,6,0,1,2,3].map{SourceSpan($0,$0+1)}
        let joined=Occurrence(captureID:page.id,lexemeID:"w",surface:"あたたかさ",start:1,end:6,sentence:page.text,fragment:true)
        let regions=TermGeometry.regions(page:page,occurrences:[joined])
        XCTAssertEqual(regions.count,2);XCTAssertEqual(regions.map(\.characterCount).reduce(0,+),5)
    }
    func testHorizontalOrderUsesRowCenterlines() {
        func transpose(_ l:TextLine)->TextLine {
            var result=l;result.region=Region(x:l.region.y,y:l.region.x,width:l.region.height,height:l.region.width)
            result.corners=l.corners?.map{ImagePoint(x:$0.y,y:$0.x)};return result
        }
        let top=transpose(line("Top",x:0.5,y:0.1,height:0.8)),bottom=transpose(line("Bottom",x:0.55,y:0.1,height:0.25))
        XCTAssertEqual(PageLayoutRepair.readingOrder([bottom,top],vertical:false).map(\.text),["Top","Bottom"])
    }
    func testReportedSavedCapture() throws {
        guard let path=ProcessInfo.processInfo.environment["COLUMN_REPAIR_LIBRARY"] else { return }
        var state=try JSONDecoder().decode(LibraryState.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        let id="3248A2D1-0F59-4B10-AE8D-3A9E2393A028"
        let original=try XCTUnwrap(state.captures.first{$0.id==id}),retained=try JSONEncoder().encode(state.retained)
        XCTAssertTrue(try state.repairReadingOrder(id))
        let page=try XCTUnwrap(state.captures.first{$0.id==id})
        XCTAssertTrue(page.text.contains("あたたかさ"))
        XCTAssertTrue(page.text.contains("よく見て"))
        XCTAssertEqual(page.corrections?.count,original.corrections?.count)
        XCTAssertEqual(page.recognition?.text,original.recognition?.text)
        // Dictionary states and frozen cards are not rewritten by layout repair.
        XCTAssertEqual(try JSONDecoder().decode([String:RetainedWord].self,from:retained).count,state.retained.count)
        for o in state.occurrences where o.captureID==id { XCTAssertEqual(JapaneseText.slice(page.text,o.start,o.end),o.surface) }
    }
}
