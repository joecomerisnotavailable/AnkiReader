// Isolated simulator host for the production views. Recognition is deliberately unavailable.
import SwiftUI
import UIKit

enum PageLayout:String,CaseIterable,Identifiable { case vertical="Vertical",horizontal="Horizontal"; var id:String {rawValue} }
final class SudachiAnalyzer:MorphologicalAnalyzer {
    init(directory:URL) throws { throw StorageError.database("OCR/tokenization disabled in UI fixture") }
    func tokenize(_ text:String) throws -> [MorphToken] { throw StorageError.database("Disabled in UI fixture") }
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
