import Foundation

struct CorrectionUndo {
    var page:PageCapture
    var before:[Occurrence]
    var after:Data
    var afterPage:Data
    var revision:Int
}
extension ReadingWorker {
    func correctionPreview(page:PageCapture,all:[Occurrence],target:Occurrence,replacement:String,method:CorrectionMethod,keepBoundaries:Bool,contextWindow:Range<Int>? = nil) async throws -> CorrectionPreview {
        let window=contextWindow ?? CorrectionMapping.window(target,in:all,text:page.text)
        let text=JapaneseText.slice(page.text,0,target.start)+replacement+JapaneseText.slice(page.text,target.end,page.text.unicodeScalars.count)
        let delta=replacement.unicodeScalars.count-(target.end-target.start)
        let old=all.filter{$0.captureID==page.id && $0.start<window.upperBound && $0.end>window.lowerBound}.sorted{$0.start<$1.start}
        var items:[Occurrence],words:[Lexeme]
        if keepBoundaries {
            let kept=old.filter{$0.id != target.id || !replacement.isEmpty}
            let surfaces=kept.map{$0.id==target.id ? replacement : JapaneseText.slice(page.text,$0.start,$0.end)}
            words=try await resolveExpressions(surfaces)
            items=zip(kept,zip(surfaces,words)).map { previous,pair in
                let (surface,word)=pair
                let start=previous.start+(previous.start>=target.end ? delta : 0)
                return Occurrence(captureID:page.id,lexemeID:word.id,surface:surface,start:start,end:start+surface.unicodeScalars.count,sentence:"",fragment:false)
            }
        } else {
            let parsed=try await analyzeCorrection(JapaneseText.slice(text,window.lowerBound,window.upperBound+delta),captureID:page.id)
            words=parsed.lexemes;items=parsed.occurrences
            for i in items.indices { items[i].start += window.lowerBound;items[i].end += window.lowerBound }
        }
        for i in items.indices {
            let example=JapaneseText.example(text:text,start:items[i].start,end:items[i].end)
            items[i].sentence=example.0;items[i].fragment=example.1;items[i].corrected=true
            func range(_ o:Occurrence)->Range<Int> {
                if o.id==target.id { return o.start..<(o.end+delta) }
                return o.start>=target.end ? (o.start+delta)..<(o.end+delta) : o.start..<o.end
            }
            let overlapping=old.filter{range($0).overlaps(items[i].start..<items[i].end)}
            items[i].selected=overlapping.contains(where:\.selected)
            items[i].lineIDs=Array(Set(overlapping.flatMap(\.lineIDs)))
            if let manual=overlapping.first(where:{$0.manualExample==true}) {
                items[i].sentence=manual.sentence;items[i].manualExample=true
            }
            if let unchanged=overlapping.first(where:{range($0)==items[i].start..<items[i].end && $0.surface==items[i].surface}) {
                items[i].id=unchanged.id;items[i].lexemeID=unchanged.lexemeID
                items[i].corrected=unchanged.corrected
            }
        }
        // Keep original dictionaries for unaffected explicit choices in the window.
        return CorrectionPreview(pageID:page.id,revision:page.textRevision ?? 0,originalPage:page,originalText:page.text,originalOccurrences:all.filter{$0.captureID==page.id},start:target.start,end:target.end,replacement:replacement,method:method,window:window,occurrences:items,lexemes:words,manualBoundaries:old.contains(where:\.corrected))
    }
}
extension ReaderModel {
    func previewCorrection(_ target:Occurrence,replacement:String,method:CorrectionMethod,keepBoundaries:Bool,contextWindow:Range<Int>? = nil) async throws -> CorrectionPreview {
        guard let page=state.captures.first(where:{$0.id==target.captureID}),state.occurrences.contains(where:{$0.id==target.id && $0.start==target.start && $0.end==target.end && $0.surface==target.surface}) else { throw StorageError.invalidArchive("Photo unavailable") }
        return try await worker.correctionPreview(page:page,all:state.occurrences,target:target,replacement:replacement,method:method,keepBoundaries:keepBoundaries,contextWindow:contextWindow)
    }
    @discardableResult func applyCorrection(_ preview:CorrectionPreview)->Bool {
        guard let page=state.captures.first(where:{$0.id==preview.pageID}) else { return false }
        let before=state.occurrences.filter{$0.captureID==page.id}
        if update({try $0.applyCorrection(preview)}) {
            let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
            correctionUndo=CorrectionUndo(page:page,before:before,after:(try? encoder.encode(state.occurrences.filter{$0.captureID==page.id})) ?? Data(),afterPage:(try? encoder.encode(state.captures.first{$0.id==page.id}!)) ?? Data(),revision:preview.revision+1)
            parseUndo=nil
            return true
        }
        return false
    }
    func undoCorrection() {
        guard let undo=correctionUndo else { return }
        if update({ s in
            let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
            guard let i=s.captures.firstIndex(where:{$0.id==undo.page.id}),s.captures[i].textRevision==undo.revision,
                  try encoder.encode(s.occurrences.filter{$0.captureID==undo.page.id})==undo.after,try encoder.encode(s.captures[i])==undo.afterPage else { throw StorageError.invalidArchive("This photo changed after the correction. Undo its later edits first.") }
            s.captures[i]=undo.page;s.occurrences.removeAll{$0.captureID==undo.page.id};s.occurrences += undo.before
        }) { correctionUndo=nil }
    }
}
