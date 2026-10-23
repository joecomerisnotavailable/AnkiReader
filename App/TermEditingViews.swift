import SwiftUI

struct TermSplitPopup:View {
    @EnvironmentObject var model:ReaderModel
    @Environment(\.dismiss) private var dismiss
    let page:PageCapture
    let occurrence:Occurrence
    @State private var first=1
    @State private var second=2
    @State private var twoCuts=false
    @State private var busy=false
    private var text:String { JapaneseText.slice(page.text,occurrence.start,occurrence.end) }
    private var count:Int { text.count }
    private var cutSet:Set<Int> { twoCuts ? [first,second] : [first] }
    var body:some View {
        NavigationStack {
            Form {
                if count<2 { Text("This term has only one character and cannot be split.") }
                else {
                    Section("Move the cursors between characters") {
                        BoundaryStrip(text:text,cuts:cutSet) { index,position in
                            if index==0 { first=min(position,twoCuts ? second-1 : count-1) }
                            else { second=max(first+1,position) }
                        }
                        Toggle("Two cuts",isOn:$twoCuts).disabled(count<3)
                            .onChange(of:twoCuts) { _,enabled in if enabled { first=min(first,count-2); second=max(first+1,min(second,count-1)) } }
                        Stepper("First cut after character \(first)",value:$first,in:1...max(1,twoCuts ? second-1 : count-1))
                        if twoCuts { Stepper("Second cut after character \(second)",value:$second,in:min(count-1,first+1)...max(1,count-1)) }
                    }
                    Section("Result") { ForEach(Array(ParseGesture.segments(text,cuts:cutSet).enumerated()),id:\.offset) { _,term in Text(term).font(.title3) } }
                    Text("This changes only the selected occurrence. You can undo it from the page menu.").font(.caption).foregroundStyle(.secondary)
                    if let error=model.error { Text(error).foregroundStyle(.red) }
                }
            }.navigationTitle("Split term").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement:.confirmationAction) { Button("Apply") { busy=true; Task { await model.split(occurrence.id,cuts:cutSet); busy=false; if model.error==nil { dismiss() } } }.disabled(count<2 || busy || model.editingParse) }
                }
        }.interactiveDismissDisabled(busy)
    }
}

/// Two independently draggable handles snap to grapheme boundaries, not UTF-16 units.
struct BoundaryStrip:View {
    let text:String
    let cuts:Set<Int>
    let move:(Int,Int)->Void
    private let cell:CGFloat=38
    var body:some View {
        ScrollView(.horizontal) {
            ZStack(alignment:.topLeading) {
                HStack(spacing:0) { ForEach(Array(Array(text).enumerated()),id:\.offset) { _,character in Text(String(character)).font(.system(size:28)).frame(width:cell,height:64) } }
                ForEach(Array(cuts.sorted().enumerated()),id:\.offset) { index,cut in
                    VStack(spacing:0) { Circle().frame(width:16,height:16); Rectangle().frame(width:3,height:52) }
                        .foregroundStyle(.tint).frame(width:30,height:72).contentShape(Rectangle())
                        .position(x:CGFloat(cut)*cell,y:36)
                        .gesture(DragGesture(coordinateSpace:.named("strip")).onChanged { value in
                            let position=min(max(1,Int((value.location.x/cell).rounded())),max(1,text.count-1)); move(index,position)
                        })
                        .accessibilityLabel("Cut \(index+1) after character \(cut)")
                        .accessibilityValue(Text("\(cut)"))
                        .accessibilityAdjustableAction { direction in move(index,min(max(1,cut+(direction == .increment ? 1 : -1)),max(1,text.count-1))) }
                }
            }.frame(width:CGFloat(text.count)*cell,height:80).coordinateSpace(name:"strip").padding(.horizontal,16)
        }
    }
}

struct ExampleRangeEditor:View {
    @Environment(\.dismiss) private var dismiss
    let page:PageCapture
    let occurrence:Occurrence
    let initial:ExampleContext
    let apply:(ExampleContext)->Void
    @State private var start=0
    @State private var end=0
    private var boundaries:[Int] {
        var values=[0], offset=0
        for c in page.text { offset += String(c).unicodeScalars.count; values.append(offset) }; return values
    }
    private var selectedText:String { JapaneseText.slice(page.text,boundaries[min(start,boundaries.count-1)],boundaries[min(end,boundaries.count-1)]) }
    var body:some View {
        NavigationStack {
            Form {
                Section("Context range") {
                    Text("Move the start and end handles to include more of this photo. Applying replaces the example draft with the selected source text.").font(.caption)
                    RangeHandles(text:page.text,start:$start,end:$end,targetStart:targetStart,targetEnd:targetEnd)
                    Stepper("Start: character \(start+1)",value:$start,in:0...targetStart)
                    Stepper("End: character \(end)",value:$end,in:targetEnd...max(targetEnd,boundaries.count-1))
                }
                Section("Selected context") { Text(selectedText).font(.title3).textSelection(.enabled) }
                Section("Full page text") { Text(page.text).textSelection(.enabled) }
            }.navigationTitle("Example context").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) { Button("Use selected text") { var next=initial; next.replaceRange(boundaries[start]..<boundaries[end],from:page.text); apply(next); dismiss() }.disabled(!selectedText.contains(occurrence.surface)) }
                }.onAppear { start=boundaries.lastIndex(where:{$0<=initial.start}) ?? 0; end=boundaries.firstIndex(where:{$0>=initial.end}) ?? boundaries.count-1 }
        }
    }
    private var targetStart:Int { boundaries.lastIndex(where:{$0<=occurrence.start}) ?? 0 }
    private var targetEnd:Int { boundaries.firstIndex(where:{$0>=occurrence.end}) ?? boundaries.count-1 }
}

private struct RangeHandles:View {
    let text:String
    @Binding var start:Int
    @Binding var end:Int
    let targetStart:Int
    let targetEnd:Int
    var body:some View {
        VStack {
            Text("Start").font(.caption)
            Slider(value:Binding(get:{Double(start)},set:{start=Int($0.rounded())}),in:0...Double(max(1,targetStart)),step:1).disabled(targetStart==0).accessibilityLabel("Example start handle")
            Text("End").font(.caption)
            Slider(value:Binding(get:{Double(end)},set:{end=Int($0.rounded())}),in:Double(targetEnd)...Double(max(targetEnd+1,text.count)),step:1).disabled(targetEnd==text.count).accessibilityLabel("Example end handle")
        }
    }
}
