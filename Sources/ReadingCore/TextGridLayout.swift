import Foundation

public struct GridGlyph:Hashable,Sendable {
    public var text:String
    public var start:Int
    public var end:Int
    public var box:Region
}
public struct TextGridPage:Equatable,Sendable {
    public var width:Double
    public var height:Double
    public var vertical:Bool
    public var glyphs:[GridGlyph]
    public var regions:[TermRegion]
}

/// Layout uses saved OCR column/row membership, never wraps to viewport width.
/// Offsets remain in the effective page text, so all editing gestures share IDs.
public enum TextGridLayout {
    public static func make(page:PageCapture,occurrences:[Occurrence])->TextGridPage {
        let vertical=page.layout != "Horizontal"
        let lines=page.recognition?.lines.filter{!$0.isRuby} ?? []
        let original=page.recognition?.text ?? page.text
        let boundaries:[Int]
        if let map=page.sourceMap,map.count==page.text.unicodeScalars.count {
            boundaries=(0...original.unicodeScalars.count).map { offset in
                if offset==0 { return 0 }
                if offset==original.unicodeScalars.count { return map.count }
                return map.firstIndex{$0.start>=offset} ?? map.count
            }
        } else { boundaries=rebaseBoundaries(original:original,edited:page.text) }
        let crossSizes=lines.map{vertical ? $0.region.width : $0.region.height}.sorted()
        let crossMedian=crossSizes.isEmpty ? 0.03 : crossSizes[crossSizes.count/2]
        struct Fragment { var range:Range<Int>; var group:Int; var along:Double; var length:Double }
        var groups:[Double]=[], fragments:[Fragment]=[], cursor=0
        for line in lines {
            let oldEnd=cursor+line.text.unicodeScalars.count
            let start=boundaries[min(cursor,boundaries.count-1)],end=boundaries[min(oldEnd,boundaries.count-1)]
            let r=line.region,center=vertical ? r.x+r.width/2 : r.y+r.height/2
            let along=vertical ? r.y : r.x, length=vertical ? r.height : r.width
            // A wide bounding box on a skewed column can overlap its neighbor.
            // Never concatenate OCR lines that occupy overlapping reading-axis spans.
            let group=groups.indices.first { candidate in
                abs(groups[candidate]-center)<max(0.002,crossMedian*0.35) &&
                !fragments.contains { f in
                    f.group==candidate && min(f.along+f.length,along+length)-max(f.along,along)>min(f.length,length)*0.08
                }
            } ?? groups.count
            if group==groups.count { groups.append(center) }
            fragments.append(Fragment(range:start..<max(start,end),group:group,along:vertical ? r.y : r.x,length:vertical ? r.height : r.width))
            cursor=oldEnd
        }
        if fragments.isEmpty { groups=[0]; fragments=[Fragment(range:0..<page.text.unicodeScalars.count,group:0,along:0,length:1)] }
        let order=groups.indices.sorted { vertical ? groups[$0]>groups[$1] : groups[$0]<groups[$1] }
        let ranks=Dictionary(uniqueKeysWithValues:order.enumerated().map{($0.element,$0.offset)})
        let pitches=fragments.compactMap { f -> Double? in
            let count=JapaneseText.slice(page.text,f.range.lowerBound,f.range.upperBound).count
            return count>=4 ? f.length/Double(count) : nil
        }.sorted()
        let pitch=max(0.0001,pitches.isEmpty ? crossMedian : pitches[pitches.count/2])
        let origin=fragments.map(\.along).min() ?? 0
        let cell=32.0, columnPitch=44.0, margin=24.0
        var next=[Int:Int](), slots:[(GridGlyph,Int,Int)]=[], maxAlong=0
        for f in fragments {
            let rank=ranks[f.group] ?? 0
            var row=max(next[rank] ?? 0,Int(((f.along-origin)/pitch).rounded()))
            var offset=f.range.lowerBound
            for character in JapaneseText.slice(page.text,f.range.lowerBound,f.range.upperBound) {
                let text=String(character),end=offset+text.unicodeScalars.count
                slots.append((GridGlyph(text:text,start:offset,end:end,box:Region(x:0,y:0,width:0,height:0)),rank,row))
                row += 1; offset=end
            }
            next[rank]=row; maxAlong=max(maxAlong,row)
        }
        let cross=Double(max(1,groups.count))*columnPitch+margin*2
        let along=Double(max(1,maxAlong))*cell+margin*2
        let width=vertical ? cross : along,height=vertical ? along : cross
        let glyphs=slots.map { glyph,rank,row -> GridGlyph in
            var g=glyph
            let across=margin+Double(vertical ? groups.count-1-rank : rank)*columnPitch
            let position=margin+Double(row)*cell
            g.box=Region(x:(vertical ? across : position)/width,y:(vertical ? position : across)/height,width:cell/width,height:cell/height)
            return g
        }
        var regions:[TermRegion]=[]
        for occurrence in occurrences {
            let covered=glyphs.filter{$0.start<occurrence.end && $0.end>occurrence.start}
            var runs:[[GridGlyph]]=[]
            for glyph in covered {
                if let last=runs.last?.last,
                   (vertical ? abs(last.box.x-glyph.box.x)<0.000001 && abs(last.box.y+last.box.height-glyph.box.y)<0.000001 : abs(last.box.y-glyph.box.y)<0.000001 && abs(last.box.x+last.box.width-glyph.box.x)<0.000001) {
                    runs[runs.count-1].append(glyph)
                } else { runs.append([glyph]) }
            }
            for (index,run) in runs.enumerated() {
                guard let first=run.first,let last=run.last else { continue }
                let r=Region(x:first.box.x,y:first.box.y,width:vertical ? first.box.width : last.box.x+last.box.width-first.box.x,height:vertical ? last.box.y+last.box.height-first.box.y : first.box.height)
                regions.append(TermRegion(id:"grid:\(occurrence.id):\(index)",occurrenceID:occurrence.id,corners:TermGeometry.rectangle(r),estimated:false,vertical:vertical,characterCount:run.count,leadingGap:true,trailingGap:true))
            }
        }
        return TextGridPage(width:width,height:height,vertical:vertical,glyphs:glyphs,regions:regions)
    }
    /// Unchanged characters anchor original line breaks after a manual OCR edit.
    private static func rebaseBoundaries(original:String,edited:String)->[Int] {
        let old=Array(original.unicodeScalars),new=Array(edited.unicodeScalars)
        guard old != new else { return Array(0...old.count) }
        let difference=new.difference(from:old)
        var removed=Set<Int>(),inserted=Set<Int>()
        for change in difference { switch change { case .remove(let i,_,_): removed.insert(i); case .insert(let i,_,_): inserted.insert(i) } }
        var result=[Int](repeating:0,count:old.count+1),j=0
        for i in old.indices {
            while j<new.count && inserted.contains(j) { j += 1 }
            result[i]=j
            if !removed.contains(i) { j += 1 }
        }
        result[0]=0; result[old.count]=new.count
        return result
    }
}
