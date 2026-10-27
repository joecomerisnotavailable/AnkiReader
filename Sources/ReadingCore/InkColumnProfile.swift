import Foundation

public struct InkColumnChunk: Sendable {
    public var from: Double
    public var to: Double
    public var estimatedCells: Double
}

/// A physical spacing estimate, independent of the OCR transcript. It is a
/// consistency check and crop planner, not a claim to recognize/count every glyph.
public struct InkColumnProfile: Sendable {
    public var pitchFraction: Double
    public var confidence: Double
    public var chunks: [InkColumnChunk]

    public static func measure(corners: [ImagePoint], vertical: Bool, raster: PageRaster) -> Self? {
        let q = TermGeometry.pageCorners(corners)
        guard q.count == 4 else { return nil }
        func distance(_ a: ImagePoint, _ b: ImagePoint) -> Double {
            hypot((a.x-b.x)*Double(raster.width), (a.y-b.y)*Double(raster.height))
        }
        let length = vertical ? (distance(q[0],q[3])+distance(q[1],q[2]))/2 : (distance(q[0],q[1])+distance(q[3],q[2]))/2
        let width = vertical ? (distance(q[0],q[1])+distance(q[3],q[2]))/2 : (distance(q[0],q[3])+distance(q[1],q[2]))/2
        guard width >= 8, length/width >= 10 else { return nil }
        let steps = min(4096, Int(ceil(length))), lateral = 20
        func point(_ t: Double, _ u: Double) -> ImagePoint {
            let end = vertical ? q[3] : q[1], across = vertical ? q[1] : q[3]
            let a = ImagePoint(x:q[0].x+(end.x-q[0].x)*t,y:q[0].y+(end.y-q[0].y)*t)
            let b = ImagePoint(x:across.x+(q[2].x-across.x)*t,y:across.y+(q[2].y-across.y)*t)
            return ImagePoint(x:a.x+(b.x-a.x)*u,y:a.y+(b.y-a.y)*u)
        }
        var samples = [Double](); samples.reserveCapacity(steps*lateral)
        var histogram=[Int](repeating:0,count:256)
        for i in 0..<steps {
            for j in 0..<lateral {
                guard let value = raster.sample(point(Double(i)/Double(steps-1),0.08+0.84*Double(j)/Double(lateral-1))) else { return nil }
                samples.append(value)
                histogram[max(0,min(255,Int(value*255)))] += 1
            }
        }
        func quantile(_ fraction:Double)->Double {
            let target=Int(Double(samples.count)*fraction)
            var count=0
            for value in histogram.indices { count += histogram[value];if count>target { return Double(value)/255 } }
            return 1
        }
        let paper=quantile(0.85),ink=quantile(0.1)
        guard paper-ink > 0.14 else { return nil }
        let threshold = paper-max(0.10,(paper-ink)*0.32)
        let density = (0..<steps).map { i in Double(samples[(i*lateral)..<((i+1)*lateral)].filter{$0<threshold}.count)/Double(lateral) }
        var profile=[Double]();profile.reserveCapacity(steps)
        for i in 0..<steps {
            let a=max(0,i-1),b=min(steps-1,i+1)
            var total=0.0
            for j in a...b { total += density[j] }
            profile.append(total/Double(b-a+1))
        }
        let mean = profile.reduce(0,+)/Double(steps)
        let scale = Double(steps)/length
        let low = max(4,Int(width*scale*0.80)), high = min(steps/5,Int(width*scale*1.55))
        guard high > low else { return nil }
        var best = (pitch:low,score:-1.0)
        for lag in low...high {
            var product = 0.0, a2 = 0.0, b2 = 0.0
            for i in 0..<(steps-lag) {
                let a = profile[i]-mean, b = profile[i+lag]-mean
                product += a*b; a2 += a*a; b2 += b*b
            }
            let score = product/max(0.000001,sqrt(a2*b2))
            if score > best.score { best = (lag,score) }
        }
        guard best.score >= 0.24 else { return nil }
        let pitch = Double(best.pitch)
        var gaps = [ClosedRange<Int>](), beginning: Int?
        for i in 0..<steps {
            if profile[i] <= 0.035 { if beginning == nil { beginning = i } }
            else if let start = beginning {
                if i-start >= max(2,Int(pitch*0.025)) { gaps.append(start...(i-1)) }
                beginning = nil
            }
        }
        if let start = beginning { gaps.append(start...(steps-1)) }
        // Narrow gaps establish the phase. A wide punctuation gap must not drag
        // the grid toward its midpoint or consume the following character.
        let narrow = gaps.filter{Double($0.count) < pitch*0.32}
        guard narrow.count >= 6 else { return nil }
        let centers = narrow.map{Double($0.lowerBound+$0.upperBound)/2}
        let phase = centers.max { a,b in
            func support(_ p:Double)->Double {
                centers.map { x in let d = abs((x-p).remainder(dividingBy:pitch)); return max(0,1-d/(pitch*0.22)) }.reduce(0,+)
            }
            return support(a)<support(b)
        }!
        var cuts = [0.0], position = 0.0
        while Double(steps)-position > pitch*10 {
            let desired = position+pitch*8
            let options = gaps.compactMap { gap -> Double? in
                let lo = Double(gap.lowerBound), hi = Double(gap.upperBound)
                guard lo > position+pitch*5, hi < position+pitch*10 else { return nil }
                let cell = phase+((desired-phase)/pitch).rounded()*pitch
                let candidate = min(hi,max(lo,cell))
                return candidate
            }
            guard let cut = options.min(by:{abs($0-desired)<abs($1-desired)}) else { break }
            cuts.append(cut/Double(steps-1)); position = cut
        }
        cuts.append(1)
        let chunks = zip(cuts,cuts.dropFirst()).compactMap { originalA,originalB -> InkColumnChunk? in
            var a=originalA*Double(steps-1),b=originalB*Double(steps-1)
            // Small isolated punctuation at a crop edge is often dropped by a
            // recognizer. Exclude that edge cell from this optional retry only;
            // its original OCR text and geometry remain untouched.
            func smallInk(_ start:Double,_ end:Double)->Bool {
                let lower=max(0,Int(ceil(start))),upper=min(steps-1,Int(floor(end)))
                guard upper>lower else { return false }
                let occupied=(lower...upper).filter{profile[$0]>0.06}
                guard let first=occupied.first,let last=occupied.last else { return true }
                return Double(last-first+1)<pitch*0.4
            }
            func nearbyGap(_ target:Double)->Double? {
                gaps.compactMap { gap -> Double? in
                    let lo=Double(gap.lowerBound),hi=Double(gap.upperBound)
                    let p=min(hi,max(lo,target))
                    return abs(p-target)<pitch*0.22 ? p : nil
                }.min{abs($0-target)<abs($1-target)}
            }
            if smallInk(a,a+pitch*0.95),let cut=nearbyGap(a+pitch) { a=cut }
            if smallInk(b-pitch*0.95,b),let cut=nearbyGap(b-pitch) { b=cut }
            let cells = (b-a)/pitch
            guard cells >= 3, cells <= 11 else { return nil }
            return InkColumnChunk(from:a/Double(steps-1),to:b/Double(steps-1),estimatedCells:cells)
        }
        guard !chunks.isEmpty else { return nil }
        return Self(pitchFraction:pitch/Double(steps-1),confidence:best.score,chunks:chunks)
    }

