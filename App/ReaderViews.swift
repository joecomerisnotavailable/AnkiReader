import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct ReaderHome: View {
    @EnvironmentObject var model: ReaderModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView(selection:$model.selectedTab) {
            CaptureScreen().tabItem { Label("Read", systemImage: "camera") }.tag(0)
            FinalReviewHub().tabItem { Label("Review", systemImage: "checklist") }.badge(model.pendingPhotos.count).tag(1)
            LibraryScreen().tabItem { Label("Library", systemImage: "books.vertical") }.tag(2)
        }
        .tint(Color(red: 0.18, green: 0.40, blue: 0.31))
        .safeAreaInset(edge: .top) {
            if model.undoKnown != nil {
                HStack { Text("Vocabulary knowledge updated").font(.caption); Spacer(); Button("Undo") { model.undoKnowledge() }; Button { model.undoKnown = nil } label: { Image(systemName: "xmark") } }.padding(10).background(.regularMaterial)
            }
        }
        .alert("Could not complete action", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("OK") { model.error = nil } } message: { Text(model.error ?? "") }
        .task { await model.resume() }
        .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await model.resume() } } }
    }
}

struct CaptureScreen: View {
    @EnvironmentObject var model: ReaderModel
    @Environment(\.scenePhase) private var phase
    @State private var visible = false
    @State private var photo: PhotosPickerItem?
    @State private var layout: PageLayout = .vertical
    @State private var automatic = true
    @State private var source = ""
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let id = model.activeCaptureID, let page = model.state.captures.first(where: { $0.id == id }) {
                    PhotoPageScreen(pageID: page.id).id(page.id)
                } else {
                    if visible && phase == .active && model.selectedTab == 0 {
                        ReadingCamera(automatic: automatic, captured: { model.capture($0, layout: layout) }, failed: { model.error = $0 })
                    } else { Color.black }
                    VStack(spacing: 8) {
                        HStack {
                            Picker("Layout", selection: $layout) { ForEach(PageLayout.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                            PhotosPicker(selection: $photo, matching: .images) { Image(systemName: "photo.on.rectangle").font(.title2) }.accessibilityLabel("Import page photo")
                        }
                        HStack {
                            TextField("Book or source (optional)", text: $source).onSubmit { model.setSource(source) }
                            Toggle("Auto", isOn: $automatic).fixedSize()
                        }
                    }.padding()
                }
            }
            .navigationTitle(model.activeCaptureID == nil ? "Read" : "Page").navigationBarTitleDisplayMode(.inline)
            .toolbar(model.activeCaptureID == nil ? .visible : .hidden, for: .tabBar)
            .onAppear { source = model.state.lastSource; visible = true }
            .onDisappear { visible = false }
            .onChange(of: source) { _, value in model.setSource(value) }
            .onChange(of: photo) { _, value in Task {
                do { if let data = try await value?.loadTransferable(type: Data.self) { model.capture(data, layout: layout) } }
                catch { model.error = error.localizedDescription }
            } }
        }
    }
}

struct CaptureDetail: View {
    let pageID: String
    var body: some View { PhotoPageScreen(pageID:pageID).id(pageID) }
}

