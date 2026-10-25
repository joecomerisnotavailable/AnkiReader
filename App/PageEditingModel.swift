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
    @discardableResult func editPage(_ id:String,command:PageEditCommand) async -> Bool {
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
                    guard state.lexemes[target.lexemeID]?.dictionaryID == nil else { return true }
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
            UIImpactFeedbackGenerator(style:.light).impactOccurred();return true
        } catch { self.error=error.localizedDescription;return false }
    }
    func undoPageEdit(_ id:String) {
        guard !editingParse,var stack=pageEditHistory[id],let undo=stack.last else { return }
        if update({ s in
            guard let i=s.captures.firstIndex(where:{$0.id==id}) else { return }
            let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
            guard try encoder.encode(s.captures[i])==encoder.encode(undo.after),try encoder.encode(s.occurrences.filter{$0.captureID==id})==encoder.encode(undo.afterOccurrences) else { throw StorageError.invalidArchive("Review decisions or page data changed after this edit; they will not be overwritten by Undo.") }
            let revision=(s.captures[i].textRevision ?? 0)+1
            s.captures[i]=undo.before;s.captures[i].textRevision=revision
            s.occurrences.removeAll{$0.captureID==id};s.occurrences += undo.occurrences
        }) {
            stack.removeLast()
            if !stack.isEmpty { stack[stack.count-1].after=state.captures.first{$0.id==id}! }
            pageEditHistory[id]=stack
        }
    }
    func openPageEditor(_ occurrence:Occurrence) {
        pendingPageEditorID=occurrence.id
        openPhoto(occurrence.captureID,fromFinalReview:selectedTab==1)
    }
}
