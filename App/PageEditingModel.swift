import Foundation
import UIKit

struct PageEditUndo {
    var before:PageCapture
    var occurrences:[Occurrence]
    var after:PageCapture
    var afterOccurrences:[Occurrence]
}
extension ReaderModel {
    func preparePageEditing(_ id:String) {
        let count=state.occurrences.count
        var copy=state;copy.materializePageGaps(id)
        if copy.occurrences.count != count { update{$0=copy} }
    }
    @discardableResult func editPage(_ id:String,command:PageEditCommand,suggest:Bool=true) async -> Bool {
        guard !editingParse,let page=state.captures.first(where:{$0.id==id}),page.status == .ready else { return false }
        editingParse=true;defer { editingParse=false }
        let old=state.occurrences.filter{$0.captureID==id}
        do {
            let preview:CorrectionPreview?,segments:(Range<Int>,[String])?,words:[Lexeme]
            switch command {
            case .replace(let occurrenceID,let text,let method):
                guard let target=old.first(where:{$0.id==occurrenceID}) else { throw StorageError.invalidArchive("This term changed. Select it again.") }
                if target.surface==text {
                    // Keep can retry a previously unresolved term after resolver improvements.
                    // This changes lexical identity only: no fabricated OCR correction record.
                    words=try await worker.resolveExpressions([text])
                    guard words.first?.dictionaryID != nil else { return true }
                    segments=(target.start..<target.end,[text]);preview=nil
                } else {
                    preview=try await worker.correctionPreview(page:page,all:old,target:target,replacement:text,method:method,keepBoundaries:true,contextWindow:target.start..<target.end)
                    segments=nil;words=[]
                }
            default:
                let value=try PageEditing.segments(page:page,occurrences:old,command:command)
                segments=value;words=try await worker.resolveExpressions(value.1);preview=nil
            }
            let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
            guard let current=state.captures.first(where:{$0.id==id}),try encoder.encode(current)==encoder.encode(page),try encoder.encode(state.occurrences.filter{$0.captureID==id})==encoder.encode(old) else { throw StorageError.invalidArchive("This page changed during the edit. Try again.") }
            guard update({ s in
                if let preview { try s.applyCorrection(preview,requireValidExample:false) }
                if let segments {
                    try s.replaceSegments(captureID:id,start:segments.0.lowerBound,end:segments.0.upperBound,surfaces:segments.1,words:words)
                    let i=s.captures.firstIndex{$0.id==id}!
                    s.captures[i].textRevision=(page.textRevision ?? 0)+1
                }
                s.reconcilePageDecisions(id)
            }) else { return false }
            lastPageEditStart[id]=preview?.start ?? segments?.0.lowerBound ?? 0
            var stack=pageEditHistory[id] ?? []
            stack.append(PageEditUndo(before:page,occurrences:old,after:state.captures.first{$0.id==id}!,afterOccurrences:state.occurrences.filter{$0.captureID==id}))
            pageEditHistory[id]=Array(stack.suffix(20));parseUndo=nil;correctionUndo=nil
            parsingSuggestions[id]=[]
            if suggest { Task { await self.suggestParsing(id,anchor:self.lastPageEditStart[id] ?? 0) } }
            UIImpactFeedbackGenerator(style:.light).impactOccurred();return true
        } catch { self.error=error.localizedDescription;return false }
    }
    func undoPageEdit(_ id:String) {
        guard !editingParse,var stack=pageEditHistory[id],let undo=stack.last else { return }
        if update({ s in
            guard let i=s.captures.firstIndex(where:{$0.id==id}) else { return }
            let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
            var comparable=s.captures[i]
            let dismissed=comparable.dismissedParsingSuggestions
            comparable.dismissedParsingSuggestions=undo.after.dismissedParsingSuggestions
            guard try encoder.encode(comparable)==encoder.encode(undo.after),try encoder.encode(s.occurrences.filter{$0.captureID==id})==encoder.encode(undo.afterOccurrences) else { throw StorageError.invalidArchive("Review decisions or page data changed after this edit; they will not be overwritten by Undo.") }
            let revision=(s.captures[i].textRevision ?? 0)+1
            s.captures[i]=undo.before;s.captures[i].textRevision=revision;s.captures[i].dismissedParsingSuggestions=dismissed
            s.occurrences.removeAll{$0.captureID==id};s.occurrences += undo.occurrences
        }) {
            stack.removeLast()
            if !stack.isEmpty { stack[stack.count-1].after=state.captures.first{$0.id==id}! }
            pageEditHistory[id]=stack;parsingSuggestions[id]=[]
        }
    }
    func repairPageOrder(_ id:String) {
        guard !editingParse,let before=state.captures.first(where:{$0.id==id}) else { return }
        let old=state.occurrences.filter{$0.captureID==id}
        do {
            var next=state
            guard try next.repairReadingOrder(id) else { return }
            if update({$0=next}) {
                var stack=pageEditHistory[id] ?? []
                stack.append(PageEditUndo(before:before,occurrences:old,after:next.captures.first{$0.id==id}!,afterOccurrences:next.occurrences.filter{$0.captureID==id}))
                pageEditHistory[id]=Array(stack.suffix(20));parsingSuggestions[id]=[]
            }
        } catch { self.error=error.localizedDescription }
    }
    func refineSavedCapture(_ id:String,occurrenceID:String? = nil) async {
        guard !editingParse,state.canRefineCapture(id),let before=state.captures.first(where:{$0.id==id}) else { return }
        editingParse=true;defer {editingParse=false}
        let old=state.occurrences.filter{$0.captureID==id}
        do {
            let preferences=state.rememberedExpressions.compactMapValues{state.lexemes[$0]}
            let focused=old.first(where:{$0.id==occurrenceID})
            let lines=(before.recognition?.lines ?? []).filter{!$0.isRuby}
            var lineStart=0,lineID:String?,fraction:Double?
            for line in lines {
                let end=lineStart+line.text.unicodeScalars.count
                if let focused,focused.start>=lineStart,focused.start<end {
                    lineID=line.id
                    fraction=Double(JapaneseText.slice(line.text,0,focused.start-lineStart).count)/Double(max(1,line.text.count))
                    break
                }
                lineStart=end
            }
            let refined=try await worker.refineSaved(before,url:imageURL(before),preferences:preferences,preferredLineID:lineID,preferredLineFraction:fraction)
            guard refined.recognition.lines != before.recognition?.lines else { return }
            let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
            guard let current=state.captures.first(where:{$0.id==id}),try encoder.encode(current)==encoder.encode(before),
                  try encoder.encode(state.occurrences.filter{$0.captureID==id})==encoder.encode(old) else {
                throw StorageError.invalidArchive("This page changed during refinement. No result was applied.")
            }
            if update({try $0.applyRefinement(refined,captureID:id)}) {
                // The screen follows this offset after textRevision changes.
                // Use the same insertion mapping as the transactional save.
                let original=Array(before.text.unicodeScalars),updated=Array(refined.recognition.text.unicodeScalars)
                let inserted=Set(updated.difference(from:original).compactMap { change -> Int? in
                    if case .insert(let offset,_,_)=change { return offset };return nil
                })
                let positions=updated.indices.filter{!inserted.contains($0)}
                let offset=focused?.start ?? 0
                lastPageEditStart[id]=positions.indices.contains(offset) ? positions[offset] : 0
                var stack=pageEditHistory[id] ?? []
                stack.append(PageEditUndo(before:before,occurrences:old,after:state.captures.first{$0.id==id}!,afterOccurrences:state.occurrences.filter{$0.captureID==id}))
                pageEditHistory[id]=Array(stack.suffix(20));parsingSuggestions[id]=[]
            }
        } catch {self.error=error.localizedDescription}
    }
    func openPageEditor(_ occurrence:Occurrence) {
        pendingPageEditorID=occurrence.id
        openPhoto(occurrence.captureID,fromFinalReview:selectedTab==1)
    }
}