struct WordDetail: View {
    @EnvironmentObject var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    let item: Recommendation
    let pages: Set<String>
    @State private var correction=false
    @State private var correctionDirty=false
    @State private var confirmCorrectionLeave=false
    @State private var cuts=false
    @State private var dictionary=false
    @State private var expand=false
    @State private var confirmLeave=false
    @State private var context:ExampleContext?
    @State private var savedContext:ExampleContext?
    private var occurrence:Occurrence { model.state.occurrences.first{$0.id==item.occurrence.id} ?? item.occurrence }
    private var sourcePage:PageCapture? { model.state.captures.first{$0.id==occurrence.captureID} }
    private var dirty:Bool { context != savedContext }
    private var valid:Bool { context?.draft.contains(occurrence.surface) == true }
    var body:some View {
        NavigationStack {
            List {
                Section {
                    Text(occurrence.surface).font(.largeTitle)
                    Button("Edit on page") { if saveIfNeeded() { dismiss();model.openPageEditor(occurrence) } }
                    OccurrenceCorrectionBadge(occurrence:occurrence)
                    Text(item.lexeme.reading).font(.title3)
                    ForEach(Array(item.lexeme.definitions.enumerated()),id:\.offset) { _,definition in Text(definition) }
                }
                if let page=sourcePage, context != nil {
                    Section("Example") {
                        TextField("Example",text:Binding(get:{context?.draft ?? ""},set:{context?.draft=$0}),axis:.vertical).lineLimit(3...12)
                        if !valid { Text("Keep the target word in the example.").font(.caption).foregroundStyle(.red) }
                        if ExampleContext.isFragment(text:page.text,start:context?.start,end:context?.end) { Text("May continue beyond this photo").font(.caption).foregroundStyle(.secondary) }
                        if let alternatives=occurrence.exampleAlternatives,!alternatives.isEmpty {
                            DisclosureGroup("Saved manual examples") { ForEach(Array(alternatives.enumerated()),id:\.offset) { _,example in Button(example.text) { context?.draft=example.text } } }
                        }
                        Button("Add preceding sentence") { context?.prepend(from:page.text) }.disabled(context?.start==0)
                        Button("Add following sentence") { context?.append(from:page.text) }.disabled((context?.end ?? 0)>=page.text.unicodeScalars.count)
                        Button("Choose context from page text") { expand=true }
                        Button("Save example") { saveExample() }.disabled(!dirty || !valid)
                    }
                }
                Section {
                    let checked=model.state.occurrences.contains{pages.contains($0.captureID) && $0.lexemeID==item.id && $0.selected}
                    Button(checked ? "Deselect for review" : "Select for review") { var focused=item; focused.occurrence=occurrence; model.select(focused,pages:pages,selected:!checked) }
                    Button("Known") { if saveIfNeeded() { model.classify(item,known:true,pageID:occurrence.captureID); dismiss() } }
                    Button("Unknown · exclude this photo") { if saveIfNeeded() { model.classify(item,known:false,pageID:occurrence.captureID); dismiss() } }
                    Button("Edit reading or definition") { if saveIfNeeded() { correction=true } }
                    Button("Choose dictionary entry or reading") { if saveIfNeeded() { dictionary=true } }
                }
                Section("Other occurrences · tap to select example") {
                    ForEach(model.state.occurrences.filter{$0.lexemeID==item.id && pages.contains($0.captureID)}) { other in
                        Button { model.update{$0.select(item.id,occurrenceID:other.id,pages:pages,selected:true)} } label: {
                            VStack(alignment:.leading) { Text(other.sentence); OccurrenceCorrectionBadge(occurrence:other); if other.selected { Label("Selected example",systemImage:"checkmark").font(.caption) } }
                        }
                    }
                }
                if let page=sourcePage {
                    Section("Source page") { PageSourceImage(page:page,lineIDs:Set(occurrence.lineIDs)) }
                }
            }.navigationTitle("Word").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { if correctionDirty { confirmCorrectionLeave=true } else if dirty { confirmLeave=true } else { dismiss() } } }
                .onAppear { if context==nil, let page=sourcePage { context=ExampleContext(page:page,occurrence:occurrence); savedContext=context } }
                .sheet(isPresented:$correction,onDismiss:{dismiss()}) { CorrectionForm(item:item) }
                .sheet(isPresented:$dictionary,onDismiss:{dismiss()}) { DictionaryChoice(occurrence:occurrence) }
                .sheet(isPresented:$expand) { if let page=sourcePage, let initial=context { ExampleRangeEditor(page:page,occurrence:occurrence,initial:initial) { context=$0 } } }
                .confirmationDialog("Save example changes?",isPresented:$confirmLeave,titleVisibility:.visible) {
                    Button("Save and close") { if saveIfNeeded() { dismiss() } }.disabled(!valid)
                    Button("Discard changes",role:.destructive) { dismiss() }
                }
                .confirmationDialog("Discard the unsaved text correction?",isPresented:$confirmCorrectionLeave,titleVisibility:.visible) {
                    Button("Discard correction and close",role:.destructive) { if saveIfNeeded() { dismiss() } }
                    Button("Keep editing",role:.cancel) {}
                }
        }.interactiveDismissDisabled(dirty || correctionDirty)
    }
    private func saveExample() { if let context, model.saveExample(occurrence.id,context:context) { savedContext=context } }
    private func saveIfNeeded()->Bool { if !dirty { return true }; guard valid else { return false }; saveExample(); return !dirty }
}

