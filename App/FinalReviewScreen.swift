import SwiftUI

struct FinalReviewHub:View {
    @EnvironmentObject var model:ReaderModel
    var body:some View {
        if let id=model.finalReviewPageID {
            NavigationStack { FinalReviewScreen(pageID:id).id(id) }
        } else { PhotoReviewBacklog() }
    }
}

struct FinalReviewScreen:View {
    @EnvironmentObject var model:ReaderModel
    let pageID:String
    @State private var detail:Occurrence?
    @State private var confirmFinish=false
    @State private var stableOrder:[String]=[]
    private var page:PageCapture? { model.state.captures.first{$0.id==pageID} }
    private var all:[Recommendation] { Recommender.ranked(state:model.state,captureIDs:[pageID],showAll:true) }
    var body:some View {
        let groups=model.state.finalReview(pageID:pageID)
        VStack(spacing:0) {
            if let page {
                Text(model.state.sessions.first{$0.id==page.sessionID}?.title ?? "Page").font(.subheadline).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal)
                GeometryReader { geometry in
                    VStack(spacing:0) {
                        pane("Marked",items:sorted(groups.marked),empty:"Select a word or mark it Known or Unknown. Your marks will appear here.")
                            .frame(height:geometry.size.height/2)
                        Divider()
                        pane("Unmarked",items:sorted(groups.unmarked),empty:page.status == .ready ? "No unmarked proposals remain." : "Words will appear after this photo finishes processing.")
                            .frame(height:geometry.size.height/2)
                    }
                }
            } else { ContentUnavailableView("Photo unavailable",systemImage:"photo") }
        }
        .navigationTitle("Final review").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement:.topBarLeading) { Button { model.returnToBacklog() } label:{Image(systemName:"chevron.left")}.accessibilityLabel("Back to review backlog") }
            ToolbarItem(placement:.topBarTrailing) { Button { model.openPhoto(pageID,fromFinalReview:true) } label:{Label("Page",systemImage:"photo")} }
        }
        .safeAreaInset(edge:.bottom) {
            Button { confirmFinish=true } label:{ Text("Keep \(groups.marked.filter{$0.selected}.count) selected & finish").frame(maxWidth:.infinity) }
                .buttonStyle(.borderedProminent).padding(.horizontal).padding(.vertical,8)
                .disabled(page?.status != .ready || model.editingParse || page.map{model.state.isReviewed($0)} == true)
                .background(.regularMaterial)
        }
        .confirmationDialog("Keep selected words and finish this photo? Known and Unknown already take effect immediately.",isPresented:$confirmFinish,titleVisibility:.visible) {
            Button("Keep selected & finish") { if model.finishPhoto(pageID) { model.returnToBacklog() } }
        }
        .sheet(item:$detail) { occurrence in
            if let item=detailItem(occurrence) { WordDetail(item:item,pages:[pageID]) }
        }
        .onAppear { reconcile() }
        .onChange(of:all.map(\.id)) { _,_ in reconcile() }
    }
    private func sorted(_ items:[Recommendation])->[Recommendation] {
        let order=Dictionary(uniqueKeysWithValues:stableOrder.enumerated().map{($0.element,$0.offset)})
        return items.sorted{(order[$0.id] ?? Int.max)<(order[$1.id] ?? Int.max)}
    }
    private func reconcile() { let seen=Set(stableOrder); stableOrder += all.map(\.id).filter{!seen.contains($0)} }
    private func detailItem(_ occurrence:Occurrence)->Recommendation? {
        guard var item=all.first(where:{$0.id==occurrence.lexemeID}) else { return nil }
        item.occurrence=occurrence; return item
    }
    private func pane(_ title:String,items:[Recommendation],empty:String)->some View {
        VStack(spacing:0) {
            HStack { Text(title).font(.headline); Text("\(items.count)").foregroundStyle(.secondary); Spacer() }.padding(.horizontal).padding(.vertical,8).accessibilityAddTraits(.isHeader)
            List {
                if items.isEmpty { Text(empty).font(.callout).foregroundStyle(.secondary) }
                ForEach(items) { item in
                    FinalReviewRow(item:item,pageID:pageID,showDetail:{detail=item.occurrence})
                }
            }.listStyle(.plain)
        }
    }
}

private struct FinalReviewRow:View {
    @EnvironmentObject var model:ReaderModel
    let item:Recommendation
    let pageID:String
    let showDetail:()->Void
    private var mark:ReviewMark? { model.state.reviewMark(item.id,pageID:pageID) }
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Button(action:showDetail) {
                    VStack(alignment:.leading,spacing:4) {
                        Text(item.occurrence.surface).font(.title3.weight(.semibold))
                        Text(item.lexeme.reading).font(.subheadline).foregroundStyle(.secondary)
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }.buttonStyle(.plain)
                Menu {
                    Button(item.selected ? "Deselect" : "Select for collection") { select() }
                    Button("Known") { classify(true) }
                    Button("Unknown") { classify(false) }
                    if mark != nil { Button("Clear mark (keep knowledge state)") { model.update{$0.clearReviewMark(item.id,pageID:pageID)} } }
                    Button("View source photo") { model.openPhoto(pageID,fromFinalReview:true) }
                    Button("Word details",action:showDetail)
                } label:{ Label(label,systemImage:symbol).font(.subheadline).padding(.vertical,6) }
                .accessibilityLabel("Review mark: \(label). Actions for \(item.occurrence.surface)")
            }
            Text(item.lexeme.definitions.first ?? "No dictionary match").font(.subheadline).lineLimit(2)
        }
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
        .swipeActions(edge:.leading,allowsFullSwipe:true) { Button { select() } label:{ Label(item.selected ? "Deselect" : "Select",systemImage:"checkmark") }.tint(.green) }
        .swipeActions(edge:.trailing,allowsFullSwipe:false) {
            Button("Known") { classify(true) }.tint(.blue)
            Button("Unknown") { classify(false) }.tint(.orange)
        }
        .accessibilityAction(named:"Select or deselect") { select() }
        .accessibilityAction(named:"Known") { classify(true) }
        .accessibilityAction(named:"Unknown") { classify(false) }
    }
    private var label:String { switch mark { case .selected:"Selected"; case .known:"Known"; case .unknown:"Unknown"; case nil:"Mark" } }
    private var symbol:String { switch mark { case .selected:"checkmark.circle.fill"; case .known:"checkmark.seal"; case .unknown:"questionmark.circle"; case nil:"ellipsis.circle" } }
    private func select() { model.select(item,pages:[pageID],selected:!item.selected) }
    private func classify(_ known:Bool) { model.classify(item,known:known,pageID:pageID) }
}
