import Foundation

/// Reconcile a short, physically bounded retry with one existing OCR line. No
/// dictionary or language-model prediction participates in this decision.
public enum RecognitionRefinement {
    public struct Chunk: Sendable {
        public var text: String
        public var from: Double
        public var to: Double
        public var cells: [[ImagePoint]]
        public var estimatedCellCount: Double
        public var clearBoundaries: [Bool]?
        public init(text:String,from:Double,to:Double,cells:[[ImagePoint]],estimatedCellCount:Double,clearBoundaries:[Bool]? = nil) {
            self.text=text;self.from=from;self.to=to;self.cells=cells;self.estimatedCellCount=estimatedCellCount;self.clearBoundaries=clearBoundaries
        }
    }
    private struct Match {
        var start: Int
        var end: Int
        var chunk: Chunk
    }
    public static func refine(line:TextLine,chunks:[Chunk],vertical:Bool) -> TextLine {
        let raw=Array(line.text)
        var offsets=[0]
        for char in raw { offsets.append(offsets.last!+String(char).unicodeScalars.count) }
        let compact=raw.indices.filter{!raw[$0].isWhitespace}
        var matches=[Match]()
        for chunk in chunks {
            let text=Array(chunk.text)
            guard text.count>=4,text.count<=12,chunk.cells.count==text.count,chunk.cells.allSatisfy({$0.count==4}),
                  abs(Double(text.count)-chunk.estimatedCellCount)<=0.7,
                  text.allSatisfy({$0.unicodeScalars.allSatisfy{$0.value>=0x3000}}) else { continue }
            var possible=[(Int,Int,Int)]()
            for length in max(4,text.count-2)...text.count where length<=compact.count {
                guard Double(length)/Double(text.count)>=0.75 else { continue }
                for start in 0...(compact.count-length) {
                    let source=compact[start..<(start+length)].map{raw[$0]}
                    guard source.prefix(2)==text.prefix(2),source.suffix(2)==text.suffix(2) else { continue }
                    // Count possible alignments, rather than picking a greedy
                    // alignment of repeated characters around a missing glyph.
                    func ways(_ a:Int,_ b:Int)->Int {
                        if a==source.count { return b==text.count ? 1 : 0 }
                        if b==text.count || text.count-b<source.count-a { return 0 }
                        var n = source[a]==text[b] ? ways(a+1,b+1) : 0
                        if b>=2 && b<text.count-2 && text.count-b>source.count-a { n += ways(a,b+1) }
                        return min(2,n)
                    }
                    if ways(0,0)==1 { possible.append((compact[start],compact[start+length-1]+1,length)) }
                }
            }
            guard let longest=possible.map({$0.2}).max() else { continue }
            let best=possible.filter{$0.2==longest}
            guard best.count==1 else { continue }
            let (a,b,_)=best[0]
            guard !raw[a..<b].contains(where:{$0.isWhitespace}) else { continue }
            // Uniqueness alone does not justify moving text across a column.
            let center=Double(a+b)/Double(max(1,raw.count)*2)
            guard abs(center-(chunk.from+chunk.to)/2)<0.13 else { continue }
            matches.append(Match(start:offsets[a],end:offsets[b],chunk:chunk))
        }
        matches=matches.enumerated().filter { i,a in !matches.enumerated().contains { j,b in
            i != j && a.start<b.end && a.end>b.start
        }}.map(\.element).sorted{$0.start<$1.start}
        guard !matches.isEmpty else { return line }
        var base=line.elements ?? []
        // Freeze all original fallback spans before text length changes. A later
        // insertion must not change the denominator of an untouched line slice.
        var covered=Set<Int>()
        for element in base { covered.formUnion(element.start..<element.end) }
        var missing=0
        while missing<line.text.unicodeScalars.count {
            if covered.contains(missing) { missing += 1;continue }
            let start=missing
            while missing<line.text.unicodeScalars.count && !covered.contains(missing) { missing += 1 }
            let from=Double(JapaneseText.slice(line.text,0,start).count)/Double(max(1,line.text.count))
            let to=Double(JapaneseText.slice(line.text,0,missing).count)/Double(max(1,line.text.count))
            base.append(TextElementGeometry(text:JapaneseText.slice(line.text,start,missing),start:start,end:missing,corners:TermGeometry.slice(line.corners ?? TermGeometry.rectangle(line.region),from:from,to:to,vertical:vertical),estimated:true))
        }
        var result=line, output="", elements=[TextElementGeometry](), cursor=0
        func appendOriginal(_ start:Int,_ end:Int) {
            guard end>start else { return }
            let delta=output.unicodeScalars.count-start
            output += JapaneseText.slice(line.text,start,end)
            for element in base where element.start<end && element.end>start {
                let a=max(start,element.start),b=min(end,element.end)
                let total=max(1,JapaneseText.slice(line.text,element.start,element.end).count)
                let from=Double(JapaneseText.slice(line.text,element.start,a).count)/Double(total)
                let to=Double(JapaneseText.slice(line.text,element.start,b).count)/Double(total)
                elements.append(TextElementGeometry(text:JapaneseText.slice(line.text,a,b),start:a+delta,end:b+delta,corners:TermGeometry.slice(element.corners,from:from,to:to,vertical:vertical),estimated:element.estimated ?? (a != element.start || b != element.end),refinedGaps:element.refinedGaps))
            }
        }
        for match in matches {
            appendOriginal(cursor,match.start)
            for (i,pair) in zip(match.chunk.text,match.chunk.cells).enumerated() {
                let (character,quad)=pair
                let start=output.unicodeScalars.count
                output.append(character)
                let clear=match.chunk.clearBoundaries ?? []
                let gaps=clear.count==match.chunk.cells.count+1 ? [clear[i],clear[i+1]] : [false,false]
                elements.append(TextElementGeometry(text:String(character),start:start,end:output.unicodeScalars.count,corners:quad,estimated:true,refinedGaps:gaps))
            }
            cursor=match.end
        }
        appendOriginal(cursor,line.text.unicodeScalars.count)
        result.text=output;result.elements=elements
        return result
    }
}
