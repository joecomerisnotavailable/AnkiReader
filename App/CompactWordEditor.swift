import SwiftUI
import UIKit
import Combine

@MainActor final class EditorTextBridge:ObservableObject {
    weak var field:UITextView?
    var insertionMethod:CorrectionMethod?
    private var host:UIHostingController<InlineHandwriting>?
    private var insertion=NSRange(location:0,length:0)
    func draw() {
        guard let field else { return }
        insertion=field.selectedRange
        let target=insertion.length==0 ? "Insert at cursor" : "Replace “\((field.text as NSString).substring(with:insertion))”"
        let host=UIHostingController(rootView:InlineHandwriting(target:target,insert:{ [weak self] in self?.insert($0) },keyboard:{ [weak self] in self?.keyboard() }))
        self.host=host
        let input=UIInputView(frame:CGRect(x:0,y:0,width:field.bounds.width,height:320),inputViewStyle:.keyboard)
        host.view.translatesAutoresizingMaskIntoConstraints=false;input.addSubview(host.view)
        NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo:input.leadingAnchor),host.view.trailingAnchor.constraint(equalTo:input.trailingAnchor),host.view.topAnchor.constraint(equalTo:input.topAnchor),host.view.bottomAnchor.constraint(equalTo:input.bottomAnchor)])
        field.inputView=input;field.reloadInputViews();field.becomeFirstResponder()
    }
    func keyboard() { field?.inputView=nil;host=nil;field?.reloadInputViews();field?.becomeFirstResponder() }
    private func insert(_ text:String) {
        guard let field,let inserted=DraftInsertion.apply(text,to:field.text,selection:insertion) else { return }
        insertionMethod = .handwriting
        field.text=inserted.text
        field.selectedRange=inserted.cursor
        field.delegate?.textViewDidChange?(field);keyboard()
    }
    func close() { field?.resignFirstResponder();field?.inputView=nil;host=nil }
}
private struct InlineHandwriting:View {
    let target:String
    let insert:(String)->Void
    let keyboard:()->Void
    @StateObject private var model=HandwritingModel()
    @State private var strokes:[[InkTouch]]=[]
    var body:some View {
        VStack(spacing:4) {
            HStack { Text(target).font(.caption).lineLimit(1);Spacer();Button("Keyboard",action:keyboard) }
            if model.ready {
                InkCanvas(strokes:$strokes,onBegin:{model.cancel()},onChange:{model.changed(strokes)})
                    .background(.background).overlay(Rectangle().stroke(.secondary)).accessibilityIdentifier("compactInkCanvas").accessibilityLabel("Kanji drawing area").accessibilityValue("\(strokes.count) strokes")
                HStack {
                    Button("Undo stroke") { if !strokes.isEmpty { strokes.removeLast();model.changed(strokes) } }.disabled(strokes.isEmpty)
                    Button("Clear") { strokes=[];model.cancel() }
                    Spacer()
                    Menu { Button("Remove downloaded model",role:.destructive) { model.remove() } } label:{Image(systemName:"ellipsis.circle")}
                }
                ScrollView(.horizontal) { HStack { ForEach(Array(model.candidates.enumerated()),id:\.offset) { _,text in Button(text){insert(text)}.font(.title).buttonStyle(.bordered) } } }.frame(height:44)
            } else {
                Text("Download the Japanese handwriting model once; then draw offline.").font(.callout)
                Button(model.downloading ? "Downloading…" : "Download / retry") { model.download() }.disabled(model.downloading)
                Spacer()
            }
            if model.busy { ProgressView() }
            if !model.status.isEmpty { Text(model.status).font(.caption).lineLimit(2) }
        }.padding(8).background(.regularMaterial).onDisappear { model.cancel() }
    }
}
struct CompactWordEditor:View {
    @EnvironmentObject var model:ReaderModel
    let occurrence:Occurrence
    let close:()->Void
    let saved:()->Void
    @State private var draft:String
    @State private var selection=NSRange(location:0,length:0)
    @StateObject private var bridge=EditorTextBridge()
    @State private var method=CorrectionMethod.typing
    @State private var candidates:[PhotoCorrectionCandidate]=[]
    @State private var message=""
    @State private var loading=false
    @State private var generation=UUID()
    @State private var task:Task<Void,Never>?
    @State private var candidateRange=NSRange(location:0,length:0)
    init(occurrence:Occurrence,close:@escaping()->Void,saved:@escaping()->Void) { self.occurrence=occurrence;self.close=close;self.saved=saved;_draft=State(initialValue:occurrence.surface) }
    var body:some View {
        VStack(spacing:8) {
            Capsule().fill(.secondary).frame(width:36,height:4).padding(.top,5)
                .frame(maxWidth:.infinity,minHeight:24).contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:12).onEnded{if $0.translation.height>35 { cancel() }})
            HStack {
                Button("Cancel") { cancel() }.disabled(model.editingParse)
                Spacer();Text("Edit text").font(.caption);Spacer()
                Button("Keep") { keep() }.fontWeight(.semibold).disabled(model.editingParse)
            }
            HStack(alignment:.center) {
                CompactTextField(text:$draft,selection:$selection,method:$method,bridge:bridge).frame(height:62)
                Button { invalidate();bridge.draw() } label:{Image(systemName:"pencil.tip.crop.circle").font(.title2)}.accessibilityLabel("Draw character")
                Button { alternatives() } label:{Image(systemName:"text.viewfinder").font(.title2)}.accessibilityLabel("Character alternatives").disabled(loading || draft != occurrence.surface)
            }.disabled(model.editingParse)
            if loading { HStack { ProgressView();Button("Cancel lookup"){invalidate()} } }
            if !candidates.isEmpty {
                ScrollView(.horizontal) { HStack { ForEach(candidates.filter{$0.replacement != nil}) { item in
                    Button {
                        if let value=item.replacement,let inserted=DraftInsertion.apply(value,to:draft,selection:candidateRange) {
                            draft=inserted.text;selection=inserted.cursor
                        }
                        method = .photo;invalidate()
                    } label: {
                        VStack { Text(item.replacement ?? item.text).font(.title2)
                        }
                    }.buttonStyle(.bordered).accessibilityIdentifier("alternative-"+(item.replacement ?? item.text))
                } }.frame(minHeight:52,maxHeight:80) }
            }
            if !message.isEmpty { Text(message).font(.caption) }
            if let error=model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(.horizontal,12).padding(.bottom,8).background(.regularMaterial,in:UnevenRoundedRectangle(topLeadingRadius:16,topTrailingRadius:16))
            .onChange(of:draft){_,_ in invalidate()}.onChange(of:selection){_,_ in if bridge.field?.isFirstResponder == true && (loading || !candidates.isEmpty) {invalidate()} }
            .onDisappear { invalidate();bridge.close() }
    }
    private func invalidate() { generation=UUID();task?.cancel();loading=false;candidates=[] }
    private func cancel() { guard !model.editingParse else { return };bridge.close();invalidate();close() }
    private func keep() {
        invalidate();bridge.close()
        Task { if await model.editPage(occurrence.captureID,command:.replace(occurrence.id,draft,method)) { saved() } }
    }
    private func alternatives() {
        guard let page=model.state.captures.first(where:{$0.id==occurrence.captureID}) else { return }
        bridge.close()
        invalidate();message="";loading=true
        candidateRange=selection.length>0 ? selection : NSRange(location:0,length:draft.utf16.count)
        guard let r=Range(candidateRange,in:draft) else { loading=false;return }
        var target=occurrence;target.start += draft[..<r.lowerBound].unicodeScalars.count;target.end=target.start+draft[r].unicodeScalars.count
        let token=generation,all=model.state.occurrences,url=model.imageURL(page)
        task=Task {
            do {
                let values=try await PhotoCorrectionService.shared.candidates(page:page,target:target,all:all,url:url)
                guard token==generation,!Task.isCancelled else { return }
                candidates=values;loading=false
                if values.isEmpty { message="No different character candidates found. Select a character to retry, or type/draw it." }
            } catch { if token==generation { loading=false;message=error.localizedDescription } }
        }
    }
}
private struct CompactTextField:UIViewRepresentable {
    @Binding var text:String
    @Binding var selection:NSRange
    @Binding var method:CorrectionMethod
    let bridge:EditorTextBridge
    func makeCoordinator()->Coordinator { Coordinator(self) }
    func makeUIView(context:Context)->UITextView {
        let view=UITextView();view.font = .preferredFont(forTextStyle:.largeTitle);view.adjustsFontForContentSizeCategory=true;view.backgroundColor = .secondarySystemBackground
        view.layer.cornerRadius=8;view.autocorrectionType = .no;view.delegate=context.coordinator;view.text=text;view.accessibilityIdentifier="compact-edit-text"
        bridge.field=view
        DispatchQueue.main.async { view.becomeFirstResponder() }
        return view
    }
    func updateUIView(_ view:UITextView,context:Context) { context.coordinator.parent=self;if view.text != text { view.text=text };bridge.field=view }
    static func dismantleUIView(_ view:UITextView,coordinator:Coordinator) { view.resignFirstResponder() }
    final class Coordinator:NSObject,UITextViewDelegate {
        var parent:CompactTextField
        init(_ parent:CompactTextField){self.parent=parent}
        func textViewDidChange(_ view:UITextView){parent.method=parent.bridge.insertionMethod ?? .typing;parent.bridge.insertionMethod=nil;parent.text=view.text;parent.selection=view.selectedRange}
        func textViewDidChangeSelection(_ view:UITextView){parent.selection=view.selectedRange}
    }
}