struct CorrectionForm: View {
    @EnvironmentObject var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    let item: Recommendation
    @State private var word = ""
    @State private var reading = ""
    @State private var definition = ""
    @State private var example = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("This occurrence only") {
                    Text(word).font(.title2)
                    TextField("Reading", text: $reading)
                    TextField("Definition", text: $definition, axis: .vertical)
                    TextField("Example from this page", text: $example, axis: .vertical).lineLimit(3...12)
                    Text("Metadata edits create a local expression. Use Text as printed in word details to correct recognition.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Correct")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }; ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    model.correct(item.occurrence, expression: word, reading: reading, definition: definition, example: example)
                    if model.error == nil { dismiss() }
                }.disabled(word.isEmpty || !example.contains(word)) } }
                .onAppear { word = item.occurrence.surface; reading = item.lexeme.reading; definition = item.lexeme.definitions.joined(separator: "; "); example = item.occurrence.sentence }
        }
    }
}

struct PageSourceImage: View {
    @EnvironmentObject var model: ReaderModel
    var page: PageCapture
    var lineIDs: Set<String>
    var body: some View {
        if let image = UIImage(contentsOfFile: model.imageURL(page).path) {
            Image(uiImage: image).resizable().scaledToFit().overlay {
                GeometryReader { geo in
                    ForEach(page.recognition?.lines.filter { lineIDs.contains($0.id) } ?? []) { line in
                        Rectangle().fill(.green.opacity(0.22)).frame(width: geo.size.width*line.region.width, height: geo.size.height*line.region.height)
                            .position(x: geo.size.width*(line.region.x+line.region.width/2), y: geo.size.height*(line.region.y+line.region.height/2))
                    }
                }
            }
        }
    }
}

