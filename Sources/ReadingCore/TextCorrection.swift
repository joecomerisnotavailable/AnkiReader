import Foundation

/// Scalar range in immutable OCR. -1 denotes a legacy edit without a safe mapping.
public struct SourceSpan:Codable,Hashable,Sendable {
    public var start:Int
    public var end:Int
    public init(_ start:Int,_ end:Int) { self.start=start; self.end=end }
}
public enum CorrectionMethod:String,Codable,Sendable { case typing, photo, handwriting }
public struct TextCorrection:Codable,Identifiable,Hashable,Sendable {
    public var id=UUID().uuidString
    public var before:String
    public var after:String
    public var method:CorrectionMethod
    public var source:SourceSpan
    public var start:Int
    public var end:Int
    public var revision:Int
}
public struct CorrectionPreview:Sendable {
    public var pageID:String
    public var revision:Int
    public var originalPage:PageCapture
    public var originalText:String
    public var originalOccurrences:[Occurrence]
    public var start:Int
    public var end:Int
    public var replacement:String
    public var method:CorrectionMethod
    public var window:Range<Int>
    public var occurrences:[Occurrence]
    public var lexemes:[Lexeme]
    public var manualBoundaries:Bool
    public var text:String { JapaneseText.slice(originalText,0,start)+replacement+JapaneseText.slice(originalText,end,originalText.unicodeScalars.count) }
}
public enum CorrectionMapping {
    public static func cells(_ page:PageCapture)->[SourceSpan] {
        if let map=page.sourceMap,map.count==page.text.unicodeScalars.count { return map }
        let original=Array((page.recognition?.text ?? "").unicodeScalars), edited=Array(page.text.unicodeScalars)
        if original==edited { return original.indices.map{SourceSpan($0,$0+1)} }
        // Keep only unchanged aligned scalars for legacy page edits. Never guess
        // geometry for replacements whose source history was not recorded.
        let diff=edited.difference(from:original)
        var deleted=Set<Int>(),inserted=Set<Int>()
        for change in diff { switch change { case .remove(let i,_,_):deleted.insert(i); case .insert(let i,_,_):inserted.insert(i) } }
        var result=[SourceSpan](repeating:SourceSpan(-1,-1),count:edited.count),j=0
        for i in original.indices where !deleted.contains(i) {
            while j<edited.count && inserted.contains(j) { j += 1 }
            if j<edited.count { result[j]=SourceSpan(i,i+1); j += 1 }
        }
        return result
    }
    public static func rebasePageEdit(_ page:PageCapture,to text:String)->([SourceSpan],[TextCorrection]) {
        let old=Array(page.text.unicodeScalars),new=Array(text.unicodeScalars),map=cells(page)
        var deleted=Set<Int>(),inserted=Set<Int>()
        for change in new.difference(from:old) { switch change { case .remove(let i,_,_):deleted.insert(i);case .insert(let i,_,_):inserted.insert(i) } }
        var result=[SourceSpan](repeating:SourceSpan(-1,-1),count:new.count),positions=[Int:Int](),j=0
        for i in old.indices where !deleted.contains(i) {
            while j<new.count && inserted.contains(j) { j += 1 }
            if j<new.count { result[j]=map[i];positions[i]=j;j += 1 }
        }
        var history=page.corrections ?? []
        for i in history.indices {
            let anchors=(history[i].start..<history[i].end).compactMap{positions[$0]}
            history[i].start=anchors.min() ?? 0;history[i].end=anchors.max().map{$0+1} ?? 0
        }
        return (result,history)
    }
    public static func sourceRuns(_ page:PageCapture,start:Int,end:Int)->[SourceSpan] {
        let map=cells(page)
        guard start>=0,end>start,end<=map.count else { return [] }
        let spans=Array(map[start..<end]).sorted{$0.start<$1.start}
        guard spans.allSatisfy({$0.start>=0 && $0.end>$0.start}) else { return [] }
        var result:[SourceSpan]=[]
        for span in spans {
            if let last=result.last,last.end>=span.start { result[result.count-1].end=max(last.end,span.end) }
            else { result.append(span) }
        }
        return result
    }
    public static func source(_ page:PageCapture,start:Int,end:Int)->SourceSpan? {
        let map=cells(page)
        guard start>=0,end>start,end<=map.count else { return nil }
        let spans=Array(map[start..<end]); guard spans.allSatisfy({$0.start>=0}) else { return nil }
        return SourceSpan(spans.map(\.start).min()!,spans.map(\.end).max()!)
    }
    public static func history(_ occurrence:Occurrence,page:PageCapture)->[TextCorrection] {
        (page.corrections ?? []).filter { $0.start<occurrence.end && $0.end>occurrence.start }
    }
    public static func window(_ occurrence:Occurrence,in all:[Occurrence],text:String)->Range<Int> {
        let sorted=all.filter{$0.captureID==occurrence.captureID}.sorted{$0.start<$1.start}
        guard let i=sorted.firstIndex(where:{$0.id==occurrence.id}) else { return occurrence.start..<occurrence.end }
        func boundary(_ s:String)->Bool { s.contains{ "。！？!?\n".contains($0) } }
        let a=i>0 && !boundary(sorted[i-1].surface) ? sorted[i-1].start : occurrence.start
        let b=i+1<sorted.count && !boundary(sorted[i+1].surface) ? sorted[i+1].end : occurrence.end
        return a..<b
    }
}
extension LibraryState {
    public mutating func applyCorrection(_ preview:CorrectionPreview,requireValidExample:Bool = true) throws {
        guard let index=captures.firstIndex(where:{$0.id==preview.pageID}) else { throw StorageError.invalidArchive("Photo no longer exists.") }
        let page=captures[index], old=occurrences.filter{$0.captureID==page.id}
        let encoder=JSONEncoder();encoder.outputFormatting = .sortedKeys
        guard try encoder.encode(page)==encoder.encode(preview.originalPage), (page.textRevision ?? 0)==preview.revision,page.text==preview.originalText,
              try encoder.encode(old)==encoder.encode(preview.originalOccurrences) else { throw StorageError.invalidArchive("This page changed. Preview the correction again.") }
        guard preview.replacement != JapaneseText.slice(page.text,preview.start,preview.end),preview.start>=0,preview.end<=page.text.unicodeScalars.count,preview.start<preview.end else { throw StorageError.invalidArchive("Enter the text as printed.") }
        let delta=preview.replacement.unicodeScalars.count-(preview.end-preview.start)
        var map=CorrectionMapping.cells(page)
        let source=CorrectionMapping.source(page,start:preview.start,end:preview.end) ?? SourceSpan(-1,-1)
        let replaced=Array(map[preview.start..<preview.end])
        let newCells=preview.replacement.unicodeScalars.count==replaced.count ? replaced : Array(repeating:source,count:preview.replacement.unicodeScalars.count)
        map.replaceSubrange(preview.start..<preview.end,with:newCells)
        func shifted(_ range:SourceSpan)->SourceSpan {
            if range.end<=preview.start { return range }
            if range.start>=preview.end { return SourceSpan(range.start+delta,range.end+delta) }
            return SourceSpan(min(range.start,preview.start),max(preview.start+preview.replacement.unicodeScalars.count,range.end+delta))
        }
        var history=page.corrections ?? []
        for i in history.indices { let r=shifted(SourceSpan(history[i].start,history[i].end));history[i].start=r.start;history[i].end=r.end }
        // Record changed grapheme runs, not an unchanged surrounding word.
        let before=JapaneseText.slice(page.text,preview.start,preview.end)
        let a=Array(before),b=Array(preview.replacement)
        var prefix=0,suffix=0
        while prefix<min(a.count,b.count) && a[prefix]==b[prefix] { prefix += 1 }
        while suffix<min(a.count,b.count)-prefix && a[a.count-1-suffix]==b[b.count-1-suffix] { suffix += 1 }
        let first=preview.start+String(b.prefix(prefix)).unicodeScalars.count
        let last=preview.start+String(b.prefix(b.count-suffix)).unicodeScalars.count
        let oldFirst=preview.start+String(a.prefix(prefix)).unicodeScalars.count
        let oldLast=preview.start+String(a.prefix(a.count-suffix)).unicodeScalars.count
        let annotationSource=CorrectionMapping.source(page,start:oldFirst,end:oldLast) ?? source
        history.append(TextCorrection(before:String(a[prefix..<(a.count-suffix)]),after:String(b[prefix..<(b.count-suffix)]),method:preview.method,source:annotationSource,start:min(first,max(0,preview.text.unicodeScalars.count-1)),end:min(preview.text.unicodeScalars.count,max(first+1,last)),revision:preview.revision+1))
        var updated=old.filter{!($0.start<preview.window.upperBound && $0.end>preview.window.lowerBound)}
        for i in updated.indices {
            if updated[i].start>=preview.end { updated[i].start += delta;updated[i].end += delta }
            if updated[i].manualExample != true {
                let example=JapaneseText.example(text:preview.text,start:updated[i].start,end:updated[i].end)
                updated[i].sentence=example.0;updated[i].fragment=example.1
            }
            if let a=updated[i].exampleStart,let b=updated[i].exampleEnd { let r=shifted(SourceSpan(a,b));updated[i].exampleStart=r.start;updated[i].exampleEnd=r.end }
        }
        for item in preview.occurrences {
            guard !requireValidExample || item.sentence.contains(item.surface) else { throw StorageError.invalidArchive("Keep each corrected target in its example before applying.") }
        }
        updated += preview.occurrences
        occurrences.removeAll{$0.captureID==page.id};occurrences += updated
        for word in preview.lexemes { lexemes[word.id]=word }
        captures[index].correctedText=preview.text;captures[index].sourceMap=map
        captures[index].corrections=history;captures[index].textRevision=preview.revision+1
        let ids=Set(updated.map(\.lexemeID))
        captures[index].reviewMarks=page.reviewMarks?.filter{ids.contains($0.key)}
        captures[index].excludedLexemeIDs=page.excludedLexemeIDs?.intersection(ids)
        for item in preview.occurrences where item.selected {
            captures[index].reviewMarks = captures[index].reviewMarks ?? [:]
            captures[index].reviewMarks?[item.lexemeID] = .selected
            captures[index].excludedLexemeIDs?.remove(item.lexemeID)
        }
    }
}

/// Display context expands by visible characters; reparsing includes complete
/// intersecting tokens so no existing boundary outside the preview is truncated.
public enum CorrectionContext {
    public static func visibleRange(text:String,target:Occurrence,radius:Int)->Range<Int> {
        var offsets=[0]
        for character in text { offsets.append(offsets.last!+String(character).unicodeScalars.count) }
        let first=offsets.lastIndex(where:{$0<=target.start}) ?? 0
        let last=offsets.firstIndex(where:{$0>=target.end}) ?? offsets.count-1
        return offsets[max(0,first-max(0,radius))]..<offsets[min(offsets.count-1,last+max(0,radius))]
    }
    public static func parseRange(visible:Range<Int>,target:Occurrence,all:[Occurrence])->Range<Int> {
        let tokens=all.filter{$0.captureID==target.captureID && $0.start<visible.upperBound && $0.end>visible.lowerBound}
        return min(target.start,tokens.map(\.start).min() ?? visible.lowerBound)..<max(target.end,tokens.map(\.end).max() ?? visible.upperBound)
    }
}
