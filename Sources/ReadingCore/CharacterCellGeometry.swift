import Foundation

public struct CharacterCellFit: Sendable {
    public var boundaries:[Double]
    public var clear:[Bool]
}

/// A bounded, shared fit for each OCR element (or saved line on older captures).
/// OCR owns text and geometry; this only refines the locations between characters.
public enum CharacterCellGeometry {
    public static func fit(_ anchor:CharacterAnchor,raster:PageRaster)->CharacterCellFit? {
        let n=anchor.text.count, q=anchor.corners
        guard n>=2,n<=160,q.count==4 else { return nil }
        // Full-cell typography is not a safe prior for horizontal Latin prose.
        let fullWidth=anchor.text.unicodeScalars.filter{$0.value>=0x3000}.count
        guard Double(fullWidth)/Double(max(1,anchor.text.unicodeScalars.count))>=0.75 else { return nil }
        let vertical=anchor.vertical
        func point(_ t:Double,_ u:Double)->ImagePoint {
            let end=vertical ? q[3] : q[1], across=vertical ? q[1] : q[3]
            let a=ImagePoint(x:q[0].x+(end.x-q[0].x)*t,y:q[0].y+(end.y-q[0].y)*t)
            let b=ImagePoint(x:across.x+(q[2].x-across.x)*t,y:across.y+(q[2].y-across.y)*t)
            return ImagePoint(x:a.x+(b.x-a.x)*u,y:a.y+(b.y-a.y)*u)
        }
        // Sample a rectified strip once. Complexity is linear in character count.
        let subdivisions=24, steps=n*subdivisions
        var samples:[[Double]]=[]
        for i in -12...(steps+12) {
            samples.append((0..<20).compactMap{raster.sample(point(Double(i)/Double(steps),0.08+0.84*Double($0)/19))})
        }
        let values=samples.flatMap{$0}.sorted()
        guard !values.isEmpty else { return nil }
        let paper=values[Int(Double(values.count-1)*0.85)], ink=values[Int(Double(values.count-1)*0.1)]
        guard paper-ink>0.14 else { return nil }
        let threshold=paper-max(0.10,(paper-ink)*0.32)
        let density=samples.map{ row in row.count<20 ? 1.0 : Double(row.filter{$0<threshold}.count)/20 }
        // Shared boundaries cannot cross. A spacing penalty discourages snapping
        // into an internal glyph gap, or collapsing a small punctuation cell.
        let offsets=Array(-10...10), k=offsets.count
        var costs=Array(repeating:Double.infinity,count:k), parents=[[Int]]()
        for boundary in 0...n {
            var next=Array(repeating:Double.infinity,count:k), back=Array(repeating:0,count:k)
            for j in 0..<k {
                let index=boundary*subdivisions+offsets[j]+12
                let dark=(density[index-1]+2*density[index]+density[index+1])/4
                let displacement=Double(offsets[j])/Double(subdivisions)
                let unary=dark*5+displacement*displacement*0.65
                if boundary==0 { next[j]=unary; continue }
                for previous in 0..<k {
                    let change=Double(offsets[j]-offsets[previous])/Double(subdivisions)
                    guard abs(change)<=0.34 else { continue }
                    let cost=costs[previous]+unary+change*change*4
                    if cost<next[j] { next[j]=cost; back[j]=previous }
                }
            }
            parents.append(back); costs=next
        }
        var j=costs.indices.min{costs[$0]<costs[$1]}!, chosen=Array(repeating:0,count:n+1)
        for boundary in stride(from:n,through:0,by:-1) { chosen[boundary]=offsets[j]; j=parents[boundary][j] }
        let clear=(0...n).map { boundary -> Bool in
            let index=boundary*subdivisions+chosen[boundary]+12
            return max(density[index-1],density[index],density[index+1])<=0.05
        }
        // Reject a grid inconsistent with the observed text (bad character count,
        // merged columns, heavy blur). The existing conservative fallback applies.
        guard Double(clear.filter{$0}.count)/Double(n+1)>=0.55 else { return nil }
        return CharacterCellFit(boundaries:(0...n).map{Double($0)/Double(n)+Double(chosen[$0])/Double(steps)},clear:clear)
    }
}
