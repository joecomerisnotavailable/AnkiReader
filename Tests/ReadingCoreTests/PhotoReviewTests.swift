import XCTest
@testable import ReadingCore

final class PhotoReviewTests:XCTestCase {
    private func fixture()->LibraryState {
        var state=LibraryState(); let session=state.session(source:"Novel")
        for index in 0..<2 {
            var page=PageCapture(sessionID:session,imagePath:"\(index).jpg",fingerprint:"\(index)")
            page.status = .ready; page.layout="Vertical"
            page.recognition=Recognition(engine:"saved-fixture",lines:[TextLine(text:"本を読んだ。",region:Region(x:0.7,y:0.1,width:0.1,height:0.6))],elapsed:0)
            state.captures.append(page)
            state.lexemes["book"]=Lexeme(id:"book",expression:"本",reading:"ほん",definitions:["book"],commonness:1,dictionaryID:"1")
            state.occurrences.append(Occurrence(captureID:page.id,lexemeID:"book",surface:"本",start:0,end:1,sentence:page.text,fragment:true))
        }
        return state
    }
    func testMigrationAndFinishOnlyCurrentPhoto() throws {
        var state=fixture(); state.occurrences[0].selected=true
        // Decode a pre-redesign library with no new fields.
        var json=try JSONSerialization.jsonObject(with:JSONEncoder().encode(state)) as! [String:Any]
        var pages=json["captures"] as! [[String:Any]]
        for i in pages.indices { pages[i].removeValue(forKey:"reviewCompleted"); pages[i].removeValue(forKey:"excludedLexemeIDs") }
        json["captures"]=pages
        state=try JSONDecoder().decode(LibraryState.self,from:JSONSerialization.data(withJSONObject:json))
        state.migratePhotoReviews()
        XCTAssertEqual(state.captures.map(\.reviewCompleted),[false,false])
        state.finishPhotos([state.captures[0].id])
        XCTAssertTrue(state.isReviewed(state.captures[0])); XCTAssertFalse(state.isReviewed(state.captures[1]))
        XCTAssertFalse(state.sessions[0].completed); XCTAssertNotNil(state.retained["book"])
        state.finishPhotos([state.captures[1].id]); XCTAssertTrue(state.sessions[0].completed)
        var legacy=fixture(); legacy.sessions[0].completed=true; legacy.migratePhotoReviews()
        XCTAssertTrue(legacy.captures.allSatisfy{$0.reviewCompleted==true})
    }
    func testUnknownExcludesOnlyThisPhotoAndExplicitSelectionRestoresIt() {
        var state=fixture(); state.occurrences[0].selected=true; state.occurrences[1].selected=true
        let first=state.captures[0].id, second=state.captures[1].id
        state.classify("book",known:false,pageID:first)
        XCTAssertFalse(state.occurrences[0].selected); XCTAssertTrue(state.occurrences[1].selected)
        XCTAssertTrue(Recommender.ranked(state:state,captureIDs:[first]).isEmpty)
        XCTAssertEqual(Recommender.ranked(state:state,captureIDs:[second]).count,1)
        XCTAssertEqual(Recommender.ranked(state:state,captureIDs:[first],showAll:true).count,1)
        state.select("book",occurrenceID:state.occurrences[0].id,pages:[first],selected:true)
        XCTAssertEqual(Recommender.ranked(state:state,captureIDs:[first]).count,1)
        XCTAssertFalse(state.knowledge["book"]!.isKnown)
    }
    func testKnownClearsAllPendingSelectionsAndSurvivesReimport() {
        var state=fixture(); for i in state.occurrences.indices { state.occurrences[i].selected=true }
        state.classify("book",known:true,pageID:state.captures[0].id)
        XCTAssertTrue(state.occurrences.allSatisfy{!$0.selected})
        XCTAssertTrue(Recommender.ranked(state:state,captureIDs:Set(state.captures.map(\.id))).isEmpty)
        state.importKnown([state.lexemes["book"]!]); XCTAssertTrue(state.knowledge["book"]!.isKnown)
        state.select("book",occurrenceID:state.occurrences[0].id,pages:[state.captures[0].id],selected:true)
        XCTAssertTrue(state.knowledge["book"]!.isKnown)
        XCTAssertEqual(Recommender.ranked(state:state,captureIDs:[state.captures[0].id]).count,1)
    }
    func testVerticalHorizontalAndSkewGeometry() {
        var state=fixture(); var page=state.captures[0]
        let occurrence=state.occurrences[0]
        let vertical=TermGeometry.regions(page:page,occurrences:[occurrence])
        XCTAssertEqual(vertical.count,1); XCTAssertTrue(vertical[0].estimated)
        XCTAssertEqual(vertical[0].corners[2].y,0.2,accuracy:0.0001)
        page.layout="Horizontal"
        let horizontal=TermGeometry.regions(page:page,occurrences:[occurrence])
        XCTAssertEqual(horizontal[0].corners[1].x,0.7+0.1/6,accuracy:0.0001)
        let quad=[ImagePoint(x:0.1,y:0.1),ImagePoint(x:0.9,y:0.2),ImagePoint(x:0.8,y:0.8),ImagePoint(x:0,y:0.7)]
        page.recognition!.lines[0].elements=[TextElementGeometry(text:"本",start:0,end:1,corners:quad)]
        let measured=TermGeometry.regions(page:page,occurrences:[occurrence])
        XCTAssertFalse(measured[0].estimated); XCTAssertEqual(measured[0].corners,quad)
        state.captures[0]=page
    }
    func testRepeatedAndMulticolumnOccurrencesKeepSeparateIdentity() {
        var page=fixture().captures[0]
        page.recognition=Recognition(engine:"saved",lines:[TextLine(text:"本を",region:Region(x:0.8,y:0.1,width:0.1,height:0.5)),TextLine(text:"読む。本",region:Region(x:0.6,y:0.1,width:0.1,height:0.5))],elapsed:0)
        let spanning=Occurrence(captureID:page.id,lexemeID:"phrase",surface:"を読",start:1,end:3,sentence:page.text,fragment:true)
        let repeated=Occurrence(captureID:page.id,lexemeID:"book",surface:"本",start:5,end:6,sentence:page.text,fragment:true)
        let regions=TermGeometry.regions(page:page,occurrences:[spanning,repeated])
        XCTAssertEqual(regions.filter{$0.occurrenceID==spanning.id}.count,2)
        XCTAssertEqual(regions.filter{$0.occurrenceID==repeated.id}.count,1)
        page.correctedText="完全に違う文章"
        XCTAssertTrue(TermGeometry.regions(page:page,occurrences:[spanning]).isEmpty)
    }
    func testNeighborMergeAndGraphemeCuts() throws {
        let page=fixture().captures[0]
        let a=Occurrence(captureID:page.id,lexemeID:"a",surface:"本",start:0,end:1,sentence:page.text,fragment:true)
        let b=Occurrence(captureID:page.id,lexemeID:"b",surface:"を",start:1,end:2,sentence:page.text,fragment:true)
        let c=Occurrence(captureID:page.id,lexemeID:"c",surface:"読んだ",start:2,end:5,sentence:page.text,fragment:true)
        XCTAssertEqual(try ParseGesture.mergeRange(a,b,in:[a,b,c]),0..<2)
        XCTAssertThrowsError(try ParseGesture.mergeRange(a,c,in:[a,b,c]))
        XCTAssertEqual(ParseGesture.segments("か\u{3099}くせい",cuts:[1,2]),["か\u{3099}","く","せい"])
        XCTAssertEqual(ParseGesture.segments("𠮷野",cuts:[1]),["𠮷","野"])
    }
    func testExampleExpansionPreservesDraftAndRetainedExample() throws {
        var state=fixture(); let id=state.captures[0].id
        state.captures[0].correctedText="朝だった。本を読んだ。夜になった。"
        state.occurrences[0].start=5; state.occurrences[0].end=6; state.occurrences[0].sentence="本を読んだ。"
        var context=ExampleContext(page:state.captures[0],occurrence:state.occurrences[0])
        context.draft="本を読んだ（手修正）。"; context.prepend(from:state.captures[0].text); context.append(from:state.captures[0].text)
        XCTAssertEqual(context.draft,"朝だった。本を読んだ（手修正）。夜になった。")
        try state.saveExample(occurrenceID:state.occurrences[0].id,text:context.draft,start:context.start,end:context.end)
        state.occurrences[0].selected=true; state.finishPhotos([id])
        let frozen=state.retained["book"]!.example
        try state.saveExample(occurrenceID:state.occurrences[0].id,text:"別の本。",start:nil,end:nil)
        XCTAssertEqual(state.retained["book"]!.example,frozen)
        XCTAssertThrowsError(try state.saveExample(occurrenceID:state.occurrences[0].id,text:"対象なし",start:nil,end:nil))
        context.replaceRange(5..<11,from:state.captures[0].text); XCTAssertEqual(context.draft,"本を読んだ。")
    }
}

