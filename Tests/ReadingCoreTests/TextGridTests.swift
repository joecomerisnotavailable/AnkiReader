import XCTest
@testable import ReadingCore

final class TextGridTests:XCTestCase {
    func testTermAcrossColumnsKeepsOneIdentityAndTwoRegions() {
        for vertical in [true,false] {
            var page=PageCapture(sessionID:"s",imagePath:"p",fingerprint:"p"); page.layout=vertical ? "Vertical" : "Horizontal"
            page.recognition=Recognition(engine:"saved",lines:[
                TextLine(text:"猫私",region:vertical ? Region(x:0.8,y:0.1,width:0.1,height:0.2) : Region(x:0.1,y:0.2,width:0.2,height:0.1)),
                TextLine(text:"立。",region:vertical ? Region(x:0.6,y:0.1,width:0.1,height:0.2) : Region(x:0.1,y:0.4,width:0.2,height:0.1))],elapsed:0)
            let term=Occurrence(captureID:page.id,lexemeID:"private",surface:"私立",start:1,end:3,sentence:"猫私立。",fragment:true)
            let grid=TextGridLayout.make(page:page,occurrences:[term])
            XCTAssertEqual(grid.glyphs.map(\.text),["猫","私","立","。"])
            XCTAssertEqual(grid.regions.count,2); XCTAssertTrue(grid.regions.allSatisfy{$0.occurrenceID==term.id})
            XCTAssertEqual(grid.glyphs[2].box.width,grid.glyphs[3].box.width)
            XCTAssertEqual(grid.glyphs[2].box.height,grid.glyphs[3].box.height)
            if vertical { XCTAssertGreaterThan(grid.glyphs[0].box.x,grid.glyphs[2].box.x) }
            else { XCTAssertLessThan(grid.glyphs[0].box.y,grid.glyphs[2].box.y) }
        }
    }
    func testSkewedOverlappingColumnBoxesNeverConcatenate() {
        for vertical in [true,false] {
            var page=PageCapture(sessionID:"s",imagePath:"p",fingerprint:"p"); page.layout=vertical ? "Vertical" : "Horizontal"
            page.recognition=Recognition(engine:"saved",lines:[
                TextLine(text:"日本語の列",region:vertical ? Region(x:0.4,y:0.1,width:0.15,height:0.7) : Region(x:0.1,y:0.4,width:0.7,height:0.15)),
                TextLine(text:"別の文章。",region:vertical ? Region(x:0.43,y:0.12,width:0.15,height:0.7) : Region(x:0.12,y:0.43,width:0.7,height:0.15))],elapsed:0)
            let grid=TextGridLayout.make(page:page,occurrences:[])
            XCTAssertEqual(grid.glyphs.count,10)
            if vertical { XCTAssertNotEqual(grid.glyphs[0].box.x,grid.glyphs[5].box.x); XCTAssertLessThan(grid.height,300) }
            else { XCTAssertNotEqual(grid.glyphs[0].box.y,grid.glyphs[5].box.y); XCTAssertLessThan(grid.width,300) }
        }
    }
    func testFragmentsInSameColumnAndManualInsertionKeepAllText() {
        var page=PageCapture(sessionID:"s",imagePath:"p",fingerprint:"p"); page.layout="Vertical"
        page.recognition=Recognition(engine:"saved",lines:[TextLine(text:"日本",region:Region(x:0.8,y:0.1,width:0.1,height:0.2)),TextLine(text:"語。",region:Region(x:0.8,y:0.3,width:0.1,height:0.2)),TextLine(text:"次頁",region:Region(x:0.6,y:0.1,width:0.1,height:0.2))],elapsed:0)
        page.correctedText="新日本語。次頁"
        let grid=TextGridLayout.make(page:page,occurrences:[])
        XCTAssertEqual(grid.glyphs.map(\.text).joined(),page.text)
        XCTAssertEqual(grid.glyphs[0].box.x,grid.glyphs[4].box.x)
        XCTAssertNotEqual(grid.glyphs[4].box.x,grid.glyphs[5].box.x)
        XCTAssertEqual(grid.glyphs.last?.end,page.text.unicodeScalars.count)
    }
}
