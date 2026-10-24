import SwiftUI

struct PhotoPageScreen: View {
    @EnvironmentObject var model:ReaderModel
    let pageID:String
    @StateObject private var coordinator=PhotoPageCoordinator()
    @State private var editPage=false
    @State private var dragMessage:String?
    @State private var standardRowHeight:CGFloat=110
    private var page:PageCapture? { model.state.captures.first{$0.id==pageID} }
    private var occurrences:[Occurrence] { model.state.occurrences.filter{$0.captureID==pageID}.sorted{$0.start<$1.start} }
    private var recommendations:[Recommendation] { Recommender.ranked(state:model.state,captureIDs:[pageID],showAll:coordinator.showAll) }
    private var ordered:[Recommendation] {
        let values=recommendations
        if coordinator.pageOrder { return values.sorted{$0.occurrence.start<$1.occurrence.start} }
        let order=Dictionary(uniqueKeysWithValues:coordinator.stableOrder.enumerated().map{($0.element,$0.offset)})
        return values.sorted { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
    }
    var body:some View {
        VStack(spacing:0) {
            if let page {
                let items=ordered
                let allRegions=TermGeometry.regions(page:page,occurrences:occurrences)
                let grid=coordinator.textGrid ? TextGridLayout.make(page:page,occurrences:occurrences) : nil
                // Proposal filters affect the list, never the editable page parse.
                let visibleIDs=Set(occurrences.map(\.id))
                let scoreByLexeme=Dictionary(uniqueKeysWithValues:items.map{($0.id,$0.score)})
                let scores=Dictionary(uniqueKeysWithValues:occurrences.map{($0.id,scoreByLexeme[$0.lexemeID] ?? -1)})
                GeometryReader { geo in
                    VStack(spacing:0) {
                        VStack(spacing:0) {
                          ZStack {
                            if page.photoRemoved == true { ContentUnavailableView("Photo removed",systemImage:"photo",description:Text("The recognized text and vocabulary are still available.")) }
                            if page.photoRemoved != true || coordinator.textGrid { ZoomablePage(url:model.imageURL(page),grid:grid,regions:allRegions,occurrences:occurrences,visibleIDs:visibleIDs,scores:scores,page:coordinator) }
                            if page.status != .ready {
                                VStack { Spacer(); Text(page.status == .failed ? "Recognition failed · Retry in menu" : "Photo saved · finding words…").font(.callout).padding(12).background(.regularMaterial,in:Capsule()).padding() }
                            }
                          }
                          Button { coordinator.textGrid.toggle() } label:{ Label(coordinator.textGrid ? "Show photo" : "Show text grid",systemImage:coordinator.textGrid ? "photo" : "character.textbox").font(.callout).frame(maxWidth:.infinity).padding(.vertical,8) }.background(.bar)
                        }.frame(height:coordinator.wordsOnly ? 0 : max(0,geo.size.height-paneHeight(geo.size.height))).clipped().accessibilityHidden(coordinator.wordsOnly)
                        if !coordinator.wordsOnly { Divider() }
                        wordList(items:items,regions:grid?.regions ?? allRegions)
                            .frame(height:coordinator.wordsOnly ? geo.size.height : paneHeight(geo.size.height))
                    }
                }
                if model.editingParse { ProgressView("Updating terms…").font(.caption).padding(4) }
            } else { ContentUnavailableView("Photo unavailable",systemImage:"photo") }
        }
        .background(.background)
        .navigationTitle(page.map { capture in model.state.sessions.first{$0.id==capture.sessionID}?.title ?? "Page" } ?? "Page")
        .navigationBarTitleDisplayMode(.inline).navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement:.topBarLeading) { Button { model.leavePhoto(pageID) } label:{ Image(systemName:"chevron.left") }.accessibilityLabel(model.photoReturnsToFinalReview ? "Back to final review" : "Back to camera") }
            ToolbarItem(placement:.topBarTrailing) { pageMenu }
        }
        .onAppear { installCallbacks(); reconcileOrder(reset:true) }
        .onChange(of:recommendations.map(\.id)) { _,_ in reconcileOrder() }
        .onChange(of:page?.textRevision) { _,_ in
            if let edit=page?.corrections?.last,let target=occurrences.first(where:{$0.start<=edit.start && $0.end>edit.start}) {
                coordinator.photoTap(target)
            }
        }
        .onChange(of:coordinator.showAll) { _,_ in reconcileOrder() }
        .alert("Terms could not be joined",isPresented:Binding(get:{dragMessage != nil},set:{if !$0 { dragMessage=nil }})) { Button("OK",role:.cancel) {} } message:{ Text(dragMessage ?? "") }
        .sheet(isPresented:$editPage) { if let page { PageTextEditor(page:page) } }
        .sheet(item:$coordinator.splitOccurrence) { occurrence in if let page { TermSplitPopup(page:page,occurrence:occurrence).presentationDetents([.medium,.large]) } }
        .sheet(item:$coordinator.detailOccurrence) { occurrence in
            if let item=detailRecommendation(occurrence) { WordDetail(item:item,pages:[pageID]) }
        }
    }
    private func paneHeight(_ available:CGFloat)->CGFloat { min(available*0.65,standardRowHeight*1.25) }
    private var pageMenu:some View {
        Menu {
            Picker("Sort",selection:$coordinator.pageOrder) { Text("Recommended").tag(false); Text("Page order").tag(true) }
            Toggle("Show all words",isOn:$coordinator.showAll)
            Toggle("Words only",isOn:$coordinator.wordsOnly)
            Button("Reset zoom",systemImage:"arrow.up.left.and.arrow.down.right") { coordinator.resetRequest += 1 }
            Button("Edit page text",systemImage:"pencil") { editPage=true }.disabled(page?.status != .ready || model.editingParse)
            if page?.status == .failed { Button("Retry recognition") { model.retry(pageID) } }
            if model.correctionUndo?.page.id==pageID { Button("Undo text correction",systemImage:"arrow.uturn.backward") { model.undoCorrection() }.disabled(model.editingParse) }
            if model.parseUndo?.pageID==pageID { Button("Undo parse edit",systemImage:"arrow.uturn.backward") { model.undoParse() }.disabled(model.editingParse) }
            Divider()
            Button("Previous pending photo",systemImage:"chevron.backward") { move(-1) }.disabled(adjacent(-1)==nil)
            Button("Next pending photo",systemImage:"chevron.forward") { move(1) }.disabled(adjacent(1)==nil)
            Button("Review backlog",systemImage:"rectangle.stack") { model.returnToBacklog() }
            Button("Final review",systemImage:"checklist") { model.openFinalReview(pageID) }
            if model.photoReturnsToFinalReview { Button("Back to camera",systemImage:"camera") { model.returnToCamera() } }
        } label:{ Image(systemName:"ellipsis.circle").font(.title3) }.accessibilityLabel("Page actions")
    }
    private func wordList(items:[Recommendation],regions:[TermRegion])->some View {
        ScrollViewReader { reader in
            List {
                if items.isEmpty {
                    Text(page?.status == .ready ? "No proposed words. Use Show all words in the menu to inspect this page." : "Vocabulary will appear here.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(items) { item in
                    let occurrence=coordinator.focus(in:occurrences,lexemeID:item.id) ?? item.occurrence
                    InteractivePhotoWordRow(item:item,occurrence:occurrence,pageID:pageID,locationAvailable:regions.contains{$0.occurrenceID==occurrence.id},coordinator:coordinator)
                        .id(item.id)
                }
            }.listStyle(.plain)
                .onChange(of:coordinator.scrollRequest) { _,_ in
                    if let id=coordinator.scrollWordID { withAnimation(.easeOut(duration:0.18)) { reader.scrollTo(id,anchor:.top) } }
                }
                .background(alignment:.top) {
                    if let item=items.first {
                        PhotoWordRow(item:item,occurrence:item.occurrence,locationAvailable:true)
                            .padding(.horizontal,16).padding(.vertical,8)
                            .background(GeometryReader { geometry in Color.clear.preference(key:RowHeightPreference.self,value:geometry.size.height) })
                            .hidden().accessibilityHidden(true)
                    }
                }
                .onPreferenceChange(RowHeightPreference.self) { value in if value>0 { standardRowHeight=value } }
        }
    }
    private func installCallbacks() {
        coordinator.onTap = { [weak coordinator, weak model] id in if let occurrence=model?.state.occurrences.first(where:{$0.id==id}) { coordinator?.photoTap(occurrence) } }
        coordinator.onSplit = { [weak coordinator, weak model] id in if let model, !model.editingParse { coordinator?.splitOccurrence=model.state.occurrences.first{$0.id==id} } }
        coordinator.onInvalidDrop = { source,target in
            guard let a=occurrences.first(where:{$0.id==source}) else { return }
            if let target,let b=occurrences.first(where:{$0.id==target}),a.id != b.id {
                let between=occurrences.filter{$0.start>=min(a.end,b.end) && $0.end<=max(a.start,b.start)}.map(\.surface).joined(separator:" · ")
                dragMessage=between.isEmpty ? "Hold, then drag onto the preceding or following term." : "The saved text has ‘\(between)’ between these terms. Open word details and choose See in context to inspect and edit the saved segmentation. No intervening text is skipped automatically."
            } else { dragMessage="Hold, then drag onto the preceding or following term. Release over its highlight to join." }
        }
        coordinator.onMerge = { [weak model] first,second in Task { await model?.merge(first,second) } }
    }
    private func reconcileOrder(reset:Bool=false) {
        let ranked=recommendations.map(\.id)
        if reset { coordinator.stableOrder=ranked }
        else { let seen=Set(coordinator.stableOrder); coordinator.stableOrder += ranked.filter{!seen.contains($0)} }
    }
    private func adjacent(_ offset:Int)->String? {
        let pending=model.pendingPhotos
        guard let i=pending.firstIndex(where:{$0.id==pageID}),pending.indices.contains(i+offset) else { return nil }
        return pending[i+offset].id
    }
    private func move(_ offset:Int) { if let id=adjacent(offset) { model.openPhoto(id,fromFinalReview:model.photoReturnsToFinalReview) } }
    private func detailRecommendation(_ occurrence:Occurrence)->Recommendation? {
        guard var item=Recommender.ranked(state:model.state,captureIDs:[pageID],showAll:true).first(where:{$0.id==occurrence.lexemeID}) else { return nil }
        item.occurrence=model.state.occurrences.first{$0.id==occurrence.id} ?? occurrence; return item
    }
}
private struct RowHeightPreference:PreferenceKey {
    static var defaultValue:CGFloat=0
    static func reduce(value:inout CGFloat,nextValue:()->CGFloat) { value=max(value,nextValue()) }
}
struct PhotoWordRow:View {
    let item:Recommendation
    let occurrence:Occurrence
    let locationAvailable:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:4) {
            HStack(alignment:.firstTextBaseline) {
                Text(occurrence.surface).font(.title3.weight(.semibold))
                Text(item.lexeme.reading).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength:4)
                if item.selected { Image(systemName:"checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Selected") }
            }
            if occurrence.surface != item.lexeme.expression { Text("Dictionary: \(item.lexeme.expression)").font(.caption).foregroundStyle(.secondary) }
            Text(item.lexeme.definitions.first ?? "No dictionary match").font(.subheadline).lineLimit(2,reservesSpace:true)
            Text(locationAvailable ? (item.reasons.isEmpty ? (item.secondary ? "Check reading or meaning" : " ") : item.reasons.joined(separator:" · ")) : "Photo location unavailable")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            OccurrenceCorrectionBadge(occurrence:occurrence)
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
}