extension ReaderModel {
    func suggestParsing(_ id:String,anchor:Int) async {
        guard let page=state.captures.first(where:{$0.id==id}) else { return }
        let all=state.occurrences.filter{$0.captureID==id}.sorted{$0.start<$1.start}
        guard let index=all.firstIndex(where:{$0.end>anchor}) ?? all.indices.last else { return }
        var a=index,b=index
        func punctuation(_ o:Occurrence)->Bool { o.surface.contains{ "。！？!?".contains($0) } }
        while a>0 && index-a<2 && !punctuation(all[a-1]) { a-=1 }
        while b+1<all.count && b-index<2 && !punctuation(all[b+1]) { b+=1 }
        let start=all[a].start,end=all[b].end
        do {
            let parsed=try await worker.analyzeCorrection(JapaneseText.slice(page.text,start,end),captureID:id)
            var proposed=parsed.occurrences
            for i in proposed.indices { proposed[i].start += start;proposed[i].end += start }
            // Also offer an inflected word spanning several grammatical tokens.
            let tokens=proposed
            for i in tokens.indices where tokens.count-i>=2 {
                for length in 2...min(4,tokens.count-i) where i+length<=tokens.count {
                    let range=tokens[i].start..<tokens[i+length-1].end
                    guard range.contains(anchor),!all.contains(where:{$0.start==range.lowerBound && $0.end==range.upperBound}) else { continue }
                    let text=JapaneseText.slice(page.text,range.lowerBound,range.upperBound)
                    let words=try await worker.resolveExpressions([text])
                    if let word=words.first,word.dictionaryID != nil {
                        proposed.append(Occurrence(captureID:id,lexemeID:word.id,surface:text,start:range.lowerBound,end:range.upperBound,sentence:"",fragment:false))
                    }
                }
            }
            guard let current=state.captures.first(where:{$0.id==id}),current.textRevision==page.textRevision else { return }
            parsingSuggestions[id]=ParsingSuggestion.changedTerms(proposed,page:current,current:all,anchor:anchor)
        } catch { /* Suggestions are optional; an edit has already been saved safely. */ }
    }
    func acceptParsing(_ suggestion:ParsingSuggestion,pageID:String) async {
        guard (state.captures.first(where:{$0.id==pageID})?.textRevision ?? 0) == suggestion.revision else { return }
        _=await editPage(pageID,command:.join(suggestion.start..<suggestion.end),suggest:false)
    }
    func dismissParsing(_ suggestion:ParsingSuggestion,pageID:String) {
        if update({ state in
            guard let i=state.captures.firstIndex(where:{$0.id==pageID}) else { return }
            state.captures[i].dismissedParsingSuggestions=state.captures[i].dismissedParsingSuggestions ?? []
            state.captures[i].dismissedParsingSuggestions?.insert(suggestion.id)
        }) { parsingSuggestions[pageID]?.removeAll{$0.id==suggestion.id} }
    }
}
