import XCTest
@testable import ReadingCore

final class ExpressionLookupTests:XCTestCase {
    private struct Analyzer:MorphologicalAnalyzer {
        var tokens:[MorphToken]
        func tokenize(_ text:String) throws -> [MorphToken] { tokens }
    }
    private func tokens(_ parts:[(String,String,String)]) -> Analyzer {
        var offset=0
        return Analyzer(tokens:parts.map { surface,lemma,pos in
            defer { offset += surface.unicodeScalars.count }
            return MorphToken(surface:surface,lemma:lemma,reading:"",partOfSpeech:pos,start:offset,end:offset+surface.unicodeScalars.count,unknown:false)
        })
    }
    private func withDictionary(_ run:(DictionaryIndex)throws->Void) throws {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".sqlite")
        defer { try? FileManager.default.removeItem(at:url) }
        do {
            let db=try Database(url:url)
            try db.execute("PRAGMA journal_mode=DELETE; CREATE TABLE entries(id TEXT,expression TEXT,reading TEXT,definitions TEXT,commonness REAL,pos TEXT); CREATE TABLE forms(form TEXT,entry_id TEXT);")
            for (word,reading) in [("貼る","はる"),("泣く","なく"),("高い","たかい"),("猫","ねこ"),("貼ってある","はってある")] {
                try db.execute("INSERT INTO entries VALUES(?,?,?,'[\"definition\"]',0.5,'')",values:["dict:"+word,word,reading])
                try db.execute("INSERT INTO forms VALUES(?,?)",values:[word,"dict:"+word])
            }
        }
        try run(DictionaryIndex(url:url))
    }
    func testInflectionalEndingsResolveWithoutChangingSurface() throws {
        // Morphological splits verified against the bundled Sudachi engine/core dictionary.
        try withDictionary { dictionary in
            for (stem,lemma,ending,pos) in [("貼っ","貼る","て","助詞,接続助詞"),("貼っ","貼る","た","助動詞"),("貼り","貼る","ます","助動詞"),("貼ら","貼る","ない","助動詞"),("泣い","泣く","て","助詞,接続助詞"),("高かっ","高い","た","助動詞")] {
                let analyzer=tokens([(stem,lemma,lemma=="高い" ? "形容詞,一般" : "動詞,一般"),(ending,ending,pos)])
                let word=try dictionary.resolveExpression(stem+ending,tokenizer:analyzer)
                XCTAssertEqual(word.id,"dict:"+lemma);XCTAssertFalse(word.definitions.isEmpty)
            }
        }
    }
    func testDoesNotResolveArbitraryJoinedPhrasesToFirstWord() throws {
        try withDictionary { dictionary in
            for parts in [[("貼る","貼る","動詞,一般"),("紙","紙","名詞,普通名詞")],[("猫","猫","名詞,普通名詞"),("に","に","助詞,格助詞")],[("貼る","貼る","動詞,一般"),("と","と","助詞,接続助詞")]] {
                let text=parts.map{$0.0}.joined()
                let word=try dictionary.resolveExpression(text,tokenizer:tokens(parts))
                XCTAssertNil(word.dictionaryID);XCTAssertEqual(word.expression,text)
            }
            var broken=tokens([("貼っ","貼る","動詞,一般"),("て","て","助詞,接続助詞")])
            broken.tokens[1].start=1
            XCTAssertNil(try dictionary.resolveExpression("貼って",tokenizer:broken).dictionaryID)
        }
    }
    func testExactExpressionStillWins() throws {
        try withDictionary { dictionary in
            let word=try dictionary.resolveExpression("貼ってある",tokenizer:tokens([]))
            XCTAssertEqual(word.expression,"貼ってある");XCTAssertNotNil(word.dictionaryID)
        }
    }
    func testBundledDictionaryResolvesHatteToHaru() throws {
        let url=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/dictionary.sqlite")
        guard FileManager.default.fileExists(atPath:url.path) else { throw XCTSkip("Bundled dictionary is a local build resource") }
        let dictionary=try DictionaryIndex(url:url)
        var analyzer=tokens([("貼っ","貼る","動詞,一般,*,*,五段-ラ行,連用形-促音便"),("て","て","助詞,接続助詞,*,*,*,*")])
        analyzer.tokens[0].reading="ハッ";analyzer.tokens[1].reading="テ"
        let result=try dictionary.resolveExpression("貼って",tokenizer:analyzer)
        XCTAssertEqual(result.id,try dictionary.lookup("貼る").first?.id)
        XCTAssertEqual(result.reading,"はる");XCTAssertFalse(result.definitions.isEmpty)
    }
    func testJoinedInflectionPreservesSelectionAndPhotoSpan() throws {
        try withDictionary { dictionary in
            var state=LibraryState();let session=state.session(source:"Novel")
            var page=PageCapture(sessionID:session,imagePath:"photo",fingerprint:"p")
            page.recognition=Recognition(engine:"saved",lines:[TextLine(text:"貼って",region:Region(x:0.1,y:0.1,width:0.1,height:0.6))],elapsed:0)
            state.captures=[page]
            for (i,text) in ["貼","っ","て"].enumerated() {
                var o=Occurrence(captureID:page.id,lexemeID:text,surface:text,start:i,end:i+1,sentence:"貼って",fragment:true)
                o.selected=i==0;state.occurrences.append(o)
            }
            let word=try dictionary.resolveExpression("貼って",tokenizer:tokens([("貼っ","貼る","動詞,一般"),("て","て","助詞,接続助詞")]))
            try state.replaceSegments(captureID:page.id,start:0,end:3,surfaces:["貼って"],words:[word])
            let joined=try XCTUnwrap(state.occurrences.first)
            XCTAssertEqual(joined.surface,"貼って");XCTAssertEqual(joined.lexemeID,"dict:貼る")
            XCTAssertTrue(joined.selected);XCTAssertEqual(joined.start,0);XCTAssertEqual(joined.end,3)
            XCTAssertFalse(TermGeometry.regions(page:page,occurrences:[joined]).isEmpty)
        }
    }
}
