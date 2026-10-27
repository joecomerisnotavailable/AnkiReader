// Isolated simulator host for the production views. Recognition is deliberately unavailable.
import SwiftUI
import UIKit

enum PageLayout:String,CaseIterable,Identifiable { case vertical="Vertical",horizontal="Horizontal"; var id:String {rawValue} }
final class SudachiAnalyzer:MorphologicalAnalyzer {
    init(directory:URL) throws { if !ProcessInfo.processInfo.arguments.contains("--corrections-enabled") { throw StorageError.database("Tokenization disabled in UI fixture") } }
    // Deterministic UI-only tokenizer, not a Sudachi accuracy test.
    func tokenize(_ text:String) throws -> [MorphToken] {
        var result:[MorphToken]=[],offset=0
        while offset<text.unicodeScalars.count {
            let remaining=JapaneseText.slice(text,offset,text.unicodeScalars.count)
            let surface=["元日","悔恨","なだめる"].first{remaining.hasPrefix($0)} ?? String(remaining.first!)
            result.append(MorphToken(surface:surface,lemma:surface,reading:"",partOfSpeech:"名詞",start:offset,end:offset+surface.unicodeScalars.count,unknown:false));offset += surface.unicodeScalars.count
        }
        return result
    }
}
final class GoogleRecognizer {
    func recognize(_ image:UIImage,layout:PageLayout) throws -> Recognition { throw StorageError.database("OCR disabled in UI fixture") }
}
struct BenchmarkArchiveView:View { var body:some View { Text("Benchmark execution is disabled in this fixture app.") } }
extension UIImage {
    func normalized()->UIImage {
        let format=UIGraphicsImageRendererFormat(); format.scale=1
        return UIGraphicsImageRenderer(size:size,format:format).image { _ in draw(in:CGRect(origin:.zero,size:size)) }
    }
}
private struct SavedPage:Decodable { var recognition:Recognition; var vocabulary:[Lexeme]; var layout:String }
@main struct PhotoPreviewApp:App {
    @StateObject private var model=PhotoPreviewApp.fixture()
    var body:some Scene {
        WindowGroup {
                ReaderHome().environmentObject(model)
                    .environment(\.dynamicTypeSize,ProcessInfo.processInfo.arguments.contains("--large-text") ? .accessibility2 : .large)
        }
    }
    @MainActor static func fixture()->ReaderModel {
        let model=ReaderModel()
        do {
            let record=try JSONDecoder().decode(SavedPage.self,from:Data(contentsOf:Bundle.main.url(forResource:"fixture",withExtension:"json")!))
            let image=try Data(contentsOf:Bundle.main.url(forResource:"page",withExtension:"jpg")!)
            try image.write(to:model.root.appendingPathComponent("images/fixture.jpg"),options:.atomic)
            var state=LibraryState(); let session=state.session(source:"Saved page · UI fixture")
            var page=PageCapture(sessionID:session,imagePath:"images/fixture.jpg",fingerprint:"fixture")
            page.recognition=record.recognition; page.status = .ready; page.layout=record.layout; page.reviewCompleted=false
            state.captures=[page]
            let text=page.text; var occupied=Set<Int>()
            for word in record.vocabulary.filter({$0.dictionaryID != nil && !$0.expression.isEmpty}).sorted(by:{$0.expression.count>$1.expression.count}) {
                var cursor=text.startIndex
                while cursor<text.endIndex,let range=text.range(of:word.expression,range:cursor..<text.endIndex) {
                    let a=text[..<range.lowerBound].unicodeScalars.count,b=text[..<range.upperBound].unicodeScalars.count
                    if occupied.isDisjoint(with:a..<b) {
                        occupied.formUnion(a..<b); state.lexemes[word.id]=word
                        let example=JapaneseText.example(text:text,start:a,end:b)
                        state.occurrences.append(Occurrence(captureID:page.id,lexemeID:word.id,surface:String(text[range]),start:a,end:b,sentence:example.0,fragment:example.1))
                    }
                    cursor=range.upperBound
                }
            }
            // Keep filtered punctuation/particles in the parse so neighbor gestures exercise hidden terms.
            for i in 0..<text.unicodeScalars.count where !occupied.contains(i) {
                let surface=JapaneseText.slice(text,i,i+1),id="gap:\(i)"
                state.lexemes[id]=Lexeme(id:id,expression:surface,partOfSpeech:"補助記号")
                state.occurrences.append(Occurrence(captureID:page.id,lexemeID:id,surface:surface,start:i,end:i+1,sentence:surface,fragment:true))
            }
            if ProcessInfo.processInfo.arguments.contains("--gesture-fixture") {
                let phantom=ProcessInfo.processInfo.arguments.contains("--phantom-fixture")
                page.recognition=Recognition(engine:"synthetic gesture fixture",lines:[TextLine(text:phantom ? "ながにめる。" : "ながめる。",region:Region(x:0.45,y:0.15,width:0.15,height:0.65))],elapsed:0)
                state.captures=[page];state.occurrences=[];state.lexemes=[:]
                let tokens=phantom ? [("なが",0,2),("に",2,3),("め",3,4),("る",4,5),("。",5,6)] : [("なが",0,2),("め",2,3),("る",3,4),("。",4,5)]
                for (surface,start,end) in tokens {
                    state.lexemes[surface]=Lexeme(id:surface,expression:surface,definitions:["gesture fixture"])
                    state.occurrences.append(Occurrence(captureID:page.id,lexemeID:surface,surface:surface,start:start,end:end,sentence:page.text,fragment:false))
                }
                let original=state.occurrences
                var corrected=original[0];corrected.surface="なだ";corrected.lexemeID="なだ";corrected.sentence="なだめる。";corrected.corrected=true
                let proposal=CorrectionPreview(pageID:page.id,revision:0,originalPage:page,originalText:page.text,originalOccurrences:original,start:0,end:2,replacement:"なだ",method:.typing,window:0..<2,occurrences:[corrected],lexemes:[Lexeme(id:"なだ",expression:"なだ",definitions:["corrected fixture"])],manualBoundaries:false)
                try state.applyCorrection(proposal)
                state.basicWords.insert("に")
                if ProcessInfo.processInfo.arguments.contains("--pitch-fixture"),let first=state.occurrences.first {
                    state.lexemes[first.lexemeID]=Lexeme(id:first.lexemeID,expression:"食べる",reading:"たべる",definitions:["to eat"])
                    state.occurrences[0].selected=true
                }
                model.update{$0=state};model.openPhoto(page.id);return model
            }
            var second=page; second.id="second-fixture-page"; state.captures.append(second)
            if ProcessInfo.processInfo.arguments.contains("--retained") {
                if let item=Recommender.ranked(state:state,captureIDs:[page.id]).first {
                    state.select(item.id,occurrenceID:item.occurrence.id,pages:[page.id],selected:true); state.finishPhotos([page.id])
                }
                model.update{$0=state}; model.selectedTab=2
            } else if ProcessInfo.processInfo.arguments.contains("--final-review") {
                let candidates=Recommender.ranked(state:state,captureIDs:[page.id])
                if candidates.count>=3 {
                    state.select(candidates[0].id,occurrenceID:candidates[0].occurrence.id,pages:[page.id],selected:true)
                    state.classify(candidates[1].id,known:true,pageID:page.id)
                    state.classify(candidates[2].id,known:false,pageID:page.id)
                }
                model.update{$0=state}; model.openFinalReview(page.id)
            } else { model.update{$0=state}; model.openPhoto(page.id) }
        } catch { model.error=error.localizedDescription }
        return model
    }
}
