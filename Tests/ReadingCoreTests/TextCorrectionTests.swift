import XCTest
@testable import ReadingCore

final class TextCorrectionTests:XCTestCase {
    func fixture()->LibraryState {
        var s=LibraryState();let session=s.session(source:"Book")
        var p=PageCapture(sessionID:session,imagePath:"page.jpg",fingerprint:"p");p.status = .ready
        p.recognition=Recognition(engine:"saved",lines:[TextLine(text:"無恨。無恨。",region:Region(x:0.6,y:0.1,width:0.1,height:0.6))],elapsed:0)
        s.captures=[p]
        for (i,c) in p.text.enumerated() { let word=String(c);s.lexemes[word]=Lexeme(id:word,expression:word,definitions:["test"]);s.occurrences.append(Occurrence(captureID:p.id,lexemeID:word,surface:word,start:i,end:i+1,sentence:p.text,fragment:false)) }
        return s
    }
    func proposal(_ s:LibraryState,start:Int=0,end:Int=1,replacement:String="悔")->CorrectionPreview {
        let p=s.captures[0],old=s.occurrences.first{$0.start==start}!
        let text=JapaneseText.slice(p.text,0,start)+replacement+JapaneseText.slice(p.text,end,p.text.unicodeScalars.count)
        var item=Occurrence(captureID:p.id,lexemeID:replacement,surface:replacement,start:start,end:start+replacement.unicodeScalars.count,sentence:text,fragment:false)
        item.corrected=true;item.selected=old.selected
        return CorrectionPreview(pageID:p.id,revision:p.textRevision ?? 0,originalPage:p,originalText:p.text,originalOccurrences:s.occurrences,start:start,end:end,replacement:replacement,method:.typing,window:start..<end,occurrences:replacement.isEmpty ? [] : [item],lexemes:[Lexeme(id:replacement,expression:replacement)],manualBoundaries:false)
    }
    func testCorrectionUpdatesTextGeometryGridAndKeepsOtherOccurrence() throws {
        var s=fixture();let old=s.occurrences[0]
        let geometry=TermGeometry.regions(page:s.captures[0],occurrences:[old]).first!.corners
        try s.applyCorrection(proposal(s))
        XCTAssertEqual(s.captures[0].text,"悔恨。無恨。")
        let corrected=s.occurrences.first{$0.start==0}!
        XCTAssertEqual(TermGeometry.regions(page:s.captures[0],occurrences:[corrected]).first!.corners,geometry)
        XCTAssertEqual(TextGridLayout.make(page:s.captures[0],occurrences:s.occurrences).glyphs.map(\.text).joined(),s.captures[0].text)
        XCTAssertEqual(s.occurrences.first{$0.start==3}?.surface,"無")
        XCTAssertEqual(CorrectionMapping.history(corrected,page:s.captures[0]).first?.before,"無")
        XCTAssertTrue(CorrectionMapping.history(s.occurrences.first{$0.start==3}!,page:s.captures[0]).isEmpty)
    }
    func testMergeSplitAndRetainedSnapshot() throws {
        var s=fixture();s.occurrences[0].selected=true
        try s.applyCorrection(proposal(s));let id=s.captures[0].id
        try s.replaceSegments(captureID:id,start:0,end:2,surfaces:["悔恨"],words:[Lexeme(id:"regret",expression:"悔恨")])
        let merged=s.occurrences.first{$0.start==0}!
        XCTAssertTrue(merged.selected);XCTAssertEqual(CorrectionMapping.history(merged,page:s.captures[0]).count,1)
        s.finishPhotos([id]);let snapshot=try JSONEncoder().encode(s.retained["regret"])
        XCTAssertEqual(s.retained["regret"]?.corrections?.first?.after,"悔")
        try s.replaceSegments(captureID:id,start:0,end:2,surfaces:["悔","恨"],words:[Lexeme(id:"悔",expression:"悔"),Lexeme(id:"恨",expression:"恨")])
        XCTAssertTrue(CorrectionMapping.history(s.occurrences.first{$0.start==1}!,page:s.captures[0]).isEmpty)
        try s.applyCorrection(proposal(s,replacement:"海"))
        let decoded=try JSONDecoder().decode(RetainedWord?.self,from:snapshot)
        XCTAssertEqual(s.retained["regret"]?.example,decoded?.example)
        XCTAssertEqual(s.retained["regret"]?.corrections,decoded?.corrections)
    }
    func testLengthChangesRebaseAndRepeatedCorrectionsKeepSource() throws {
        var s=fixture();try s.applyCorrection(proposal(s,replacement:"後悔"))
        XCTAssertEqual(s.occurrences.first{$0.surface=="恨"}?.start,2)
        XCTAssertEqual(CorrectionMapping.source(s.captures[0],start:0,end:2),SourceSpan(0,1))
        try s.applyCorrection(proposal(s,start:0,end:2,replacement:"無"))
        XCTAssertEqual(s.captures[0].text,"無恨。無恨。")
        XCTAssertEqual(CorrectionMapping.source(s.captures[0],start:0,end:1),SourceSpan(0,1))
        XCTAssertEqual(s.captures[0].corrections?.count,2)
        XCTAssertEqual(s.occurrences.first{$0.start==3}?.surface,"無")
    }
    func testStalePreviewAndInvalidManualExampleAreAtomic() throws {
        var s=fixture();let p=proposal(s)
        s.occurrences[0].selected=true
        XCTAssertThrowsError(try s.applyCorrection(p));XCTAssertEqual(s.captures[0].text,"無恨。無恨。")
        var invalid=proposal(s);invalid.occurrences[0].manualExample=true;invalid.occurrences[0].sentence="無恨。"
        XCTAssertThrowsError(try s.applyCorrection(invalid));XCTAssertNil(s.captures[0].sourceMap)
        invalid.occurrences[0].sentence="悔恨。";try s.applyCorrection(invalid)
        XCTAssertEqual(s.occurrences.first{$0.start==0}?.sentence,"悔恨。")
    }
    func testKnowledgeNotTransferredAndSelectionsPersist() throws {
        var s=fixture();s.knowledge["無"]=Knowledge(override:true);s.occurrences[0].selected=true
        s.captures[0].reviewMarks=["無":.known];s.captures[0].excludedLexemeIDs=["無"]
        try s.applyCorrection(proposal(s))
        XCTAssertNil(s.knowledge["悔"]);XCTAssertTrue(s.knowledge["無"]!.isKnown)
        XCTAssertEqual(s.captures[0].reviewMarks?["悔"],.selected)
        XCTAssertEqual(s.captures[0].reviewMarks?["無"],.known) // another original occurrence remains
    }
    func testBackupAndLegacyDecoding() throws {
        var s=fixture();s.captures[0].photoRemoved=true;try s.applyCorrection(proposal(s))
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let archive=root.appendingPathComponent("backup.zip")
        try LibraryBackup.create(state:s,root:root,destination:archive)
        let restored=try LibraryBackup.stageRestore(archive:archive,root:root)
        XCTAssertEqual(restored.captures[0].sourceMap,s.captures[0].sourceMap)
        XCTAssertEqual(restored.captures[0].corrections,s.captures[0].corrections)
        let old=fixture();let decoded=try JSONDecoder().decode(LibraryState.self,from:JSONEncoder().encode(old))
        XCTAssertNil(decoded.captures[0].corrections)
    }
    func testCorrectedNadameruCanMergeInEitherDirection() throws {
        for reverse in [false,true] {
            var s=fixture();var p=s.captures[0]
            p.recognition=Recognition(engine:"saved",lines:[TextLine(text:"ながめる。",region:Region(x:0.5,y:0.1,width:0.1,height:0.7))],elapsed:0);s.captures=[p]
            s.occurrences=[]
            for (surface,start,end) in [("なが",0,2),("め",2,3),("る",3,4),("。",4,5)] {
                s.occurrences.append(Occurrence(captureID:p.id,lexemeID:surface,surface:surface,start:start,end:end,sentence:p.text,fragment:false))
            }
            try s.applyCorrection(proposal(s,start:0,end:2,replacement:"なだ"))
            var a=s.occurrences.first{$0.surface=="なだ"}!,b=s.occurrences.first{$0.surface=="め"}!
            XCTAssertEqual(TermGeometry.regions(page:s.captures[0],occurrences:[a,b]).count,2)
            var drag=TermDragSession();drag.begin(reverse ? b.id : a.id,occurrences:s.occurrences)
            drag.update(distance:40,candidate:reverse ? a.id : b.id)
            XCTAssertEqual(drag.end(),.merge(reverse ? b.id : a.id,reverse ? a.id : b.id))
            let range=try ParseGesture.mergeRange(a,b,in:s.occurrences)
            try s.replaceSegments(captureID:p.id,start:range.lowerBound,end:range.upperBound,surfaces:["なだめ"],words:[Lexeme(id:"なだめ",expression:"なだめ")])
            a=s.occurrences.first{$0.surface=="なだめ"}!;b=s.occurrences.first{$0.surface=="る"}!
            let final=try ParseGesture.mergeRange(a,b,in:s.occurrences)
            try s.replaceSegments(captureID:p.id,start:final.lowerBound,end:final.upperBound,surfaces:["なだめる"],words:[Lexeme(id:"なだめる",expression:"なだめる")])
            let merged=s.occurrences.first{$0.surface=="なだめる"}!
            XCTAssertEqual(CorrectionMapping.history(merged,page:s.captures[0]).map(\.before),["が"])
            XCTAssertEqual(CorrectionMapping.history(merged,page:s.captures[0]).map(\.after),["だ"])
            XCTAssertEqual(CorrectionMapping.source(s.captures[0],start:merged.start,end:merged.end),SourceSpan(0,4))
        }
    }
    func testRemoveSpuriousCharacterThenMergeCorrectedWord() throws {
        var s=fixture();var p=s.captures[0]
        p.recognition=Recognition(engine:"saved",lines:[TextLine(text:"ながにめる。",region:Region(x:0.5,y:0.1,width:0.1,height:0.7))],elapsed:0);s.captures=[p]
        s.occurrences=[]
        for (surface,start,end) in [("なが",0,2),("に",2,3),("め",3,4),("る",4,5),("。",5,6)] {
            s.occurrences.append(Occurrence(captureID:p.id,lexemeID:surface,surface:surface,start:start,end:end,sentence:p.text,fragment:false))
        }
        try s.applyCorrection(proposal(s,start:0,end:2,replacement:"なだ"))
        let a=s.occurrences.first{$0.surface=="なだ"}!,b=s.occurrences.first{$0.surface=="め"}!
        XCTAssertThrowsError(try ParseGesture.mergeRange(a,b,in:s.occurrences))
        let geometry=TermGeometry.regions(page:s.captures[0],occurrences:[b]).first!.corners
        try s.applyCorrection(proposal(s,start:2,end:3,replacement:""))
        XCTAssertEqual(s.captures[0].text,"なだめる。")
        let shifted=s.occurrences.first{$0.surface=="め"}!
        XCTAssertEqual(shifted.start,2)
        XCTAssertEqual(TermGeometry.regions(page:s.captures[0],occurrences:[shifted]).first!.corners,geometry)
        XCTAssertEqual(CorrectionMapping.source(s.captures[0],start:2,end:3),SourceSpan(3,4))
        _ = try ParseGesture.mergeRange(a,shifted,in:s.occurrences)
        try s.replaceSegments(captureID:p.id,start:0,end:4,surfaces:["なだめる"],words:[Lexeme(id:"なだめる",expression:"なだめる")])
        let merged=s.occurrences.first{$0.surface=="なだめる"}!
        XCTAssertEqual(CorrectionMapping.history(merged,page:s.captures[0]).map(\.before),["が","に"])
        XCTAssertEqual(CorrectionMapping.history(merged,page:s.captures[0]).map(\.after),["だ",""])
        XCTAssertEqual(TextGridLayout.make(page:s.captures[0],occurrences:s.occurrences).glyphs.map(\.text).joined(),"なだめる。")
    }
    func testContextRadiusUsesCharactersAndParseWindowPreservesWholeTokens() {
        let text="前👩‍💻なだにめる。後"
        let start="前👩‍💻".unicodeScalars.count
        let target=Occurrence(captureID:"p",lexemeID:"なだ",surface:"なだ",start:start,end:start+2,sentence:text,fragment:false)
        let range=CorrectionContext.visibleRange(text:text,target:target,radius:1)
        XCTAssertEqual(JapaneseText.slice(text,range.lowerBound,range.upperBound),"👩‍💻なだに")
        let neighbor=Occurrence(captureID:"p",lexemeID:"にめ",surface:"にめ",start:start+2,end:start+4,sentence:text,fragment:false)
        let parse=CorrectionContext.parseRange(visible:range,target:target,all:[target,neighbor])
        XCTAssertEqual(parse.upperBound,neighbor.end)
        XCTAssertEqual(CorrectionContext.visibleRange(text:text,target:target,radius:0),target.start..<target.end)
    }
    func testContextCandidateMapping() {
        XCTAssertEqual(CorrectionCandidates.replacement(candidate:"悔恨の",context:"無恨の",start:0,end:1),"悔")
        XCTAssertNil(CorrectionCandidates.replacement(candidate:"悔根の",context:"無恨の",start:0,end:1))
        XCTAssertNil(CorrectionCandidates.replacement(candidate:"",context:"無",start:0,end:1))
        XCTAssertEqual(CorrectionCandidates.replacement(candidate:"悔",context:"無",start:0,end:1),"悔")
    }
}
