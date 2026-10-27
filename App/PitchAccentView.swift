import SwiftUI

private actor PitchProvider {
    static let shared=PitchProvider()
    private var index:PitchIndex?
    private var cache:[String:[PitchPattern]]=[:]
    func patterns(_ word:Lexeme)->[PitchPattern] {
        let key=word.expression+"\t"+word.reading
        if let saved=cache[key] { return saved }
        do {
            if index==nil,let url=Bundle.main.url(forResource:"dictionary",withExtension:"sqlite") { index=try PitchIndex(url:url) }
            let result=try index?.lookup(expression:word.expression,reading:word.reading) ?? []
            if cache.count>2000 { cache.removeAll() };cache[key]=result;return result
        } catch { return [] }
    }
}
struct PitchAccentView:View {
    var word:Lexeme
    @ScaledMetric(relativeTo:.caption2) private var moraWidth:CGFloat=22
    @ScaledMetric(relativeTo:.caption2) private var labelHeight:CGFloat=16
    @State private var patterns:[PitchPattern]=[]
    var body:some View {
        Group {
            if patterns.isEmpty { Text("Pitch unavailable").font(.caption2).foregroundStyle(.tertiary) }
            else {
                ScrollView(.horizontal,showsIndicators:false) {
                    HStack(spacing:16) {
                        ForEach(patterns,id:\.self) { pattern in
                            let morae=PitchAccent.morae(word.reading)
                            let heights=PitchAccent.heights(moraCount:morae.count,drop:pattern.position)
                            VStack(alignment:.leading,spacing:1) {
                                Canvas { context,size in
                                    let step=size.width/CGFloat(max(1,heights.count))
                                    var path=Path()
                                    for i in heights.indices {
                                        let point=CGPoint(x:step*(CGFloat(i)+0.5),y:heights[i] ? 3 : 15)
                                        if i==0 { path.move(to:point) } else { path.addLine(to:point) }
                                        let dot=Path(ellipseIn:CGRect(x:point.x-2,y:point.y-2,width:4,height:4))
                                        if i==morae.count { context.stroke(dot,with:.color(.secondary),lineWidth:1) }
                                        else { context.fill(dot,with:.color(.primary)) }
                                    }
                                    context.stroke(path,with:.color(.primary),lineWidth:1.5)
                                }.frame(height:19)
                                HStack(spacing:0) { ForEach(Array((morae+["·"]).enumerated()),id:\.offset) { _,mora in Text(mora).font(.caption2).frame(width:moraWidth) } }
                                Text("[\(pattern.position)] \(pattern.label)").font(.caption2).foregroundStyle(.secondary)
                            }.frame(width:CGFloat(morae.count+1)*moraWidth)
                            .accessibilityElement(children:.ignore)
                            .accessibilityLabel("\(word.expression), \(word.reading), \(pattern.position==0 ? "unaccented" : "pitch drops after mora \(pattern.position)"), \(pattern.label)")
                        }
                    }
                }.frame(height:19+labelHeight*2)
                .accessibilityElement(children:.ignore)
                .accessibilityLabel(word.expression+", "+word.reading+", "+patterns.map { $0.position==0 ? "unaccented" : "pitch drops after mora \($0.position)" }.joined(separator:"; "))
                .accessibilityIdentifier("pitch-accent-graphs")
            }
        }.task(id:word.expression+"\t"+word.reading) { patterns=await PitchProvider.shared.patterns(word) }
    }
}