    /// Rectify a proposed crop using the same quadrilateral and normalized
    /// coordinates used by the overlay. Paper-colored padding adds no neighboring text.
    /// Vertical strips rotate counterclockwise for jpn_vert's single-line mode,
    /// avoiding its unreliable automatic block detection on a small upright crop.
    public static func crop(raster:PageRaster,corners:[ImagePoint],vertical:Bool,from:Double,to:Double)->PageRaster? {
        let q=TermGeometry.pageCorners(corners)
        guard q.count==4,from>=0,to<=1,from<to else { return nil }
        func distance(_ a:ImagePoint,_ b:ImagePoint)->Double { hypot((a.x-b.x)*Double(raster.width),(a.y-b.y)*Double(raster.height)) }
        let width=vertical ? (distance(q[0],q[1])+distance(q[3],q[2]))/2 : (distance(q[0],q[3])+distance(q[1],q[2]))/2
        let length=(vertical ? (distance(q[0],q[3])+distance(q[1],q[2]))/2 : (distance(q[0],q[1])+distance(q[3],q[2]))/2)*(to-from)
        let across=max(1,Int(ceil(width*1.16))),along=max(1,Int(ceil(length))),pad=max(8,across/3)
        let w=(vertical ? across : along)+pad*2,h=(vertical ? along : across)+pad*2
        guard w*h<=4_000_000 else { return nil }
        var pixels=[UInt8](repeating:255,count:w*h)
        var histogram=[Int](repeating:0,count:256),sampleCount=0
        let quad=TermGeometry.slice(q,from:from,to:to,vertical:vertical)
        for a in 0..<along { for b in 0..<across {
            let t=Double(a)/Double(max(1,along-1)),u = -0.08+1.16*Double(b)/Double(max(1,across-1))
            let end=vertical ? quad[3] : quad[1],edge=vertical ? quad[1] : quad[3]
            let p=ImagePoint(x:quad[0].x+(end.x-quad[0].x)*t,y:quad[0].y+(end.y-quad[0].y)*t)
            let r=ImagePoint(x:edge.x+(quad[2].x-edge.x)*t,y:edge.y+(quad[2].y-edge.y)*t)
            let point=ImagePoint(x:p.x+(r.x-p.x)*u,y:p.y+(r.y-p.y)*u)
            if let value=raster.sample(point) {
                let byte=UInt8(max(0,min(255,value*255)))
                pixels[(pad+(vertical ? a : b))*w+pad+(vertical ? b : a)]=byte
                histogram[Int(byte)] += 1;sampleCount += 1
            }
        }}
        // Pure white padding around gray photographed paper can make Otsu's
        // threshold classify the entire paper strip as ink. Match local paper.
        var accumulated=0,paper:UInt8=255
        for value in histogram.indices {
            accumulated += histogram[value]
            if accumulated>sampleCount*85/100 {paper=UInt8(value);break}
        }
        for y in 0..<h { for x in 0..<w where x<pad || x>=w-pad || y<pad || y>=h-pad { pixels[y*w+x]=paper } }
        if vertical {
            var rotated=[UInt8](repeating:255,count:w*h)
            for y in 0..<h { for x in 0..<w { rotated[(w-1-x)*h+y]=pixels[y*w+x] } }
            return PageRaster(width:h,height:w,pixels:rotated)
        }
        return PageRaster(width:w,height:h,pixels:pixels)
    }
}
