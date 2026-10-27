import Foundation

/// Top-left-origin grayscale pixels, sampled locally; this performs no recognition.
public struct PageRaster: Sendable {
    public let width:Int
    public let height:Int
    public let pixels:[UInt8]
    public init(width:Int,height:Int,pixels:[UInt8]) { self.width=width; self.height=height; self.pixels=pixels }
    func sample(_ p:ImagePoint)->Double? {
        guard width>0,height>0,pixels.count==width*height,p.x>=0,p.x<1,p.y>=0,p.y<1 else { return nil }
        return Double(pixels[min(height-1,Int(p.y*Double(height)))*width+min(width-1,Int(p.x*Double(width)))])/255
    }
}

/// Owned by one image view; discard whenever its raster changes. Failed fits are cached too.
public struct InkGeometryCache: Sendable {
    fileprivate var fits:[CharacterAnchor:CharacterCellFit]=[:]
    fileprivate var attempted=Set<CharacterAnchor>()
    public init() {}
}

public enum InkGeometry {
    /// Snap only within a fraction of a character pitch. Bad OCR remains estimated;
    /// no reliable local whitespace means no transverse stroke, not a guessed cut.
    public static func refine(_ regions:[TermRegion],raster:PageRaster)->[TermRegion] {
        var cache=InkGeometryCache()
        return refine(regions,raster:raster,cache:&cache)
    }
    public static func refine(_ regions:[TermRegion],raster:PageRaster,cache:inout InkGeometryCache)->[TermRegion] {
        let anchors=Set(regions.compactMap(\.anchor))
        // Bound memory to anchors on the current page, including after text corrections.
        cache.fits=cache.fits.filter{anchors.contains($0.key)}
        cache.attempted.formIntersection(anchors)
        for anchor in anchors where !cache.attempted.contains(anchor) {
            cache.attempted.insert(anchor)
            if let fit=CharacterCellGeometry.fit(anchor,raster:raster) { cache.fits[anchor]=fit }
        }
        let fits=cache.fits
        return regions.map { original in
            if original.imageAligned { return original }
            if let anchor=original.anchor, let fit=fits[anchor], original.characterEnd<fit.boundaries.count {
                var result=original
                result.corners=TermGeometry.slice(anchor.corners,from:fit.boundaries[original.characterStart],to:fit.boundaries[original.characterEnd],vertical:original.vertical)
                result.leadingGap=fit.clear[original.characterStart]
                result.trailingGap=fit.clear[original.characterEnd]
                result.estimated=true
                return result
            }
            guard original.corners.count==4 else { return original }
            var result=original
            let q=original.corners, vertical=original.vertical
            func point(_ t:Double,_ across:Double)->ImagePoint {
                let a=q[0], b=vertical ? q[3] : q[1]
                let c=vertical ? q[1] : q[3], d=q[2]
                let left=ImagePoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t)
                let right=ImagePoint(x:c.x+(d.x-c.x)*t,y:c.y+(d.y-c.y)*t)
                return ImagePoint(x:left.x+(right.x-left.x)*across,y:left.y+(right.y-left.y)*across)
            }
            let count=Double(max(1,original.characterCount))
            func gap(near expected:Double)->Double? {
                let radius=0.38/count, steps=48
                var rows:[[Double]]=[]
                for step in 0...steps {
                    let t=expected-radius+2*radius*Double(step)/Double(steps)
                    // Inset laterally to avoid adjacent columns and furigana.
                    let samples=(0..<24).compactMap { raster.sample(point(t,0.08+0.84*Double($0)/23)) }
                    guard samples.count==24 else { return nil }
                    rows.append(samples)
                }
                let sorted=rows.flatMap{$0}.sorted()
                let paper=sorted[Int(Double(sorted.count-1)*0.85)]
                let ink=sorted[Int(Double(sorted.count-1)*0.1)]
                guard paper-ink>0.14 else { return nil }
                let threshold=paper-max(0.10,(paper-ink)*0.32)
                let blank=rows.map { row in Double(row.filter{$0<threshold}.count)/Double(row.count)<=0.045 }
                var runs:[ClosedRange<Int>]=[], start:Int?
                for i in blank.indices {
                    if blank[i] { if start==nil { start=i } }
                    else if let s=start { runs.append(s...(i-1)); start=nil }
                }
                if let start { runs.append(start...(blank.count-1)) }
                // Do not snap to a cropped edge of the search area or a one-pixel valley.
                let candidates=runs.filter { $0.lowerBound>0 && $0.upperBound<steps && $0.count>=3 }
                guard let best=candidates.min(by: {
                    abs(Double($0.lowerBound+$0.upperBound)/2-Double(steps)/2)-Double($0.count)*0.12 < abs(Double($1.lowerBound+$1.upperBound)/2-Double(steps)/2)-Double($1.count)*0.12
                }) else { return nil }
                return expected-radius+2*radius*Double(best.lowerBound+best.upperBound)/2/Double(steps)
            }
            let start=gap(near:0), end=gap(near:1)
            result.leadingGap=start != nil; result.trailingGap=end != nil
            let a=start ?? 0, b=end ?? 1
            guard a<b else { return original }
            result.corners=vertical ? [point(a,0),point(a,1),point(b,1),point(b,0)] : [point(a,0),point(b,0),point(b,1),point(a,1)]
            return result
        }
    }
}