extension PhotoReviewTests {
    func testHoldDragCancellationAndDropArbitration() throws {
        let a=Occurrence(captureID:"page",lexemeID:"a",surface:"本",start:0,end:1,sentence:"本を読む",fragment:true)
        let b=Occurrence(captureID:"page",lexemeID:"b",surface:"を",start:1,end:2,sentence:"本を読む",fragment:true)
        let c=Occurrence(captureID:"page",lexemeID:"c",surface:"読む",start:2,end:4,sentence:"本を読む",fragment:true)
        var drag=TermDragSession()
        drag.update(distance:20,candidate:b.id) // Ordinary pan never began a term hold.
        XCTAssertEqual(drag.end(),.cancelled)
        drag.begin(a.id,occurrences:[a,b,c]); XCTAssertEqual(drag.end(),.split(a.id))
        drag.begin(a.id,occurrences:[a,b,c]); drag.update(distance:30,candidate:b.id)
        XCTAssertEqual(drag.end(),.merge(a.id,b.id))
        drag.begin(a.id,occurrences:[a,b,c]); drag.update(distance:30,candidate:c.id)
        XCTAssertEqual(drag.end(),.cancelled)
        drag.begin(a.id,occurrences:[a,b,c]); drag.update(distance:30,candidate:b.id); drag.cancel() // Pinch/system cancellation.
        XCTAssertEqual(drag.end(),.cancelled)
        drag.begin(a.id,occurrences:[a,b,c]); drag.update(distance:30,candidate:b.id); drag.update(distance:40,candidate:nil)
        XCTAssertEqual(drag.end(),.cancelled)
    }
    func testSavedRecognitionCanProduceRegionsWithoutOCR() throws {
        struct Report:Decodable { var runs:[Run] }
        struct Run:Decodable { var recognition:Recognition?; var layout:String }
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url=root.appendingPathComponent("Benchmark/private/iphone-benchmark-report.json")
        guard FileManager.default.fileExists(atPath:url.path) else { throw XCTSkip("Private saved report is not part of source distribution") }
        let report=try JSONDecoder().decode(Report.self,from:Data(contentsOf:url))
        var checked=0
        for run in report.runs {
            guard let recognition=run.recognition else { continue }
            var page=PageCapture(sessionID:"fixture",imagePath:"unused",fingerprint:"saved")
            page.recognition=recognition; page.layout=run.layout
            var cursor=0, occurrences:[Occurrence]=[]
            for line in recognition.lines where !line.isRuby {
                let count=line.text.unicodeScalars.count
                if count>0 { occurrences.append(Occurrence(captureID:page.id,lexemeID:UUID().uuidString,surface:JapaneseText.slice(line.text,0,min(3,count)),start:cursor,end:cursor+min(3,count),sentence:line.text,fragment:true)) }
                cursor += count
            }
            let regions=TermGeometry.regions(page:page,occurrences:occurrences)
            XCTAssertEqual(Set(regions.map(\.occurrenceID)),Set(occurrences.map(\.id)))
            XCTAssertTrue(regions.allSatisfy{$0.corners.count==4 && $0.corners.allSatisfy{$0.x.isFinite && $0.y.isFinite}})
            checked += regions.count
        }
        XCTAssertGreaterThan(checked,100)
    }
    func testClippedExampleExpansionKeepsSourceRange() {
        var page=PageCapture(sessionID:"s",imagePath:"p",fingerprint:"p")
        page.correctedText="前の部分で本を読んでいた後ろの部分。次の文。"
        let occurrence=Occurrence(captureID:page.id,lexemeID:"book",surface:"本",start:5,end:6,sentence:"本を読んでいた",fragment:true)
        var context=ExampleContext(page:page,occurrence:occurrence)
        XCTAssertEqual(context.start,5)
        context.append(from:page.text)
        XCTAssertEqual(context.draft,"本を読んでいた後ろの部分。")
    }
    func testPageTextEditRebasesManualExampleWithoutReplacingDraft() throws {
        var state=fixture(); let id=state.captures[0].id
        try state.saveExample(occurrenceID:state.occurrences[0].id,text:"本を読んだ（手修正）。",start:0,end:6)
        try state.editText(captureID:id,text:"朝。本を読んだ。")
        XCTAssertEqual(state.occurrences[0].start,2)
        XCTAssertEqual(state.occurrences[0].exampleStart,2)
        XCTAssertEqual(state.occurrences[0].exampleEnd,8)
        XCTAssertEqual(state.occurrences[0].sentence,"本を読んだ（手修正）。")
        XCTAssertThrowsError(try state.editText(captureID:id,text:"朝。別の文章。"))
    }
    func testRotatedSDKCornersKeepDelimitersTransverseToText() {
        let box=TermGeometry.rectangle(Region(x:0.2,y:0.1,width:0.1,height:0.8))
        for offset in 0..<4 {
            let rotated=(0..<4).map { box[($0+offset)%4] }
            for corners in [rotated,Array(rotated.reversed())] {
                let vertical=TermRegion(id:"v",occurrenceID:"o",corners:TermGeometry.slice(corners,from:0,to:0.5,vertical:true),estimated:true,vertical:true)
                let bar=TermGeometry.separator(vertical)
                XCTAssertEqual(bar[0].y,bar[1].y,accuracy:0.00001)
                XCTAssertEqual(bar[0].y,0.5,accuracy:0.00001)
                let horizontal=TermRegion(id:"h",occurrenceID:"o",corners:TermGeometry.slice(corners,from:0,to:0.5,vertical:false),estimated:true,vertical:false)
                let divider=TermGeometry.separator(horizontal)
                XCTAssertEqual(divider[0].x,divider[1].x,accuracy:0.00001)
                XCTAssertEqual(divider[0].x,0.25,accuracy:0.00001)
            }
        }
    }
    func testFilteredComponentsRemainMappedAndMergeIntoOneProposal() throws {
        var state=fixture(); let id=state.captures[0].id
        state.captures[0].recognition=Recognition(engine:"fixture",lines:[TextLine(text:"私立",region:Region(x:0.2,y:0.1,width:0.1,height:0.6))],elapsed:0)
        let a=Lexeme(id:"self",expression:"私",reading:"わたし",commonness:1,dictionaryID:"1")
        let b=Lexeme(id:"stand",expression:"立",reading:"りつ",commonness:1,dictionaryID:"2")
        state.lexemes[a.id]=a; state.lexemes[b.id]=b; state.basicWords.formUnion(["私","立"])
        let first=Occurrence(captureID:id,lexemeID:a.id,surface:"私",start:0,end:1,sentence:"私立",fragment:true)
        let second=Occurrence(captureID:id,lexemeID:b.id,surface:"立",start:1,end:2,sentence:"私立",fragment:true)
        state.occurrences=[first,second]
        XCTAssertTrue(Recommender.ranked(state:state,captureIDs:[id]).isEmpty)
        XCTAssertEqual(TermGeometry.regions(page:state.captures[0],occurrences:state.occurrences).count,2)
        let range=try ParseGesture.mergeRange(first,second,in:state.occurrences)
        let compound=Lexeme(id:"private",expression:"私立",reading:"しりつ",commonness:1,dictionaryID:"3")
        try state.replaceSegments(captureID:id,start:range.lowerBound,end:range.upperBound,surfaces:["私立"],words:[compound])
        XCTAssertEqual(Recommender.ranked(state:state,captureIDs:[id]).map(\.id),[compound.id])
        XCTAssertEqual(state.occurrences.map(\.surface),["私立"])
    }
}
