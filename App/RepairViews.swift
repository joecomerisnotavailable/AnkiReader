import SwiftUI
import UniformTypeIdentifiers

struct PageTextEditor: View {
    @EnvironmentObject var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    var page: PageCapture
    @State private var text = ""
    var body: some View {
        NavigationStack {
            VStack {
                Text("Edit recognized text. Selected and corrected spans must remain unambiguous. Line highlights are unavailable after a page-text edit.").font(.caption).foregroundStyle(.secondary).padding()
                TextEditor(text: $text).font(.title3).padding(.horizontal)
            }.navigationTitle("Edit page text")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Apply") { model.editText(page.id, text: text); if model.error == nil { dismiss() } }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                }.onAppear { text = page.text }
        }
    }
}

struct SegmentationEditor: View {
    @EnvironmentObject var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    var page: PageCapture
    var anchor: Occurrence?
    @State private var start = 0
    @State private var end = 0
    @State private var cuts: Set<Int> = []
    @State private var busy = false
    private var scalars: [Unicode.Scalar] { Array(page.text.unicodeScalars) }
    private var segments: [String] {
        let points = [start]+cuts.filter { $0 > start && $0 < end }.sorted()+[end]
        return zip(points, points.dropFirst()).map { JapaneseText.slice(page.text, $0, $1) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Tap a divider to add or remove a cut. Removing cuts merges words; adding cuts splits them. Changes apply to this occurrence.").font(.callout)
                    if !scalars.isEmpty {
                        Stepper("Start: \(start+1)", value: $start, in: 0...max(0,end-1))
                        Stepper("End: \(end)", value: $end, in: min(start+1,scalars.count)...scalars.count)
                    }
                }
                Section("Enlarged text strip") {
                    ScrollView(.horizontal) {
                        HStack(spacing: 2) {
                            ForEach(start..<end, id: \.self) { offset in
                                Text(String(scalars[offset])).font(.system(size: 30)).frame(minWidth: 30)
                                if offset+1 < end {
                                    Button { if cuts.contains(offset+1) { cuts.remove(offset+1) } else { cuts.insert(offset+1) } } label: {
                                        Text(cuts.contains(offset+1) ? "│" : "·").font(.title2).frame(width: 30, height: 50)
                                    }.buttonStyle(.bordered).accessibilityLabel("Toggle cut after \(offset+1)")
                                }
                            }
                        }
                    }
                }
                Section("Resulting words") { ForEach(Array(segments.enumerated()), id: \.offset) { _, text in Text(text) } }
                Button(busy ? "Saving…" : "Apply cuts") { busy = true; Task {
                    await model.replaceSegments(pageID: page.id, start: start, end: end, segments: segments)
                    busy = false; if model.error == nil { dismiss() }
                } }.disabled(busy || segments.isEmpty)
            }.navigationTitle("Word boundaries").toolbar { Button("Cancel") { dismiss() }.disabled(busy) }
                .onAppear {
                    let tokens = model.state.occurrences.filter { $0.captureID == page.id }.sorted { $0.start < $1.start }
                    if let anchor {
                        let near = tokens.filter { $0.start >= max(0,anchor.start-12) && $0.end <= anchor.end+12 }
                        start = min(anchor.start,near.first?.start ?? anchor.start); end = max(anchor.end,near.last?.end ?? anchor.end)
                    } else { start = 0; end = tokens.filter { $0.end <= 100 }.last?.end ?? min(100,scalars.count) }
                    cuts = Set(tokens.map(\.end))
                }
        }.interactiveDismissDisabled(busy)
    }
}

struct DictionaryChoice: View {
    @EnvironmentObject var model: ReaderModel
    @Environment(\.dismiss) private var dismiss
    let occurrence: Occurrence
    @State private var query = ""
    @State private var matches: [Lexeme] = []
    @State private var remember = false
    @State private var busy = false
    var body: some View {
        NavigationStack {
            List {
                TextField("Expression or dictionary form", text: $query).onSubmit { lookup() }
                Button("Find entries") { lookup() }.disabled(busy)
                Toggle("Remember this reading preference", isOn: $remember)
                Text("A remembered entry is preferred only when the tokenizer also gives the same reading. It does not replace matching text globally.").font(.caption).foregroundStyle(.secondary)
                ForEach(matches) { word in
                    Button { model.chooseEntry(word, occurrence: occurrence, remember: remember); if model.error == nil { dismiss() } } label: {
                        VStack(alignment: .leading) { Text("\(word.expression) · \(word.reading)").font(.headline); Text(word.definitions.joined(separator: "; ")).font(.subheadline) }
                    }
                }
                if !busy && matches.isEmpty { Text("No matching entries. You can create a custom expression with Correct.").foregroundStyle(.secondary) }
            }.navigationTitle("Dictionary entry").toolbar { Button("Cancel") { dismiss() } }
                .task { query = occurrence.surface; lookup() }
        }
    }
    private func lookup() { busy = true; Task { matches = await model.alternatives(query); busy = false } }
}

