import Foundation

extension LibraryState {
    /// Reorder effective scalar cells, never immutable OCR or guessed matching text.
    /// Refuse edits that would split a manually joined occurrence across columns.
    @discardableResult public mutating func repairReadingOrder(_ pageID:String) throws -> Bool {
        guard let index=captures.firstIndex(where:{$0.id==pageID}),let recognition=captures[index].recognition else { return false }
        let page=captures[index],lines=recognition.lines.filter{!$0.isRuby}
        let ordered=PageLayoutRepair.readingOrder(lines,vertical:page.layout != "Horizontal")
        let rank=Dictionary(uniqueKeysWithValues:ordered.enumerated().map{($0.element.id,$0.offset)})
        var originalColumns:[String]=[]
        for line in lines { originalColumns += Array(repeating:line.id,count:line.text.unicodeScalars.count) }
        let cells=CorrectionMapping.cells(page),scalars=Array(page.text.unicodeScalars)
        var keys:[Int]=[]
        for cell in cells {
            guard cell.start>=0,cell.end>cell.start,cell.end<=originalColumns.count,
                  originalColumns[cell.start..<cell.end].allSatisfy({$0==originalColumns[cell.start]}),let key=rank[originalColumns[cell.start]] else {
                throw StorageError.invalidArchive("Column order cannot be changed safely because an edited span has no unique source column.")
            }
            keys.append(key)
        }
        let permutation=scalars.indices.sorted { keys[$0]==keys[$1] ? $0<$1 : keys[$0]<keys[$1] }
        guard permutation != Array(scalars.indices) else { return false }
        let positions=Dictionary(uniqueKeysWithValues:permutation.enumerated().map{($0.element,$0.offset)})
        func moved(_ start:Int,_ end:Int)throws->Range<Int> {
            let values=(start..<end).compactMap{positions[$0]}
            guard let first=values.first,values.count==end-start,values==Array(first..<(first+values.count)) else {
                throw StorageError.invalidArchive("Column repair would separate an existing term or correction. Split that term before repairing column order.")
            }
            return first..<(first+values.count)
        }
        let text=String(String.UnicodeScalarView(permutation.map{scalars[$0]}))
        var items=occurrences.filter{$0.captureID==pageID}
        for i in items.indices {
            let range=try moved(items[i].start,items[i].end)
            items[i].start=range.lowerBound;items[i].end=range.upperBound
            if items[i].manualExample != true {
                let example=JapaneseText.example(text:text,start:items[i].start,end:items[i].end)
                items[i].sentence=example.0;items[i].fragment=example.1
            }
            if let a=items[i].exampleStart,let b=items[i].exampleEnd,let mapped=try? moved(a,b) { items[i].exampleStart=mapped.lowerBound;items[i].exampleEnd=mapped.upperBound }
            else { items[i].exampleStart=nil;items[i].exampleEnd=nil }
        }
        var history=page.corrections ?? []
        for i in history.indices {
            let range=try moved(history[i].start,history[i].end)
            history[i].start=range.lowerBound;history[i].end=range.upperBound
        }
        captures[index].correctedText=text;captures[index].sourceMap=permutation.map{cells[$0]}
        captures[index].corrections=history;captures[index].textRevision=(page.textRevision ?? 0)+1
        captures[index].dismissedParsingSuggestions=nil // old suggestions refer to old offsets
        occurrences.removeAll{$0.captureID==pageID};occurrences += items
        return true
    }
}
