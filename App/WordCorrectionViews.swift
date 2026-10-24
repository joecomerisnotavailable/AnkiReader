import SwiftUI
import UIKit

struct CorrectionBadge:View {
    var changes:[TextCorrection]
    var legacy=false
    var body:some View {
        if let change=changes.last {
            HStack(spacing:3) {
                Spacer(minLength:0)
                Text(change.before.isEmpty ? "∅" : change.before).strikethrough()
                Text("→")
                Text(change.after.isEmpty ? "∅" : change.after)
                if changes.count>1 { Text("+\(changes.count-1)") }
            }.font(.caption).foregroundStyle(.orange).lineLimit(1)
                .accessibilityElement(children:.ignore)
                .accessibilityLabel("Corrected \(change.before) to \(change.after)\(changes.count>1 ? ", plus \(changes.count-1) earlier changes" : "")")
        } else if legacy { Text("Previously edited").font(.caption).foregroundStyle(.orange).frame(maxWidth:.infinity,alignment:.trailing) }
    }
}
struct OccurrenceCorrectionBadge:View {
    @EnvironmentObject var model:ReaderModel
    let occurrence:Occurrence
    var body:some View {
        if let page=model.state.captures.first(where:{$0.id==occurrence.captureID}) {
            CorrectionBadge(changes:CorrectionMapping.history(occurrence,page:page),legacy:occurrence.corrected)
        }
    }
}
struct WordCorrectionControls:View {
    @EnvironmentObject var model:ReaderModel
    let occurrence:Occurrence
    var beforePreview:()->Bool
    var didApply:()->Void
    var dirtyChanged:(Bool)->Void
    @State private var draft=""
    @State private var selection=NSRange(location:0,length:0)
    @State private var method=CorrectionMethod.typing
    @State private var candidates:[PhotoCorrectionCandidate]=[]
    @State private var definitions:[String:String]=[:]
    @State private var contextOpen=false
    @State private var drawing=false
    @State private var drawingSelection=NSRange(location:0,length:0)
    @State private var busy=false
    @State private var message=""
    @State private var requestID=UUID()
    @State private var task:Task<Void,Never>?
    @State private var preview:CorrectionPreview?
    @State private var crop:UIImage?
    @State private var keepBoundaries=false
    private var page:PageCapture? { model.state.captures.first{$0.id==occurrence.captureID} }
    private var original:String { page.map{JapaneseText.slice($0.text,occurrence.start,occurrence.end)} ?? occurrence.surface }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Text as printed").font(.caption).foregroundStyle(.secondary)
            SelectedWordField(text:$draft,selection:$selection,onEdit:{ method = .typing;invalidate() }).frame(minHeight:54,maxHeight:90)
            Button("See in context") { if beforePreview() { contextOpen=true } }.disabled(draft != original)
            if draft != original { Text("Apply or cancel this draft before editing neighboring text.").font(.caption) }
            if let crop { Image(uiImage:crop).resizable().scaledToFit().frame(maxHeight:150).accessibilityLabel("Original photographed text") }
            HStack {
                Button("Try alternatives") { alternatives() }.disabled(busy || draft != original)
                Button("Draw kanji") { drawingSelection=selectedRange;drawing=true }
            }.buttonStyle(.bordered)
            if draft != original { Text("Photo alternatives use the original text. Cancel your draft to try them again.").font(.caption).foregroundStyle(.secondary) }
            if busy { HStack { ProgressView();Button("Cancel request") { invalidate();busy=false } } }
            ForEach(candidates) { candidate in
                VStack(alignment:.leading) {
                    if let replacement=candidate.replacement {
                        Button(replacement) { replaceSelection(replacement,range:drawingSelection,using:.photo) }.font(.title3)
                    } else { Text(candidate.text).textSelection(.enabled);Text("Crop text — select and copy a correction manually").font(.caption) }
                    Text([candidate.engine,definitions[candidate.text] ?? ""].filter{!$0.isEmpty}.joined(separator:" · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
            if draft != original {
                if draft.isEmpty { Text("Preview removal of this OCR text. Nothing is deleted until you apply.").font(.caption).foregroundStyle(.orange) }
                Toggle("Keep existing word boundaries",isOn:$keepBoundaries)
                HStack {
                    Button("Preview correction") { makePreview() }.disabled(busy)
                    Button("Cancel edit") { draft=original;invalidate();message="" }
                }.buttonStyle(.bordered)
            }
            OccurrenceCorrectionBadge(occurrence:occurrence)
            if let page {
                let history=CorrectionMapping.history(occurrence,page:page)
                if !history.isEmpty {
                    DisclosureGroup("Correction history") {
                        ForEach(history) { change in
                            HStack { Text(change.before.isEmpty ? "∅" : change.before).strikethrough();Text("→");Text(change.after.isEmpty ? "∅" : change.after);Spacer();Text(change.method.rawValue).font(.caption) }.foregroundStyle(.orange)
                        }
                    }
                }
            }
        }
        .onAppear {
            draft=original
            if let page { let url=model.imageURL(page);let all=model.state.occurrences
                Task { crop=await Task.detached { CorrectionPhoto.crop(page:page,target:occurrence,all:all,url:url,context:false)?.image }.value }
            }
        }
        .onChange(of:page?.textRevision) { _,_ in invalidate() }
        .onChange(of:selection) { _,_ in if busy || !candidates.isEmpty { invalidate() } }
        .onChange(of:draft) { _,value in dirtyChanged(value != original) }
        .onDisappear { invalidate() }
        .fullScreenCover(isPresented:$drawing) { HandwritingPad(replacementText:draft,initialSelection:drawingSelection) { value,range in replaceSelection(value,range:range,using:.handwriting) } }
        .sheet(isPresented:$contextOpen) { SegmentedContextEditor(occurrence:occurrence) { contextOpen=false;didApply() } }
        .sheet(isPresented:Binding(get:{preview != nil},set:{if !$0 { preview=nil }})) {
            if let preview { CorrectionPreviewScreen(initial:preview,keepBoundaries:keepBoundaries) { proposal in
                if model.applyCorrection(proposal) { self.preview=nil;didApply() }
            } }
        }
    }
    private var selectedRange:NSRange { selection.length>0 && NSMaxRange(selection)<=draft.utf16.count ? selection : NSRange(location:0,length:draft.utf16.count) }
    private func invalidate() { requestID=UUID();task?.cancel();candidates=[];definitions=[:];busy=false }
    private func replaceSelection(_ value:String,range:NSRange,using method:CorrectionMethod) {
        guard let range=Range(range,in:draft) else { return }
        draft.replaceSubrange(range,with:value);self.method=method;selection=NSRange(location:0,length:0);invalidate()
    }
    private func alternatives() {
        guard let page else { return };invalidate();busy=true;message="";drawingSelection=selectedRange
        let range=drawingSelection
        guard let stringRange=Range(range,in:draft) else { busy=false;return }
        var target=occurrence
        target.start=occurrence.start+draft[..<stringRange.lowerBound].unicodeScalars.count
        target.end=target.start+draft[stringRange].unicodeScalars.count
        let token=requestID,all=model.state.occurrences,url=model.imageURL(page)
        task=Task {
            do {
                let values=try await PhotoCorrectionService.shared.candidates(page:page,target:target,all:all,url:url)
                guard !Task.isCancelled,token==requestID else { return }
                candidates=values;busy=false
                if values.isEmpty { message="No alternatives found. You can type or draw the correction." }
                for value in values {
                    let words=await model.alternatives(value.replacement ?? value.text)
                    guard !Task.isCancelled,token==requestID else { return }
                    definitions[value.text]=words.first.map{[$0.reading,$0.definitions.first ?? ""].filter{!$0.isEmpty}.joined(separator:" · ")} ?? "No dictionary match"
                }
            } catch { if token==requestID { busy=false;message=error.localizedDescription } }
        }
    }
    private func makePreview() {
        guard beforePreview() else { return };invalidate();busy=true;message=""
        let token=requestID,value=draft
        task=Task {
            do {
                let proposed=try await model.previewCorrection(occurrence,replacement:value,method:method,keepBoundaries:keepBoundaries)
                guard !Task.isCancelled,token==requestID else { return };preview=proposed;busy=false
            } catch { if token==requestID { busy=false;message=error.localizedDescription } }
        }
    }
}
struct CorrectionPreviewScreen:View {
    @EnvironmentObject var model:ReaderModel
    @Environment(\.dismiss) private var dismiss
    @State var proposal:CorrectionPreview
    let keepBoundaries:Bool
    let apply:(CorrectionPreview)->Void
    init(initial:CorrectionPreview,keepBoundaries:Bool,apply:@escaping(CorrectionPreview)->Void) { _proposal=State(initialValue:initial);self.keepBoundaries=keepBoundaries;self.apply=apply }
    var body:some View {
        NavigationStack {
            Form {
                Section("Text correction") { Text(JapaneseText.slice(proposal.originalText,proposal.start,proposal.end)).strikethrough();Text(proposal.replacement.isEmpty ? "→ Delete the text shown above" : "→ "+proposal.replacement).font(.title2) }
                Section(keepBoundaries ? "Existing boundaries" : "Proposed nearby terms") {
                    Text("Applying uses the boundaries shown here. Checkboxes select words for collection; they do not accept or reject boundaries.").font(.caption).foregroundStyle(.secondary)
                    if proposal.manualBoundaries && !keepBoundaries { Text("This proposal replaces manually edited boundaries in the nearby span. Cancel and choose Keep existing word boundaries to preserve them.").foregroundStyle(.orange) }
                    ForEach(proposal.occurrences.indices,id:\.self) { i in
                        let item=proposal.occurrences[i]
                        let word=proposal.lexemes.first{$0.id==item.lexemeID} ?? model.state.lexemes[item.lexemeID]
                        VStack(alignment:.leading) {
                            Toggle(item.surface,isOn:$proposal.occurrences[i].selected).font(.headline)
                            Text([word?.reading ?? "",word?.definitions.first ?? "No dictionary match"].joined(separator:" · ")).font(.callout)
                            if item.manualExample==true {
                                TextField("Preserved manual example",text:$proposal.occurrences[i].sentence,axis:.vertical)
                                if !item.sentence.contains(item.surface) { Text("Include the corrected target before applying.").foregroundStyle(.red).font(.caption) }
                            } else { Text(item.sentence).font(.caption) }
                        }
                    }
                }
                Text("Only this occurrence is corrected. Existing retained cards and global knowledge are unchanged.").font(.caption)
                if let error=model.error { Text(error).foregroundStyle(.red) }
            }.navigationTitle("Preview correction").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) { Button("Apply") { apply(proposal) }.disabled(proposal.occurrences.contains{!$0.sentence.contains($0.surface)}) }
                }
        }
    }
}
private struct SelectedWordField:UIViewRepresentable {
    @Binding var text:String
    @Binding var selection:NSRange
    var onEdit:()->Void
    func makeCoordinator()->Coordinator { Coordinator(self) }
    func makeUIView(context:Context)->UITextView {
        let view=UITextView();view.delegate=context.coordinator;view.font = .preferredFont(forTextStyle:.largeTitle)
        view.adjustsFontForContentSizeCategory=true;view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius=8;view.autocorrectionType = .no;view.isScrollEnabled=true;view.accessibilityLabel="Text as printed"
        return view
    }
    func updateUIView(_ view:UITextView,context:Context) { context.coordinator.parent=self;if view.text != text { view.text=text };if view.markedTextRange==nil,NSMaxRange(selection)<=text.utf16.count,view.selectedRange != selection { view.selectedRange=selection } }
    final class Coordinator:NSObject,UITextViewDelegate {
        var parent:SelectedWordField
        init(_ parent:SelectedWordField) { self.parent=parent }
        func textViewDidChange(_ view:UITextView) { parent.text=view.text;parent.selection=view.selectedRange;parent.onEdit() }
        func textViewDidChangeSelection(_ view:UITextView) { parent.selection=view.selectedRange }
    }
}

