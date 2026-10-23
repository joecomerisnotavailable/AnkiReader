import Foundation

public struct ImagePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x=x; self.y=y }
}
public struct TextElementGeometry: Codable, Hashable, Sendable {
    public var text: String
    /// Scalar offsets relative to the containing OCR line.
    public var start: Int
    public var end: Int
    public var corners: [ImagePoint]
    public init(text: String, start: Int, end: Int, corners: [ImagePoint]) { self.text=text; self.start=start; self.end=end; self.corners=corners }
}
public struct CharacterAnchor: Hashable, Sendable {
    public var corners: [ImagePoint]
    public var text: String
    public var vertical: Bool
}
public struct TermRegion: Identifiable, Hashable, Sendable {
    public var id: String
    public var occurrenceID: String
    public var corners: [ImagePoint]
    public var estimated: Bool
    public var vertical: Bool
    public var characterCount: Int = 1
    public var anchor: CharacterAnchor? = nil
    public var characterStart: Int = 0
    public var characterEnd: Int = 0
    public var leadingGap: Bool?
    public var trailingGap: Bool?
}
public enum TermGeometry {
    /// SDK corner order can follow text rotation. Normalize to physical page
    /// top-left, top-right, bottom-right, bottom-left before slicing terms.
    public static func pageCorners(_ input:[ImagePoint])->[ImagePoint] {
        guard input.count==4 else { return input }
        let cx=input.map(\.x).reduce(0,+)/4, cy=input.map(\.y).reduce(0,+)/4
        let points=input.sorted { atan2($0.y-cy,$0.x-cx)<atan2($1.y-cy,$1.x-cx) }
        func slope(_ i:Int)->Double {
            let a=points[i], b=points[(i+1)%4]
            return abs(b.y-a.y)/max(0.000001,hypot(b.x-a.x,b.y-a.y))
        }
        var edge=(0..<4).min { slope($0)<slope($1) }!
        let opposite=(edge+2)%4
        if points[opposite].y+points[(opposite+1)%4].y < points[edge].y+points[(edge+1)%4].y { edge=opposite }
        let ordered=(0..<4).map { points[(edge+$0)%4] }
        return ordered[0].x<=ordered[1].x ? ordered : [ordered[1],ordered[0],ordered[3],ordered[2]]
    }
    public static func separator(_ region:TermRegion)->[ImagePoint] {
        guard region.corners.count==4 else { return [] }
        return region.vertical ? [region.corners[3],region.corners[2]] : [region.corners[1],region.corners[2]]
    }
    public static func rectangle(_ region: Region) -> [ImagePoint] {
        [ImagePoint(x:region.x,y:region.y),ImagePoint(x:region.x+region.width,y:region.y),ImagePoint(x:region.x+region.width,y:region.y+region.height),ImagePoint(x:region.x,y:region.y+region.height)]
    }
    public static func regions(page: PageCapture, occurrences: [Occurrence]) -> [TermRegion] {
        guard let recognition = page.recognition else { return [] }
        let vertical = page.layout != "Horizontal", original = recognition.text
        var lineStart = 0
        var lines: [(TextLine,Int,Int)] = []
        for line in recognition.lines where !line.isRuby {
            let end = lineStart+line.text.unicodeScalars.count
            lines.append((line,lineStart,end)); lineStart=end
        }
        var result: [TermRegion] = []
        for occurrence in occurrences {
            var start=occurrence.start, end=occurrence.end
            if page.text != original {
                // A unique unchanged anchor is safe. Repeated or rewritten text has no asserted location.
                let anchor = JapaneseText.slice(page.text,start,end)
                guard !anchor.isEmpty, let range=original.range(of:anchor), original[range.upperBound...].range(of:anchor)==nil else { continue }
                start=original[..<range.lowerBound].unicodeScalars.count; end=start+anchor.unicodeScalars.count
            }
            for (line,a,b) in lines where start < b && end > a {
                let localStart=max(start,a)-a, localEnd=min(end,b)-a
                let elements=(line.elements ?? []).filter { $0.start < localEnd && $0.end > localStart && $0.corners.count == 4 }
                var covered=Set<Int>()
                for element in elements {
                    let lo=max(localStart,element.start), hi=min(localEnd,element.end)
                    guard hi>lo else { continue }
                    covered.formUnion(lo..<hi)
                    let partial=lo != element.start || hi != element.end
                    let quad=slice(element.corners, from:fraction(line.text,from:element.start,to:lo,totalEnd:element.end), to:fraction(line.text,from:element.start,to:hi,totalEnd:element.end), vertical:vertical)
                    result.append(TermRegion(id:"\(occurrence.id):\(a+lo):\(a+hi)",occurrenceID:occurrence.id,corners:quad,estimated:partial,vertical:vertical,characterCount:max(1,JapaneseText.slice(line.text,lo,hi).count),anchor:CharacterAnchor(corners:pageCorners(element.corners),text:JapaneseText.slice(line.text,element.start,element.end),vertical:vertical),characterStart:JapaneseText.slice(line.text,element.start,lo).count,characterEnd:JapaneseText.slice(line.text,element.start,hi).count))
                }
                // Older captures, or text not covered by SDK elements, use a clearly estimated line slice.
                var position=localStart
                while position<localEnd {
                    if covered.contains(position) { position += 1; continue }
                    let lo=position
                    while position<localEnd && !covered.contains(position) { position += 1 }
                    let quad=slice(line.corners?.count == 4 ? line.corners! : rectangle(line.region),from:fraction(line.text,from:0,to:lo,totalEnd:b-a),to:fraction(line.text,from:0,to:position,totalEnd:b-a),vertical:vertical)
                    result.append(TermRegion(id:"\(occurrence.id):fallback:\(a+lo)",occurrenceID:occurrence.id,corners:quad,estimated:true,vertical:vertical,characterCount:max(1,JapaneseText.slice(line.text,lo,position).count),anchor:CharacterAnchor(corners:pageCorners(line.corners?.count == 4 ? line.corners! : rectangle(line.region)),text:line.text,vertical:vertical),characterStart:JapaneseText.slice(line.text,0,lo).count,characterEnd:JapaneseText.slice(line.text,0,position).count))
                }
            }
        }
        return result
    }
    private static func fraction(_ text:String,from:Int,to:Int,totalEnd:Int)->Double {
        let count=JapaneseText.slice(text,from,totalEnd).count
        return min(1,max(0,Double(JapaneseText.slice(text,from,to).count)/Double(max(1,count))))
    }
    public static func slice(_ quad:[ImagePoint],from:Double,to:Double,vertical:Bool)->[ImagePoint] {
        guard quad.count==4 else { return [] }
        let quad=pageCorners(quad)
        func lerp(_ a:ImagePoint,_ b:ImagePoint,_ t:Double)->ImagePoint { ImagePoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t) }
        if vertical { return [lerp(quad[0],quad[3],from),lerp(quad[1],quad[2],from),lerp(quad[1],quad[2],to),lerp(quad[0],quad[3],to)] }
        return [lerp(quad[0],quad[1],from),lerp(quad[0],quad[1],to),lerp(quad[3],quad[2],to),lerp(quad[3],quad[2],from)]
    }
}