struct PhotoReviewBacklog:View {
    @EnvironmentObject var model:ReaderModel
    var body:some View {
        NavigationStack {
            List {
                if model.pendingPhotos.isEmpty { ContentUnavailableView("Nothing waiting",systemImage:"checkmark.circle",description:Text("Capture a page while reading. Each photo will appear here.")) }
                ForEach(model.state.sessions.filter { session in model.pendingPhotos.contains{$0.sessionID==session.id} }) { session in
                    Section(session.title) {
                        ForEach(model.pendingPhotos.filter{$0.sessionID==session.id}) { page in
                            Button { model.openFinalReview(page.id) } label:{
                                HStack(spacing:12) {
                                    if let image=UIImage(contentsOfFile:model.imageURL(page).path) { Image(uiImage:image).resizable().scaledToFill().frame(width:56,height:78).clipped().clipShape(RoundedRectangle(cornerRadius:6)) }
                                    else { Image(systemName:"photo").frame(width:56,height:78) }
                                    VStack(alignment:.leading,spacing:5) {
                                        Text(page.created.formatted(date:.abbreviated,time:.shortened)).font(.headline)
                                        Text(page.status == .ready ? "\(model.state.occurrences.filter{$0.captureID==page.id && $0.selected}.count) selected · pending review" : page.status.rawValue).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(); Image(systemName:"chevron.right").font(.caption)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.navigationTitle("Review")
        }
    }
}

private struct InteractivePhotoWordRow:View {
    @EnvironmentObject var model:ReaderModel
    let item:Recommendation
    let occurrence:Occurrence
    let pageID:String
    let locationAvailable:Bool
    @ObservedObject var coordinator:PhotoPageCoordinator
    var body:some View {
        PhotoWordRow(item:item,occurrence:occurrence,locationAvailable:locationAvailable)
            .accessibilityElement(children:.combine)
            .contentShape(Rectangle())
            .simultaneousGesture(LongPressGesture(minimumDuration:0.35).exclusively(before:TapGesture()).onEnded { value in
                switch value {
                case .first: coordinator.detailOccurrence=occurrence
                case .second: coordinator.rowTap(occurrence)
                }
            })
            .swipeActions(edge:.leading,allowsFullSwipe:true) {
                Button { toggle() } label: { Label(item.selected ? "Deselect" : "Select",systemImage:item.selected ? "minus.circle" : "checkmark") }.tint(.green)
            }
            .swipeActions(edge:.trailing,allowsFullSwipe:false) {
                Button("Known") { model.classify(item,known:true,pageID:pageID) }.tint(.blue)
                Button("Unknown") { model.classify(item,known:false,pageID:pageID) }.tint(.orange)
            }
            .accessibilityAction(named:"Open word details") { coordinator.detailOccurrence=occurrence }
            .accessibilityAction(named:Text(item.selected ? "Deselect" : "Select")) { toggle() }
            .accessibilityAction(named:"Known") { model.classify(item,known:true,pageID:pageID) }
            .accessibilityAction(named:"Unknown") { model.classify(item,known:false,pageID:pageID) }
            .listRowInsets(EdgeInsets(top:8,leading:16,bottom:8,trailing:16))
            .listRowBackground(coordinator.activeOccurrenceID==occurrence.id ? Color.accentColor.opacity(0.08) : Color.clear)
    }
    private func toggle() { var focused=item; focused.occurrence=occurrence; model.select(focused,pages:[pageID],selected:!item.selected) }
}
