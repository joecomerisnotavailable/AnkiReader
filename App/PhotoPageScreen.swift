import SwiftUI

struct PhotoPageScreen: View {
    @EnvironmentObject var model:ReaderModel
    let pageID:String
    @StateObject private var coordinator=PhotoPageCoordinator()
    @State private var dragMessage:String?
    @State private var standardRowHeight:CGFloat=110
    private var page:PageCapture? { model.state.captures.first{$0.id==pageID} }
    private var occurrences:[Occurrence] { model.state.occurrences.filter{$0.captureID==pageID}.sorted{$0.start<$1.start} }
    private var recommendations:[Recommendation] { Recommender.ranked(state:model.state,captureIDs:[pageID],showAll:coordinator.showAll) }
    private var ordered:[Recommendation] {
        var values=recommendations
        if let active=occurrences.first(where:{$0.id==coordinator.activeOccurrenceID}),!values.contains(where:{$0.id==active.lexemeID}),var item=Recommender.ranked(state:model.state,captureIDs:[pageID],showAll:true).first(where:{$0.id==active.lexemeID}) { item.occurrence=active;values.insert(item,at:0) }
        if coordinator.pageOrder { return values.sorted{$0.occurrence.start<$1.occurrence.start} }
        let order=Dictionary(uniqueKeysWithValues:coordinator.stableOrder.enumerated().map{($0.element,$0.offset)})
        return values.sorted { (order[$0.id] ?? Int.max) < (order[$1.id] ?? Int.max) }
    }
    var body:some View {
        observedContent
        .background(.background)
        .navigationTitle(page.map { capture in model.state.sessions.first{$0.id==capture.sessionID}?.title ?? "Page" } ?? "Page")
        .navigationBarTitleDisplayMode(.inline).navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement:.topBarLeading) { Button { model.leavePhoto(pageID) } label:{ Image(systemName:"chevron.left") }.accessibilityLabel(model.photoReturnsToFinalReview ? "Back to final review" : "Back to camera") }
            ToolbarItem(placement:.topBarTrailing) { pageMenu }
        }
        .alert("Terms could not be joined",isPresented:Binding(get:{dragMessage != nil},set:{if !$0 { dragMessage=nil }})) { Button("OK",role:.cancel) {} } message:{ Text(dragMessage ?? "") }
        .overlay(alignment:.bottom) { editorOverlay }
        .onReceive(NotificationCenter.default.publisher(for:UIResponder.keyboardDidShowNotification)) { _ in if coordinator.editorOccurrence != nil { coordinator.editFocusRequest += 1 } }
        .onDisappear { coordinator.stopEditing();coordinator.joinRange=nil;coordinator.dragSession.cancel() }
        .sheet(item:$coordinator.detailOccurrence) { occurrence in
            if let item=detailRecommendation(occurrence) { WordDetail(item:item,pages:[pageID]) }
        }
    }
    @ViewBuilder private var editorOverlay:some View {
            if let occurrence=coordinator.editorOccurrence {
                CompactWordEditor(occurrence:occurrence,close:{coordinator.stopEditing()},saved:{coordinator.stopEditing();coordinator.undoNotice=true}).id(occurrence.id)
            } else if coordinator.undoNotice {
                HStack { Text("Edit saved");Button("Undo") { model.undoPageEdit(pageID);coordinator.undoNotice=false };Button {coordinator.undoNotice=false} label:{Image(systemName:"xmark")} }
                    .padding(10).background(.regularMaterial,in:Capsule()).padding(.bottom,8)
            }
    }
    private var observedContent:some View {
        pageContent
        .onAppear { model.preparePageEditing(pageID);installCallbacks();reconcileOrder(reset:true);openRequestedEditor() }
        .onChange(of:page?.status) { _,status in if status == .ready { model.preparePageEditing(pageID) } }
        .onChange(of:model.pendingPageEditorID) { _,_ in openRequestedEditor() }
        .onChange(of:recommendations.map(\.id)) { _,_ in reconcileOrder() }
        .onChange(of:page?.textRevision) { _,_ in
            let offset=model.lastPageEditStart[pageID] ?? page?.corrections?.last?.start ?? 0
            if let target=occurrences.first(where:{$0.start<=offset && $0.end>offset}) ?? occurrences.last {
                coordinator.photoTap(target)
                coordinator.undoNotice = !(model.pageEditHistory[pageID] ?? []).isEmpty
            }
        }
        .onChange(of:coordinator.showAll) { _,_ in reconcileOrder() }
    }
    private var pageContent:some View {
        VStack(spacing:0) {
            if let page {
                let items=ordered
                let allRegions=TermGeometry.regions(page:page,occurrences:occurrences)
                // Proposal filters affect the list, never the editable page parse.
                let scoreByLexeme=Dictionary(uniqueKeysWithValues:recommendations.map{($0.id,$0.score)})
                let scores=Dictionary(uniqueKeysWithValues:occurrences.map{($0.id,scoreByLexeme[$0.lexemeID] ?? -1)})
                pageLayout(page:page,items:items,regions:allRegions,scores:scores)
                if model.editingParse { ProgressView("Updating terms…").font(.caption).padding(4) }
            } else { ContentUnavailableView("Photo unavailable",systemImage:"photo") }
        }
    }
    private func pageLayout(page:PageCapture,items:[Recommendation],regions:[TermRegion],scores:[String:Double])->some View {
                GeometryReader { geo in
                    let lower=min(geo.size.height*0.60,standardRowHeight*2.25)
                    let contextHeight=lower/2.25
                    VStack(spacing:0) {
                        ZStack {
                            if page.photoRemoved == true { ContentUnavailableView("Photo removed",systemImage:"photo",description:Text("The recognized text and vocabulary are still available.")) }
                            else { ZoomablePage(url:model.imageURL(page),regions:regions,occurrences:occurrences,visibleIDs:Set(occurrences.map(\.id)),scores:scores,page:coordinator) }
                            if page.status != .ready { VStack { Spacer();Text(page.status == .failed ? "Recognition failed · Retry in menu" : "Photo saved · finding words…").font(.callout).padding(12).background(.regularMaterial,in:Capsule()).padding() } }
                        }.frame(height:coordinator.wordsOnly ? 0 : max(0,geo.size.height-lower)).clipped().accessibilityHidden(coordinator.wordsOnly)
                        if !coordinator.wordsOnly {
                            Divider()
                            VStack(spacing:0) {
                                if let range=coordinator.joinRange {
                                    HStack {
                                        Button("Cancel join") { coordinator.joinRange=nil;coordinator.interaction = .browsing }
                                        Text(JapaneseText.slice(page.text,range.lowerBound,range.upperBound)).lineLimit(1).font(.caption)
                                        Spacer()
                                        Button("Confirm join") { apply(.join(range)) }.disabled(model.editingParse)
                                    }.padding(.horizontal,8)
                                }
                                ContextStrip(text:page.text,occurrences:occurrences,scores:scores,page:coordinator,annotations:contextAnnotations(page),suggestions:model.parsingSuggestions[pageID] ?? [],suggestionAction:{ suggestion,accept in if accept { Task { await model.acceptParsing(suggestion,pageID:pageID) } } else { model.dismissParsing(suggestion,pageID:pageID) } },disabled:model.editingParse,action:contextAction).padding(.top,-100)
                            }.frame(height:contextHeight).zIndex(2)
                            Divider()
                        }
                        wordList(items:items,regions:regions).frame(height:coordinator.wordsOnly ? geo.size.height : lower-contextHeight)
                    }
                }
    }
    private var pageMenu:some View {
        Menu {
            Picker("Sort",selection:$coordinator.pageOrder) { Text("Recommended").tag(false); Text("Page order").tag(true) }
            Toggle("Show all words",isOn:$coordinator.showAll)
            Toggle("Words only",isOn:$coordinator.wordsOnly)
            Button("Repair column order",systemImage:"text.line.first.and.arrowtriangle.forward") { model.repairPageOrder(pageID) }.disabled(model.editingParse)
            if model.state.canRefineCapture(pageID) {
                Button("Refine printed text",systemImage:"viewfinder") { Task {await model.refineSavedCapture(pageID,occurrenceID:coordinator.activeOccurrenceID)} }.disabled(model.editingParse)
            }
            Button("Reset zoom",systemImage:"arrow.up.left.and.arrow.down.right") { coordinator.resetRequest += 1 }
            if page?.status == .failed { Button("Retry recognition") { model.retry(pageID) } }
            if !(model.pageEditHistory[pageID] ?? []).isEmpty { Button("Undo last edit",systemImage:"arrow.uturn.backward") { model.undoPageEdit(pageID) }.disabled(model.editingParse) }
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
        coordinator.onSplit = { [weak coordinator, weak model] id in if let model, !model.editingParse { if let item=model.state.occurrences.first(where:{$0.id==id}) { coordinator?.startEditing(item) } } }
        coordinator.onInvalidDrop = { source,target in
            guard let a=occurrences.first(where:{$0.id==source}) else { return }
            if let target,let b=occurrences.first(where:{$0.id==target}),a.id != b.id {
                let between=occurrences.filter{$0.start>=min(a.end,b.end) && $0.end<=max(a.start,b.start)}.map(\.surface).joined(separator:" · ")
                dragMessage=between.isEmpty ? "Hold, then drag onto the preceding or following term." : "The saved text has ‘\(between)’ between these terms. Inspect the context strip to edit or discard that text explicitly. No intervening text is skipped automatically."
            } else { dragMessage="Hold, then drag onto the preceding or following term. Release over its highlight to join." }
        }
        coordinator.onOutsideTap = { [weak coordinator,weak model] in if model?.editingParse != true { coordinator?.stopEditing() } }
        coordinator.onMerge = { [weak model] first,second in Task { await model?.merge(first,second) } }
    }
    private func contextAnnotations(_ page:PageCapture)->[String:String] {
        Dictionary(uniqueKeysWithValues:occurrences.compactMap { item in
            let changes=CorrectionMapping.history(item,page:page)
            guard let change=changes.last else { return item.corrected ? (item.id,"Previously edited") : nil }
            return (item.id,"\(change.before.isEmpty ? "∅" : change.before) → \(change.after.isEmpty ? "∅" : change.after)\(changes.count>1 ? " +\(changes.count-1)" : "")")
        })
    }
    private func contextAction(_ name:String,_ item:Occurrence) {
        guard !model.editingParse else { return }
        coordinator.photoTap(item)
        switch name {
        case "Edit":coordinator.startEditing(item)
        case "Join":coordinator.joinRange=item.start..<item.end;coordinator.interaction = .joining
        case "Shatter":apply(.shatter(item.id))
        case "Discard":apply(.replace(item.id,"",.typing))
        default:
            if name.hasPrefix("Merge:"),let other=occurrences.first(where:{$0.id==String(name.dropFirst(6))}),let range=try? ParseGesture.mergeRange(item,other,in:occurrences) { apply(.join(range)) }
        }
    }
    private func apply(_ command:PageEditCommand) {
        Task { if await model.editPage(pageID,command:command) { coordinator.joinRange=nil;coordinator.interaction = .browsing;coordinator.undoNotice=true } }
    }
    private func openRequestedEditor() {
        guard let id=model.pendingPageEditorID,let item=occurrences.first(where:{$0.id==id}) else { return }
        model.pendingPageEditorID=nil
        DispatchQueue.main.asyncAfter(deadline:.now()+0.3) { coordinator.startEditing(item) }
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
                Text(item.lexeme.expression).font(.title3.weight(.semibold))
                Text(item.lexeme.reading).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength:4)
                if item.selected { Image(systemName:"checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Selected") }
            }
            if occurrence.surface != item.lexeme.expression { Text("On page: \(occurrence.surface)").font(.caption).foregroundStyle(.secondary) }
            PitchAccentView(word:item.lexeme)
            Text(item.lexeme.definitions.first ?? "No dictionary match").font(.subheadline).lineLimit(2,reservesSpace:true)
            Text(locationAvailable ? (item.reasons.isEmpty ? (item.secondary ? "Check reading or meaning" : " ") : item.reasons.joined(separator:" · ")) : "Photo location unavailable")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if occurrence.needsExampleRepair { Label("Example needs repair",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
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
                case .first: if coordinator.interaction != .editing { coordinator.detailOccurrence=occurrence }
                case .second: if coordinator.interaction == .editing { coordinator.stopEditing() } else { coordinator.rowTap(occurrence) }
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
