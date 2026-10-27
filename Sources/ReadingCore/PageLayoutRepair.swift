import Foundation

/// Layout-only repair; the engine's raw lines remain available on the capture.
public enum PageLayoutRepair {
    public static func ordered(_ input: [TextLine], vertical: Bool) -> [TextLine] {
        func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        func overlap(_ a: Region, _ b: Region) -> Double {
            let width = max(0, min(a.x+a.width, b.x+b.width)-max(a.x,b.x))
            let height = max(0, min(a.y+a.height, b.y+b.height)-max(a.y,b.y))
            return width*height / max(0.000001, min(a.width*a.height,b.width*b.height))
        }
        // Some engine results contain a whole column and its smaller sublines.
        // Suppress only a geometrically contained, text-identical repetition.
        let lines = input.enumerated().filter { i, line in
            let text = compact(line.text)
            return !input.enumerated().contains { j, other in
                let candidate = compact(other.text)
                return i != j && !text.isEmpty && candidate.contains(text) && overlap(line.region, other.region) > 0.85 &&
                    (candidate.count > text.count || (candidate.count == text.count && j < i))
            }
        }.map(\.element)
        let sizes = lines.map { vertical ? $0.region.width : $0.region.height }.sorted()
        let median = sizes.isEmpty ? 0 : sizes[sizes.count/2]
        var result = lines
        for i in result.indices {
            let line = result[i], size = vertical ? line.region.width : line.region.height
            let text = compact(line.text)
            let kanaOnly = !text.isEmpty && text.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) || (0x30a1...0x30fa).contains($0.value) || $0.value == 0x30fc }
            // Width alone misclassified complete body sentences in the saved iPhone run.
            result[i].isRuby = kanaOnly && text.count <= 12 && median > 0 && size < median*0.5 && lines.contains { other in
                guard other.id != line.id else { return false }
                if vertical {
                    return other.region.width >= median*0.85 && abs(line.region.x-(other.region.x+other.region.width)) < median*0.65 && line.region.y >= other.region.y-0.01 && line.region.y+line.region.height <= other.region.y+other.region.height+0.01
                }
                return other.region.height >= median*0.85 && abs(line.region.y+line.region.height-other.region.y) < median*0.65 && line.region.x >= other.region.x-0.01 && line.region.x+line.region.width <= other.region.x+other.region.width+0.01
            }
        }
        return readingOrder(result,vertical:vertical)
    }
    /// Compare column centerlines at the same page height. Axis-aligned boxes
    /// grow wider with skew and must not determine column membership or order.
    public static func readingOrder(_ lines:[TextLine],vertical:Bool)->[TextLine] {
        struct Axis { var line:TextLine;var across:Double;var along:Double;var thickness:Double }
        let reference=0.5
        let axes=lines.map { line -> Axis in
            let q=TermGeometry.pageCorners(line.corners ?? TermGeometry.rectangle(line.region))
            let a=vertical ? ImagePoint(x:(q[0].x+q[1].x)/2,y:(q[0].y+q[1].y)/2) : ImagePoint(x:(q[0].x+q[3].x)/2,y:(q[0].y+q[3].y)/2)
            let b=vertical ? ImagePoint(x:(q[2].x+q[3].x)/2,y:(q[2].y+q[3].y)/2) : ImagePoint(x:(q[1].x+q[2].x)/2,y:(q[1].y+q[2].y)/2)
            let along=vertical ? a.y : a.x, finish=vertical ? b.y : b.x
            let cross=vertical ? a.x : a.y, last=vertical ? b.x : b.y
            let slope=(last-cross)/max(0.00001,finish-along)
            let projected=cross+(reference-along)*max(-0.5,min(0.5,slope))
            let thickness=vertical ? (abs(q[1].x-q[0].x)+abs(q[2].x-q[3].x))/2 : (abs(q[3].y-q[0].y)+abs(q[2].y-q[1].y))/2
            return Axis(line:line,across:projected,along:along,thickness:thickness)
        }
        let sizes=axes.filter{!$0.line.isRuby}.map(\.thickness).sorted()
        let median=sizes.isEmpty ? 0.02 : sizes[sizes.count/2]
        let primary=axes.sorted { vertical ? $0.across>$1.across : $0.across<$1.across }
        var groups:[[Axis]]=[]
        for item in primary {
            if let i=groups.firstIndex(where:{abs($0[0].across-item.across)<max(0.002,median*0.45)}) { groups[i].append(item) }
            else { groups.append([item]) }
        }
        return groups.flatMap{$0.sorted{$0.along<$1.along}.map(\.line)}
    }
}