struct LibraryScreen: View {
    @EnvironmentObject var model: ReaderModel
    @State private var filePicker = false
    @State private var textImport: ImportDocument?
    var body: some View {
        NavigationStack {
            List {
                Section("Collected vocabulary") {
                    Text("\(model.state.retained.count) retained words")
                    Button(model.exporting ? "Creating package…" : "Export Anki package") { Task { await model.export() } }.disabled(model.exporting || model.state.retained.isEmpty)
                    if let url = model.lastExport { ShareLink("Share Anki package", item: url) }
                    NavigationLink("Retained words") { RetainedList() }
                    NavigationLink("Export history") {
                        List(model.state.exports.reversed()) { record in
                            ShareLink(item: model.root.appendingPathComponent(record.path)) { VStack(alignment: .leading) { Text(record.created.formatted()); Text("\(record.lexemeIDs.count) words · package generated").font(.caption) } }
                        }.navigationTitle("Exports")
                    }
                    Text("Generating or sharing a package does not confirm import into Anki.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Vocabulary knowledge") {
                    Button("Import Anki text export") { filePicker = true }
                    if let summary = model.importSummary { Text(summary).font(.caption) }
                    NavigationLink("Known vocabulary & overrides") { KnowledgeList() }
                    NavigationLink("Basic vocabulary filter") { BasicWordEditor() }
                }
                Section("Reading history") {
                    NavigationLink("Search all pages") { HistorySearch() }
                    ForEach(model.state.sessions.reversed()) { session in
                        NavigationLink { SessionHistory(sessionID: session.id) } label: { VStack(alignment: .leading) { Text(session.title); Text(session.completed ? "Completed" : "Pending review").font(.caption).foregroundStyle(.secondary) } }
                    }
                }
                Section("Data & diagnostics") {
                    NavigationLink("Backup & restore") { BackupSettings() }
                    NavigationLink("Photo storage") { StorageScreen() }
                    NavigationLink("Dictionary version") { DictionarySettings() }
                    NavigationLink("Recognition lab & saved benchmarks") { BenchmarkArchiveView() }
                    NavigationLink("Sources & licenses") { ScrollView { Text(Bundle.main.url(forResource:"Attribution",withExtension:"txt").flatMap{try? String(contentsOf:$0,encoding:.utf8)} ?? "Attribution resource unavailable in this build.").padding() } }
                }
            }.navigationTitle("Library")
                .fileImporter(isPresented: $filePicker, allowedContentTypes: [.plainText, .tabSeparatedText, .commaSeparatedText]) { result in
                    do {
                        let url = try result.get(), access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let text = try String(contentsOf: url, encoding: .utf8)
                        textImport = ImportDocument(file: try AnkiTextFile(text))
                    } catch { model.error = error.localizedDescription }
                }
                .sheet(item: $textImport) { document in ImportMappingView(file: document.file) }
        }
    }
}
struct ImportDocument: Identifiable { let id = UUID(); let file: AnkiTextFile }
struct ImportMappingView: View {
    @EnvironmentObject var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    let file: AnkiTextFile
    @State private var word = 0
    @State private var reading = -1
    @State private var noteType = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                Text("\(file.rows.count) notes. Only the mapped vocabulary field is imported, never the surrounding sentence.")
                TextField("Mapping name / note type", text: $noteType)
                Picker("Vocabulary", selection: $word) { ForEach(file.columns.indices, id: \.self) { Text("\($0+1): \(file.columns[$0])").tag($0) } }
                Picker("Reading", selection: $reading) { Text("Not supplied").tag(-1); ForEach(file.columns.indices, id: \.self) { Text("\($0+1): \(file.columns[$0])").tag($0) } }
                Section("Normalization preview") {
                    ForEach(Array(file.rows.prefix(8).enumerated()), id: \.offset) { _, row in
                        if word < row.count { VStack(alignment: .leading) { Text(row[word]).font(.caption).lineLimit(2); Text(JapaneseText.clean(row[word])).font(.headline) } }
                    }
                }
                Button(busy ? "Importing…" : "Import terms as known") { busy = true; Task {
                    await model.importText(file, mapping: FieldMapping(word: word, reading: reading < 0 ? nil : reading), noteType: noteType)
                    busy = false; if model.error == nil { dismiss() }
                } }.disabled(busy || file.rows.isEmpty)
            }.navigationTitle("Import vocabulary").toolbar { Button("Cancel") { dismiss() }.disabled(busy) }
                .onAppear { noteType = file.noteType; restoreMapping(file.noteType) }
                .onChange(of: noteType) { _, value in restoreMapping(value) }
        }.interactiveDismissDisabled(busy)
    }
    private func restoreMapping(_ name: String) { if let saved = model.state.mappings[name], saved.word < file.columns.count { word = saved.word; reading = saved.reading.flatMap { $0 < file.columns.count ? $0 : nil } ?? -1 } }
}
struct RetainedList: View {
    @EnvironmentObject var model: ReaderModel
    @State private var search = ""
    var body: some View {
        List(model.state.retained.values.filter { search.isEmpty || $0.lexeme.expression.contains(search) || $0.lexeme.reading.contains(search) }.sorted { $0.retainedAt > $1.retainedAt }) { word in
            VStack(alignment: .leading, spacing: 5) { Text(word.lexeme.expression).font(.headline); Text(word.lexeme.reading); Text(word.lexeme.definitions.first ?? ""); Text(word.example).foregroundStyle(.secondary); Text(word.source).font(.caption); CorrectionBadge(changes:word.corrections ?? [],legacy:word.previouslyEdited == true) }
                .swipeActions(edge:.trailing,allowsFullSwipe:false) { Button("Remove",role:.destructive) { model.removeRetained(word.id) } }
                .contextMenu { Button("Remove from retained words",role:.destructive) { model.removeRetained(word.id) } }
                .accessibilityAction(named:"Remove from retained words") { model.removeRetained(word.id) }
        }.navigationTitle("Retained").searchable(text: $search)
            .safeAreaInset(edge:.bottom) {
                if let removed=model.removedRetainedWord {
                    HStack { Text("Removed \(removed.lexeme.expression)").font(.callout); Spacer(); Button("Undo") { model.undoRemoveRetained() }; Button { model.removedRetainedWord=nil } label:{Image(systemName:"xmark")}.accessibilityLabel("Dismiss") }.padding().background(.regularMaterial)
                }
            }
    }
}
struct KnowledgeList: View {
    @EnvironmentObject var model: ReaderModel
    @State private var search = ""
    var body: some View {
        List(model.state.lexemes.values.filter { model.state.knowledge[$0.id] != nil && (search.isEmpty || $0.expression.contains(search) || $0.reading.contains(search)) }.sorted { $0.expression < $1.expression }) { word in
            VStack(alignment: .leading) {
                Text("\(word.expression)  \(word.reading)")
                if word.dictionaryID == nil { Text("Unresolved dictionary identity").font(.caption).foregroundStyle(.secondary) }
                Toggle("Known", isOn: Binding(get: { model.state.knowledge[word.id]?.isKnown ?? false }, set: { model.known(word.id, value: $0) }))
            }
        }.navigationTitle("Knowledge").searchable(text: $search)
    }
}
struct BasicWordEditor: View {
    @EnvironmentObject var model: ReaderModel
    @State private var words = ""
    var body: some View {
        Form { Text("One word per line. This hides suggestions without marking words known."); TextEditor(text: $words).frame(minHeight: 300); Button("Save filter") { model.update { $0.basicWords = Set(words.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }) } } }.navigationTitle("Basic words").onAppear { words = model.state.basicWords.sorted().joined(separator: "\n") }
    }
}
struct SessionHistory: View {
    @EnvironmentObject var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    let sessionID: String
    @State private var title = ""
    @State private var mergeTarget = ""
    var body: some View {
        List {
            if model.state.sessions.first(where: { $0.id == sessionID })?.completed == false {
                Picker("Merge into session", selection: $mergeTarget) {
                    Text("Choose session").tag("")
                    ForEach(model.pendingSessions.filter { $0.id != sessionID }) { Text($0.title).tag($0.id) }
                }
                Button("Merge sessions") {
                    model.update { s in
                        guard let from = s.sessions.first(where: { $0.id == sessionID }), let to = s.sessions.firstIndex(where: { $0.id == mergeTarget }) else { return }
                        for i in s.captures.indices where s.captures[i].sessionID == sessionID { s.captures[i].sessionID = mergeTarget }
                        s.sessions[to].started = min(s.sessions[to].started, from.started)
                        s.sessions[to].lastCapture = max(s.sessions[to].lastCapture, from.lastCapture)
                        s.sessions.removeAll { $0.id == sessionID }
                    }
                    if model.error == nil { dismiss() }
                }.disabled(mergeTarget.isEmpty)
            }
            TextField("Session name", text: $title).onSubmit { model.update { s in if let i = s.sessions.firstIndex(where: { $0.id == sessionID }) { s.sessions[i].title = title } } }
            ForEach(model.state.captures.filter { $0.sessionID == sessionID }) { page in Button { model.openPhoto(page.id) } label: { VStack(alignment: .leading) { Text(page.created.formatted()); Text(page.status.rawValue).font(.caption) } } }
        }.navigationTitle("Session").onAppear { title = model.state.sessions.first { $0.id == sessionID }?.title ?? "" }
    }
}

struct HistorySearch: View {
    @EnvironmentObject var model: ReaderModel
    @State private var query = ""
    var body: some View {
        List(model.state.captures.filter { page in query.isEmpty || page.text.localizedCaseInsensitiveContains(query) || model.state.occurrences.contains { $0.captureID == page.id && $0.surface.contains(query) } }) { page in
            Button { model.openPhoto(page.id) } label: {
                VStack(alignment: .leading) { Text(page.created.formatted()); Text(page.text).lineLimit(2).font(.caption).foregroundStyle(.secondary) }
            }
        }.navigationTitle("Page history").searchable(text: $query)
    }
}