struct SegmentedContextEditor:View {
    @EnvironmentObject var model:ReaderModel
    @Environment(\.dismiss) private var dismiss
    let occurrence:Occurrence
    let didApply:()->Void
    @State private var radius=8
    @State private var selected:Occurrence?
    @State private var draft=""
    @State private var keepBoundaries=false
    @State private var busy=false
    @State private var error=""
    @State private var preview:CorrectionPreview?
    private var page:PageCapture? { model.state.captures.first{$0.id==occurrence.captureID} }
    private var all:[Occurrence] { model.state.occurrences.filter{$0.captureID==occurrence.captureID}.sorted{$0.start<$1.start} }
    private var visible:Range<Int> { CorrectionContext.visibleRange(text:page?.text ?? "",target:occurrence,radius:Int(radius)) }
    private var shown:[Occurrence] { all.filter{$0.start<visible.upperBound && $0.end>visible.lowerBound} }
    private var dirty:Bool { selected.map{draft != $0.surface} ?? false }
    private func color(_ token:Occurrence)->Color {
        guard let item=Recommender.ranked(state:model.state,captureIDs:[occurrence.captureID]).first(where:{$0.id==token.lexemeID}) else { return .gray }
        return item.score>=0.55 ? .green : item.score>=0.3 ? .blue : .orange
    }
    var body:some View {
        NavigationStack {
            Form {
                Section("Current segmentation") {
                    Text("All parsed terms are included, even hidden or marked words. Tap a segment to edit it. Colors match the page; gray terms are filtered.").font(.caption)
                    ScrollView(.horizontal) {
                        HStack(spacing:4) {
                            ForEach(shown) { token in
                                Button {
                                    selected=token;draft=token.surface;error=""
                                } label: {
                                    Text(JapaneseText.slice(page?.text ?? "",max(token.start,visible.lowerBound),min(token.end,visible.upperBound)))
                                        .font(.title2).padding(8).background(color(token).opacity(0.2))
                                        .overlay(RoundedRectangle(cornerRadius:4).stroke(selected?.id==token.id ? Color.primary : color(token),lineWidth:selected?.id==token.id ? 3 : 1))
                                }.buttonStyle(.plain).disabled(dirty || busy).accessibilityIdentifier("context-token-\(token.start)")
                                Text("|").foregroundStyle(.secondary)
                            }
                        }
                    }
                    Text("Surrounding characters on each side").font(.caption)
                    HStack {
                        Button { radius=max(0,radius-1) } label: { Image(systemName:"minus") }
                            .accessibilityLabel("Decrease context by one character").disabled(radius<=0 || busy)
                        TextField("Characters",value:$radius,format:.number)
                            .keyboardType(.numberPad).multilineTextAlignment(.center).textFieldStyle(.roundedBorder)
                            .accessibilityLabel("Surrounding characters").disabled(busy)
                        Button { radius=min(80,radius+1) } label: { Image(systemName:"plus") }
                            .accessibilityLabel("Increase context by one character").disabled(radius>=80 || busy)
                    }.buttonStyle(.bordered)
                    .onChange(of:radius) { _,value in radius=min(80,max(0,value)) }
                }
                if let selected {
                    Section("Edit selected segment: 「\(selected.surface)」") {
                        TextField("Replacement text (empty deletes this segment)",text:$draft,axis:.vertical).font(.title2).accessibilityIdentifier("context-replacement")
                        Button("Delete 「\(selected.surface)」 from the draft",role:.destructive) { draft="" }.disabled(draft.isEmpty || busy)
                        Text("Only 「\(selected.surface)」 will be replaced. Delete its text here to remove it. No characters are chosen for deletion automatically.").font(.caption)
                        if dirty {
                            Toggle("Keep existing word boundaries",isOn:$keepBoundaries)
                            Text("Otherwise, propose new boundaries across the visible context. The preview includes whole segments at its edges.").font(.caption)
                            Button("Preview context edit") { makePreview(selected) }.disabled(busy)
                            Button("Discard draft") { draft=selected.surface }.disabled(busy)
                        }
                    }
                }
                if busy { ProgressView("Preparing preview") }
                if !error.isEmpty { Text(error).foregroundStyle(.red) }
            }.navigationTitle("See in context").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() }.disabled(dirty || busy) }
                .interactiveDismissDisabled(dirty || busy)
                .onAppear { selected=occurrence;draft=occurrence.surface }
                .sheet(isPresented:Binding(get:{preview != nil},set:{if !$0 { preview=nil }})) {
                    if let preview { CorrectionPreviewScreen(initial:preview,keepBoundaries:keepBoundaries) { proposal in
                        if model.applyCorrection(proposal) { self.preview=nil;didApply() }
                    } }
                }
        }
    }
    private func makePreview(_ target:Occurrence) {
        busy=true;error=""
        let window=CorrectionContext.parseRange(visible:visible,target:target,all:all),replacement=draft,keep=keepBoundaries
        Task {
            do { preview=try await model.previewCorrection(target,replacement:replacement,method:.typing,keepBoundaries:keep,contextWindow:window) }
            catch { self.error=error.localizedDescription }
            busy=false
        }
    }
}
