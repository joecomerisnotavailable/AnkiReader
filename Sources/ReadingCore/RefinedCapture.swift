import Foundation

extension LibraryState {
    /// Saved-page text refinement is explicit and limited to machine text. Never
    /// replace manual boundaries, source maps, corrections, or example drafts.
    public func canRefineCapture(_ id:String)->Bool {
        guard let page=captures.first(where:{$0.id==id}),page.status == .ready,
              page.correctedText==nil,page.sourceMap==nil,(page.corrections ?? []).isEmpty else { return false }
        return !occurrences.contains{$0.captureID==id && ($0.corrected || $0.manualExample == true)}
    }
    public mutating func applyRefinement(_ analyzed:AnalyzedPage,captureID:String) throws {
        guard canRefineCapture(captureID),let index=captures.firstIndex(where:{$0.id==captureID}) else {
            throw StorageError.invalidArchive("This page has manual edits. They will not be replaced by recognition refinement.")
        }
        let page=captures[index],old=Array(page.text.unicodeScalars),new=Array(analyzed.recognition.text.unicodeScalars)
        var inserted=Set<Int>()
        for change in new.difference(from:old) {
            switch change {
            case .remove:throw StorageError.invalidArchive("The local retry disagrees with existing text. The page was left unchanged.")
            case .insert(let i,_,_):inserted.insert(i)
            }
        }
        let positions=new.indices.filter{!inserted.contains($0)}
        guard positions.count==old.count,zip(old,positions).allSatisfy({$0.0==new[$0.1]}) else {
            throw StorageError.invalidArchive("The refinement could not be mapped safely.")
        }
        let previous=occurrences.filter{$0.captureID==captureID}
        let mapped=previous.compactMap { item -> (Occurrence,Range<Int>)? in
            guard item.start>=0,item.end>item.start,item.end<=positions.count else { return nil }
            return (item,positions[item.start]..<(positions[item.end-1]+1))
        }
        var updated=analyzed.occurrences
        for i in updated.indices {
            let overlap=mapped.filter{$0.1.lowerBound<updated[i].end && $0.1.upperBound>updated[i].start}
            updated[i].selected=overlap.contains{$0.0.selected}
            if let identical=overlap.first(where:{$0.1.lowerBound==updated[i].start && $0.1.upperBound==updated[i].end && $0.0.lexemeID==updated[i].lexemeID && $0.0.surface==updated[i].surface}) { updated[i].id=identical.0.id }
        }
        occurrences.removeAll{$0.captureID==captureID};occurrences += updated
        for word in analyzed.lexemes { lexemes[word.id]=word }
        var recognition=analyzed.recognition
        recognition.rawLines=page.recognition?.rawLines ?? page.recognition?.lines
        captures[index].recognition=recognition
        captures[index].textRevision=(page.textRevision ?? 0)+1
        captures[index].processingVersion="mlkit-8.0.0-local-cells-1-sudachi-0.6.10-jmdict-v1"
        captures[index].dismissedParsingSuggestions=nil
        reconcilePageDecisions(captureID)
    }
}