struct BackupSettings: View {
    @EnvironmentObject var model: ReaderModel
    @State private var picker = false
    @State private var restoreURL: URL?
    @State private var confirm = false
    var body: some View {
        List {
            Section("Backup") {
                Text("Includes vocabulary, decisions, photos, extracted text, and saved Anki packages. Dictionaries are excluded.")
                Button(model.maintenance ? "Working…" : "Create backup") { Task { await model.backup() } }.disabled(model.maintenance || model.processing || model.exporting)
                if let url = model.lastBackup { ShareLink("Save or share backup", item: url) }
            }
            Section("Restore") {
                Button("Choose backup to restore") { picker = true }.disabled(model.maintenance || model.processing || model.exporting)
                Text("Restoring replaces the active library. A backup of the current library is saved first.").font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Backup & restore")
            .fileImporter(isPresented: $picker, allowedContentTypes: [.zip]) { result in
                do { restoreURL = try result.get(); confirm = true } catch { model.error = error.localizedDescription }
            }
            .confirmationDialog("Replace the active library with this backup?", isPresented: $confirm, titleVisibility: .visible) {
                Button("Restore backup", role: .destructive) { if let restoreURL { Task { await model.restore(restoreURL) } } }
            }
    }
}
struct StorageScreen: View {
    @EnvironmentObject var model: ReaderModel
    @State private var deleting: PageCapture?
    @State private var confirm = false
    var body: some View {
        List {
            Text("Photos stay on this phone until you explicitly remove them. Text, selected vocabulary, and retained examples remain in history.").font(.callout)
            ForEach(model.state.captures.filter { $0.photoRemoved != true }) { page in
                HStack {
                    VStack(alignment: .leading) {
                        Text(page.created.formatted())
                        let bytes = (try? model.imageURL(page).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).font(.caption)
                    }
                    Spacer()
                    Button("Remove photo", role: .destructive) { deleting = page; confirm = true }.disabled(page.status != .ready || model.processing || model.maintenance)
                }
            }
        }.navigationTitle("Photo storage")
            .confirmationDialog("Remove this photo? The saved text and vocabulary will remain.", isPresented: $confirm, titleVisibility: .visible) {
                Button("Remove photo", role: .destructive) { if let deleting { model.deletePhoto(deleting.id) } }
            }
    }
}

struct DictionarySettings: View {
    @EnvironmentObject var model: ReaderModel
    @State private var picker = false
    @State private var versions: [String] = []
    var body: some View {
        List {
            Text(versions.last.map { "Installed index: "+String($0.prefix(12)) } ?? "Bundled JMdict English index")
            Text("Updates must be SQLite indexes built with Scripts/build_dictionary.py. Existing vocabulary identities, knowledge overrides, and retained examples are preserved.").font(.callout)
            Button(model.maintenance ? "Working…" : "Install dictionary index") { picker = true }.disabled(model.processing || model.maintenance)
            Button("Roll back to previous dictionary") { Task { await model.installDictionary(nil); reload() } }.disabled(versions.isEmpty || model.processing || model.maintenance)
            Text("JMdict / EDRDG · CC BY-SA 4.0").font(.caption)
            Link("Dictionary attribution and licensing", destination: URL(string: "https://www.edrdg.org/edrdg/licence.html")!)
        }.navigationTitle("Dictionary").onAppear { reload() }
            .fileImporter(isPresented: $picker, allowedContentTypes: [.data]) { result in
                do { let url = try result.get(); Task { await model.installDictionary(url); reload() } }
                catch { model.error = error.localizedDescription }
            }
    }
    private func reload() { versions = (try? DictionaryVersions.versions(root: model.root)) ?? [] }
}
