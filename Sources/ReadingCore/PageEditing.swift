import Foundation

public enum PageEditCommand: Sendable {
    case replace(String, String, CorrectionMethod)
    case join(Range<Int>)
    case shatter(String)
}
public struct SavedExample: Codable, Hashable, Sendable {
    public var text:String
    public var sourceOccurrenceID:String
    public init(text:String,sourceOccurrenceID:String) { self.text=text;self.sourceOccurrenceID=sourceOccurrenceID }
}
extension Occurrence {
    public var needsExampleRepair:Bool { manualExample == true && !sentence.contains(surface) }
    public var preservedExamples:[SavedExample] {
        var result=exampleAlternatives ?? []
        if manualExample == true {
            let current=SavedExample(text:sentence,sourceOccurrenceID:id)
            if !result.contains(where:{$0.text==sentence}) { result.insert(current,at:0) }
        }
        return result
    }
}
public enum PageEditing {
    public static func segments(page:PageCapture,occurrences:[Occurrence],command:PageEditCommand) throws -> (Range<Int>,[String]) {
        let all=occurrences.filter{$0.captureID==page.id}.sorted{$0.start<$1.start}
        switch command {
        case .replace: throw StorageError.invalidArchive("Text replacements require source mapping.")
        case .shatter(let id):
            guard let item=all.first(where:{$0.id==id}),item.surface.count>1 else { throw StorageError.invalidArchive("Choose a term with more than one character.") }
            return (item.start..<item.end,item.surface.map(String.init))
        case .join(let selected):
            let scalarCount=page.text.unicodeScalars.count
            let boundaries=Set(([0]+page.text.map{String($0).unicodeScalars.count}).reduce(into:[Int]()) { values,n in values.append((values.last ?? 0)+n) })
            guard selected.lowerBound>=0,selected.upperBound<=scalarCount,!selected.isEmpty,
                  boundaries.contains(selected.lowerBound),boundaries.contains(selected.upperBound) else { throw StorageError.invalidArchive("Place both cursors between characters.") }
            let covered=all.filter{$0.start<selected.upperBound && $0.end>selected.lowerBound}
            let start=min(selected.lowerBound,covered.map(\.start).min() ?? selected.lowerBound)
            let end=max(selected.upperBound,covered.map(\.end).max() ?? selected.upperBound)
            let pieces=[JapaneseText.slice(page.text,start,selected.lowerBound),JapaneseText.slice(page.text,selected.lowerBound,selected.upperBound),JapaneseText.slice(page.text,selected.upperBound,end)].filter{!$0.isEmpty}
            return (start..<end,pieces)
        }
    }
}
extension LibraryState {
    /// Make all literal text editable, including whitespace omitted by morphology.
    public mutating func materializePageGaps(_ pageID:String) {
        guard let p=captures.first(where:{$0.id==pageID}),p.status == .ready else { return }
        let sorted=occurrences.filter{$0.captureID==pageID}.sorted{$0.start<$1.start}
        var offset=0
        for item in sorted {
            if item.start>offset { addPageGap(p,start:offset,end:item.start) }
            offset=max(offset,item.end)
        }
        if offset<p.text.unicodeScalars.count { addPageGap(p,start:offset,end:p.text.unicodeScalars.count) }
    }
    private mutating func addPageGap(_ page:PageCapture,start:Int,end:Int) {
        let text=JapaneseText.slice(page.text,start,end),id="gap:\(page.id):\(start):\(end)"
        lexemes[id]=Lexeme(id:id,expression:text,partOfSpeech:text.allSatisfy(\.isWhitespace) ? "空白" : "補助記号")
        let example=JapaneseText.example(text:page.text,start:start,end:end)
        var item=Occurrence(captureID:page.id,lexemeID:id,surface:text,start:start,end:end,sentence:example.0,fragment:example.1)
        item.id=id;occurrences.append(item)
    }
    public mutating func reconcilePageDecisions(_ id:String) {
        guard let i=captures.firstIndex(where:{$0.id==id}) else { return }
        let items=occurrences.filter{$0.captureID==id},ids=Set(items.map(\.lexemeID))
        captures[i].reviewMarks=captures[i].reviewMarks?.filter{ids.contains($0.key)}
        captures[i].excludedLexemeIDs=captures[i].excludedLexemeIDs?.intersection(ids)
        for item in items where item.selected {
            captures[i].reviewMarks = captures[i].reviewMarks ?? [:]
            captures[i].reviewMarks?[item.lexemeID] = .selected
            captures[i].excludedLexemeIDs?.remove(item.lexemeID)
        }
    }
}

public enum DraftInsertion {
    /// UIKit selections use UTF-16; reject invalid/half-surrogate ranges.
    public static func apply(_ replacement:String,to draft:String,selection:NSRange)->(text:String,cursor:NSRange)? {
        guard let range=Range(selection,in:draft) else { return nil }
        var result=draft;result.replaceSubrange(range,with:replacement)
        return (result,NSRange(location:selection.location+replacement.utf16.count,length:0))
    }
}

/// A proposed boundary, not a committed change to page text or review decisions.
public struct ParsingSuggestion:Equatable,Identifiable,Sendable {
    public var start:Int
    public var end:Int
    public var surface:String
    public var revision:Int
    public var anchor:Int
    public var id:String { "\(start):\(end):\(surface)" }
    public init(start:Int,end:Int,surface:String,revision:Int,anchor:Int) {
        self.start=start;self.end=end;self.surface=surface;self.revision=revision;self.anchor=anchor
    }
    public static func changedTerms(_ proposed:[Occurrence],page:PageCapture,current:[Occurrence],anchor:Int)->[ParsingSuggestion] {
        proposed.filter { candidate in
            !candidate.surface.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty &&
            !current.contains{$0.start==candidate.start && $0.end==candidate.end} &&
            !candidate.surface.unicodeScalars.contains{ "。！？!?".unicodeScalars.contains($0) }
        }.map{ParsingSuggestion(start:$0.start,end:$0.end,surface:$0.surface,revision:page.textRevision ?? 0,anchor:anchor)}
        .filter{!(page.dismissedParsingSuggestions?.contains($0.id) ?? false)}
    }
}
