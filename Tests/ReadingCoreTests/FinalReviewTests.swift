import XCTest
@testable import ReadingCore

final class FinalReviewTests:XCTestCase {
    private func fixture()->LibraryState {
        var state=LibraryState(); let session=state.session(source:"Book")
        var page=PageCapture(sessionID:session,imagePath:"saved.jpg",fingerprint:"saved")
        page.status = .ready; page.correctedText="猫。犬。鳥。私。"
        state.captures=[page]
        for (i,word) in ["猫","犬","鳥","私"].enumerated() {
            state.lexemes[word]=Lexeme(id:word,expression:word,reading:word,definitions:["fixture"],commonness:1,dictionaryID:word)
            state.occurrences.append(Occurrence(captureID:page.id,lexemeID:word,surface:word,start:i*2,end:i*2+1,sentence:word+"。",fragment:false))
        }
        return state
    }
    func testMarksSurviveFilteringRoundTripAndAreEditable() throws {
        var state=fixture(); let page=state.captures[0].id
        state.select("猫",occurrenceID:state.occurrences[0].id,pages:[page],selected:true)
        state.classify("犬",known:true,pageID:page)
        state.classify("鳥",known:false,pageID:page)
        XCTAssertTrue(state.knowledge["犬"]!.isKnown)
        XCTAssertFalse(state.knowledge["鳥"]!.isKnown)
        XCTAssertEqual(Set(state.finalReview(pageID:page).marked.map(\.id)),Set(["猫","犬","鳥"]))
        XCTAssertTrue(state.finalReview(pageID:page).unmarked.isEmpty) // 私 stays filtered.
        state=try JSONDecoder().decode(LibraryState.self,from:JSONEncoder().encode(state))
        state.classify("犬",known:false,pageID:page)
        XCTAssertEqual(state.reviewMark("犬",pageID:page),.unknown)
        XCTAssertFalse(state.knowledge["犬"]!.isKnown)
        state.clearReviewMark("鳥",pageID:page)
        XCTAssertEqual(state.finalReview(pageID:page).unmarked.map(\.id),["鳥"])
        state.finishPhotos([page])
        XCTAssertEqual(Set(state.retained.keys),["猫"])
    }
    func testLegacyMarksAreRecoveredWithoutLosingKnowledge() {
        var state=fixture(); let page=state.captures[0].id
        state.occurrences[0].selected=true
        state.captures[0].excludedLexemeIDs=["犬","鳥"]
        state.knowledge["犬"]=Knowledge(override:true); state.knowledge["鳥"]=Knowledge(override:false)
        state.migratePhotoReviews()
        XCTAssertEqual(state.reviewMark("猫",pageID:page),.selected)
        XCTAssertEqual(state.reviewMark("犬",pageID:page),.known)
        XCTAssertEqual(state.reviewMark("鳥",pageID:page),.unknown)
        state.clearReviewMark("犬",pageID:page); state.migratePhotoReviews()
        XCTAssertNil(state.reviewMark("犬",pageID:page)); XCTAssertTrue(state.knowledge["犬"]!.isKnown)
    }
    func testRemovingRetainedClearsSelectionButPreservesExportAndGuid() {
        var state=fixture(); let page=state.captures[0].id
        state.select("猫",occurrenceID:state.occurrences[0].id,pages:[page],selected:true); state.finishPhotos([page])
        let guid=state.retained["猫"]!.guid
        state.exports=[ExportRecord(path:"old.apkg",lexemeIDs:["猫"])]
        let removed=state.removeRetained("猫")
        XCTAssertEqual(removed?.guid,guid); XCTAssertNil(state.retained["猫"])
        XCTAssertFalse(state.occurrences[0].selected); XCTAssertNil(state.reviewMark("猫",pageID:page))
        XCTAssertEqual(state.exports[0].lexemeIDs,["猫"]); XCTAssertNil(state.knowledge["猫"])
        state.select("猫",occurrenceID:state.occurrences[0].id,pages:[page],selected:true); state.finishPhotos([page])
        XCTAssertEqual(state.retained["猫"]?.guid,guid)
    }
    func testInkSnappingMovesDelimiterIntoGapForBothDirections() {
        for vertical in [true,false] {
            var pixels=[UInt8](repeating:240,count:200*200)
            for y in 0..<200 { for x in 0..<200 {
                let along=vertical ? y : x, across=vertical ? x : y
                if (40..<80).contains(across), (24..<52).contains(along) || (64..<108).contains(along) || (116..<150).contains(along) { pixels[y*200+x]=25 }
            } }
            let region=vertical ? Region(x:0.2,y:0.1,width:0.2,height:0.42) : Region(x:0.1,y:0.2,width:0.42,height:0.2)
            let original=TermRegion(id:"term",occurrenceID:"o",corners:TermGeometry.rectangle(region),estimated:true,vertical:vertical,characterCount:2)
            let refined=InkGeometry.refine([original],raster:PageRaster(width:200,height:200,pixels:pixels))[0]
            XCTAssertEqual(refined.trailingGap,true)
            let edge=TermGeometry.separator(refined)
            let endpoint=vertical ? edge[0].y : edge[0].x
            XCTAssertGreaterThan(endpoint,0.54); XCTAssertLessThan(endpoint,0.58)
        }
    }
    func testNoHardDelimiterWhenPhotographHasNoReliableGap() {
        let term=TermRegion(id:"term",occurrenceID:"o",corners:TermGeometry.rectangle(Region(x:0.2,y:0.2,width:0.2,height:0.5)),estimated:true,vertical:true,characterCount:3)
        let refined=InkGeometry.refine([term],raster:PageRaster(width:100,height:100,pixels:[UInt8](repeating:90,count:10000)))[0]
        XCTAssertEqual(refined.trailingGap,false); XCTAssertEqual(refined.corners,term.corners)
    }
}
