import Foundation
import UIKit
import Combine
import CryptoKit

final class ReadingWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "reading.pipeline", qos: .userInitiated)
    private var tokenizer: SudachiAnalyzer?
    private var dictionary: DictionaryIndex?
    private var dictionaryURL: URL?
    private let libraryRoot = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ReadingLibrary")
    private var recognizer: GoogleRecognizer?
    private let columnRefiner=ColumnRecognitionRefiner()
    private func prepare() throws {
        if tokenizer == nil { tokenizer = try SudachiAnalyzer(directory: Bundle.main.resourceURL!.appendingPathComponent("sudachi")) }
        let url = try DictionaryVersions.current(root: libraryRoot, bundled: Bundle.main.url(forResource: "dictionary", withExtension: "sqlite")!)
        if dictionary == nil || dictionaryURL != url { dictionary = try DictionaryIndex(url: url); dictionaryURL = url }
    }
    func process(capture: PageCapture, url: URL, preferences: [String: Lexeme]) async throws -> AnalyzedPage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try prepare()
                    let recognition: Recognition
                    if capture.correctedText != nil, let saved = capture.recognition { recognition = saved }
                    else {
                        if recognizer == nil { recognizer = GoogleRecognizer() }
                        guard let image = UIImage(data: try Data(contentsOf: url))?.normalized() else { throw StorageError.database("Cannot decode the saved photo") }
                        let raw = try recognizer!.recognize(image, layout: capture.layout == "Horizontal" ? .horizontal : .vertical)
                        recognition = (try? columnRefiner.refine(raw,image:image,vertical:capture.layout != "Horizontal")) ?? raw
                    }
                    let page = try ReadingPipeline.analyze(captureID: capture.id, recognition: recognition,
                        text: capture.correctedText, tokenizer: tokenizer!, dictionary: dictionary!, preferences: preferences)
                    continuation.resume(returning: page)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func refineSaved(_ capture:PageCapture,url:URL,preferences:[String:Lexeme],preferredLineID:String?,preferredLineFraction:Double?) async throws -> AnalyzedPage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try prepare()
                    guard let saved=capture.recognition,let image=UIImage(data:try Data(contentsOf:url))?.normalized() else { throw StorageError.database("The saved photo is unavailable.") }
                    let recognition=try columnRefiner.refine(saved,image:image,vertical:capture.layout != "Horizontal",preferredLineID:preferredLineID,preferredLineFraction:preferredLineFraction)
                    continuation.resume(returning:try ReadingPipeline.analyze(captureID:capture.id,recognition:recognition,tokenizer:tokenizer!,dictionary:dictionary!,preferences:preferences))
                } catch { continuation.resume(throwing:error) }
            }
        }
    }
    func analyzeCorrection(_ text:String,captureID:String) async throws -> AnalyzedPage {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { try prepare();continuation.resume(returning:try ReadingPipeline.analyze(captureID:captureID,recognition:Recognition(engine:"correction",lines:[],elapsed:0),text:text,tokenizer:tokenizer!,dictionary:dictionary!)) }
                catch { continuation.resume(throwing:error) }
            }
        }
    }
    func resolveExpressions(_ expressions: [String]) async throws -> [Lexeme] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try prepare()
                    let words = try expressions.map { try dictionary!.resolveExpression($0,tokenizer:tokenizer!) }
                    continuation.resume(returning: words)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func lookup(_ expression: String) async throws -> [Lexeme] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { try prepare(); continuation.resume(returning: try dictionary!.lookup(expression)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func importWords(_ rows: [[String]], mapping: FieldMapping) async throws -> [Lexeme] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do {
                    try prepare(); var words: [String: Lexeme] = [:]
                    for row in rows where mapping.word < row.count {
                        let surface = JapaneseText.clean(row[mapping.word])
                        guard !surface.isEmpty else { continue }
                        let reading = mapping.reading.flatMap { $0 < row.count ? JapaneseText.clean(row[$0]) : nil }
                        let matches = try dictionary!.lookup(surface, reading: reading, strictReading: true)
                        // Ambiguous written forms remain unresolved instead of marking every reading known.
                        let word: Lexeme
                        if matches.count == 1 { word = matches[0] }
                        else {
                            let tokens = try tokenizer!.tokenize(surface)
                            if matches.isEmpty, tokens.count == 1, reading == nil || reading?.isEmpty == true {
                                word = try dictionary!.resolve(tokens[0])
                            } else { word = Lexeme(id: "import:\(surface):\(reading ?? "")", expression: surface, reading: reading ?? "", definitions: ["Imported term; dictionary identity needs confirmation"]) }
                        }
                        words[word.id] = word
                    }
                    continuation.resume(returning: Array(words.values))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

@MainActor final class ReaderModel: ObservableObject {
    @Published private(set) var state = LibraryState()
    @Published var error: String?
    @Published var processing = false
    @Published var exporting = false
    @Published var maintenance = false
    @Published var lastBackup: URL?
    @Published var activeCaptureID: String?
    @Published var lastExport: URL?
    @Published var importSummary: String?
    @Published var selectedTab = 0
    @Published var finalReviewPageID:String?
    @Published var photoReturnsToFinalReview=false
    @Published var removedRetainedWord:RetainedWord?
    @Published var parseUndo: ParseUndo?
    @Published var correctionUndo: CorrectionUndo?
    @Published var parsingSuggestions:[String:[ParsingSuggestion]]=[:]
    @Published var pageEditHistory:[String:[PageEditUndo]]=[:]
    @Published var pendingPageEditorID:String?
    @Published var lastPageEditStart:[String:Int]=[:]
    @Published var editingParse = false
    @Published var undoKnown: (String, Knowledge?)?
    let root: URL
    private var store: LibraryStore?
    let worker = ReadingWorker()
    private var draining = false
    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ReadingLibrary", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("exports"), withIntermediateDirectories: true)
            store = try LibraryStore(url: root.appendingPathComponent("library.sqlite"))
            state = try store!.load()
            state.migratePhotoReviews()
            for i in state.captures.indices where state.captures[i].status == .processing { state.captures[i].status = .pending }
            try store!.save(state)
        } catch { self.error = error.localizedDescription; store = nil }
    }
    var pendingSessions: [ReadingSession] { state.sessions.filter { !$0.completed } }
    func imageURL(_ page: PageCapture) -> URL { root.appendingPathComponent(page.imagePath) }
    @discardableResult func update(_ body: (inout LibraryState) throws -> Void) -> Bool {
        guard !maintenance else { error = "Wait for backup or restore to finish."; return false }
        do {
            guard let store else { throw StorageError.database("Library is unavailable. Restart the app before capturing.") }
            var next = state; try body(&next); try store.save(next); state = next; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func setSource(_ value: String) { update { $0.lastSource = value } }
    func capture(_ data: Data, layout: PageLayout) {
        guard store != nil, !maintenance else { error = "Library unavailable or busy"; return }
        do {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            var next = state
            let sessionID = next.session(source: next.lastSource)
            var page = PageCapture(sessionID: sessionID, imagePath: "images/\(UUID().uuidString).jpg", fingerprint: hash)
            page.layout = layout.rawValue; page.reviewCompleted = false
            // Save first, so interruptions never discard a successful capture.
            try data.write(to: imageURL(page), options: .atomic)
            next.captures.append(page)
            try store!.save(next); state = next; activeCaptureID = page.id
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            Task { await resume() }
        } catch { self.error = error.localizedDescription }
    }
    func resume() async {
        guard !draining, store != nil, !maintenance else { return }
        draining = true; processing = true
        defer { draining = false; processing = false }
        while let page = state.captures.first(where: { $0.status == .pending }) {
            update { s in if let i = s.captures.firstIndex(where: { $0.id == page.id }) { s.captures[i].status = .processing } }
            if state.captures.first(where: { $0.id == page.id })?.status != .processing { return }
            do {
                let preferences = state.rememberedExpressions.compactMapValues { state.lexemes[$0] }
                let result = try await worker.process(capture: page, url: imageURL(page), preferences: preferences)
                update { $0.apply(result, captureID: page.id) }
            } catch {
                update { s in if let i = s.captures.firstIndex(where: { $0.id == page.id }) { s.captures[i].status = .failed; s.captures[i].error = error.localizedDescription } }
            }
            if state.captures.first(where: { $0.id == page.id })?.status == .processing { return }
        }
    }
    func retry(_ pageID: String) {
        update { s in if let i = s.captures.firstIndex(where: { $0.id == pageID }) { s.captures[i].status = .pending; s.captures[i].error = nil } }
        Task { await resume() }
    }
    func select(_ item: Recommendation, pages: Set<String>, selected: Bool) {
        update { $0.select(item.id, occurrenceID: item.occurrence.id, pages: pages, selected: selected) }
    }
    func known(_ id: String, value: Bool) {
        undoKnown = (id, state.knowledge[id])
        update { s in var k = s.knowledge[id] ?? Knowledge(); k.override = value; s.knowledge[id] = k
            if value {
                let pending = Set(s.captures.filter { !s.isReviewed($0) }.map(\.id))
                for i in s.occurrences.indices where s.occurrences[i].lexemeID == id && pending.contains(s.occurrences[i].captureID) { s.occurrences[i].selected = false }
            }
        }
    }
    func undoKnowledge() { if let (id, old) = undoKnown { update { $0.knowledge[id] = old }; undoKnown = nil } }
    func finish(_ sessions: Set<String>) {
        let unfinished = state.captures.contains { sessions.contains($0.sessionID) && $0.status != .ready }
        guard !unfinished else { error = "Some pages are still processing or need a retry. Finish after those pages are ready."; return }
        update { $0.finish(sessionIDs: sessions) }
    }
    func correct(_ occurrence: Occurrence, expression: String, reading: String, definition: String, example: String) {
        let surface = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !surface.isEmpty, example.contains(surface) else { error = "The example must contain the corrected expression."; return }
        update { s in
            guard let i = s.occurrences.firstIndex(where: { $0.id == occurrence.id }) else { return }
            // Local identity is persistent; correcting one occurrence never rewrites other occurrences.
            let id = "local:\(occurrence.id)"
            s.lexemes[id] = Lexeme(id: id, expression: surface, reading: reading, definitions: [definition])
            s.occurrences[i].lexemeID = id; s.occurrences[i].surface = surface
            s.occurrences[i].sentence = example; s.occurrences[i].corrected = true
        }
    }
    func editText(_ pageID: String, text: String) {
        update { try $0.editText(captureID: pageID, text: text) }
        if error == nil { Task { await resume() } }
    }
    func replaceSegments(pageID: String, start: Int, end: Int, segments: [String]) async {
        do {
            let words = try await worker.resolveExpressions(segments)
            update { try $0.replaceSegments(captureID: pageID, start: start, end: end, surfaces: segments, words: words) }
        } catch { self.error = error.localizedDescription }
    }
    func alternatives(_ expression: String) async -> [Lexeme] {
        do { return try await worker.lookup(expression) } catch { self.error = error.localizedDescription; return [] }
    }
    func chooseEntry(_ word: Lexeme, occurrence: Occurrence, remember: Bool) {
        update { s in
            guard let i = s.occurrences.firstIndex(where: { $0.id == occurrence.id }) else { return }
            s.lexemes[word.id] = word; s.occurrences[i].lexemeID = word.id; s.occurrences[i].corrected = true
            if remember { s.rememberedExpressions[occurrence.surface] = word.id }
        }
    }
    func importText(_ file: AnkiTextFile, mapping: FieldMapping, noteType: String) async {
        do {
            let items = try await worker.importWords(file.rows, mapping: mapping)
            update { $0.importKnown(items); $0.mappings[noteType] = mapping }
            let unresolved = items.filter { $0.dictionaryID == nil }.count
            importSummary = "Imported \(items.count) unique terms. \(unresolved) unresolved terms are saved in Known vocabulary for inspection. Explicit known/not-known choices were preserved."
        } catch { self.error = error.localizedDescription }
    }

    func installDictionary(_ url: URL?) async {
        guard !maintenance, !processing else { error = "Wait for processing to finish."; return }
        maintenance = true; defer { maintenance = false }
        let access = url?.startAccessingSecurityScopedResource() ?? false
        defer { if access { url?.stopAccessingSecurityScopedResource() } }
        let root = root
        do {
            try await Task.detached(priority: .utility) {
                if let url { try DictionaryVersions.install(source: url, root: root) }
                else { try DictionaryVersions.rollback(root: root) }
            }.value
        } catch { self.error = error.localizedDescription }
    }
    func backup() async {
        guard !maintenance, !processing, !exporting else { error = "Wait for current processing to finish."; return }
        maintenance = true; defer { maintenance = false }
        let snapshot = state, root = root
        let url = root.appendingPathComponent("ReadingBackup-\(UUID().uuidString).zip")
        do {
            try await Task.detached(priority: .utility) { try LibraryBackup.create(state: snapshot, root: root, destination: url) }.value
            lastBackup = url
        } catch { self.error = error.localizedDescription }
    }
    func restore(_ url: URL) async {
        guard !maintenance, !processing, !exporting, let store else { error = "Wait for current processing to finish."; return }
        maintenance = true
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() }; maintenance = false }
        let root = root
        do {
            // Preserve a pre-restore snapshot as an additional recovery point.
            let current = state
            let safety = root.appendingPathComponent("BeforeRestore-\(UUID().uuidString).zip")
            let restored = try await Task.detached(priority: .utility) {
                try LibraryBackup.create(state: current, root: root, destination: safety)
                return try LibraryBackup.stageRestore(archive: url, root: root)
            }.value
            var migrated = restored; migrated.migratePhotoReviews()
            try store.save(migrated); state = migrated; activeCaptureID = nil; lastExport = nil; undoKnown = nil
            finalReviewPageID=nil; photoReturnsToFinalReview=false; removedRetainedWord=nil
            lastBackup = safety
        } catch { self.error = error.localizedDescription }
    }
    func deletePhoto(_ id: String) {
        guard !processing, !maintenance else { error = "Wait for processing to finish."; return }
        guard let page = state.captures.first(where: { $0.id == id }) else { return }
        do {
            // Explicit photo removal leaves the recognized text and vocabulary in history.
            update { s in if let i = s.captures.firstIndex(where: { $0.id == id }) { s.captures[i].photoRemoved = true } }
            if self.error == nil { try FileManager.default.removeItem(at: imageURL(page)) }
        } catch { self.error = error.localizedDescription }
    }

    func export() async {
        guard !exporting else { return }; exporting = true; defer { exporting = false }
        let snapshot = Array(state.retained.values), name = "exports/ReadingCompanion-\(UUID().uuidString).apkg", root = root
        do {
            try await Task.detached(priority: .userInitiated) { try AnkiPackage.generate(words: snapshot, destination: root.appendingPathComponent(name)) }.value
            update { $0.exports.append(ExportRecord(path: name, lexemeIDs: snapshot.map(\.id))) }
            lastExport = root.appendingPathComponent(name)
        } catch { self.error = error.localizedDescription }
    }
}

struct ParseUndo {
    var pageID: String
    var text: String
    var start: Int
    var end: Int
    var before: [Occurrence]
    var afterIDs: Set<String>
}
extension ReaderModel {
    var pendingPhotos: [PageCapture] { state.captures.filter { !state.isReviewed($0) }.sorted { $0.created < $1.created } }
    func openPhoto(_ id: String,fromFinalReview:Bool=false) { activeCaptureID=id; photoReturnsToFinalReview=fromFinalReview; selectedTab=0 }
    func returnToCamera() { activeCaptureID=nil; photoReturnsToFinalReview=false; selectedTab=0 }
    func returnToBacklog() { activeCaptureID=nil; finalReviewPageID=nil; photoReturnsToFinalReview=false; selectedTab=1 }
    func openFinalReview(_ id:String) { activeCaptureID=nil; finalReviewPageID=id; photoReturnsToFinalReview=false; selectedTab=1 }
    func leavePhoto(_ id:String) { if photoReturnsToFinalReview { openFinalReview(id) } else { returnToCamera() } }
    func removeRetained(_ id:String) {
        var removed:RetainedWord?
        if update({removed=$0.removeRetained(id)}) { removedRetainedWord=removed }
    }
    func undoRemoveRetained() {
        guard let word=removedRetainedWord else { return }
        if update({$0.retained[word.id]=word}) { removedRetainedWord=nil }
    }
    @discardableResult func finishPhoto(_ id:String)->Bool {
        guard let page=state.captures.first(where:{$0.id==id}), page.status == .ready else { error="Wait for this photo to finish processing."; return false }
        guard !state.occurrences.contains(where:{$0.captureID==id && $0.selected && $0.needsExampleRepair}) else { error="Repair the marked manual example in word details before finishing.";return false }
        return update { $0.finishPhotos([id]) }
    }
    func classify(_ item:Recommendation,known:Bool,pageID:String) {
        update { $0.classify(item.id,known:known,pageID:pageID) }
    }
    @discardableResult func saveExample(_ id:String,context:ExampleContext)->Bool {
        update { try $0.saveExample(occurrenceID:id,text:context.draft,start:context.start,end:context.end) }
    }
    func merge(_ firstID:String,_ secondID:String) async {
        guard let first=state.occurrences.first(where:{$0.id==firstID}),let second=state.occurrences.first(where:{$0.id==secondID}) else { return }
        do {
            let range=try ParseGesture.mergeRange(first,second,in:state.occurrences.filter{$0.captureID==first.captureID})
            await editPage(first.captureID,command:.join(range))
        } catch { self.error=error.localizedDescription }
    }
    func split(_ id:String,cuts:Set<Int>) async {
        guard let occurrence=state.occurrences.first(where:{$0.id==id}), let page=state.captures.first(where:{$0.id==occurrence.captureID}) else { return }
        let segments=ParseGesture.segments(JapaneseText.slice(page.text,occurrence.start,occurrence.end),cuts:cuts)
        guard segments.count>=2 && segments.count<=3 else { error="Place one or two cuts inside the term."; return }
        await changeParse(pageID:page.id,range:occurrence.start..<occurrence.end,surfaces:segments)
    }
    private func changeParse(pageID:String,range:Range<Int>,surfaces:[String]) async {
        guard !editingParse, let page=state.captures.first(where:{$0.id==pageID}), page.status == .ready else { return }
        editingParse=true; defer { editingParse=false }
        let old=state.occurrences.filter{$0.captureID==pageID && $0.start<range.upperBound && $0.end>range.lowerBound}
        do {
            let words=try await worker.resolveExpressions(surfaces)
            guard state.captures.first(where:{$0.id==pageID})?.text==page.text,
                  Set(state.occurrences.filter{$0.captureID==pageID && $0.start<range.upperBound && $0.end>range.lowerBound}.map(\.id))==Set(old.map(\.id)) else { throw StorageError.invalidArchive("The page changed during this edit. Try again.") }
            if update({ try $0.replaceSegments(captureID:pageID,start:range.lowerBound,end:range.upperBound,surfaces:surfaces,words:words) }) {
                let added=state.occurrences.filter{$0.captureID==pageID && $0.start<range.upperBound && $0.end>range.lowerBound}
                parseUndo=ParseUndo(pageID:pageID,text:page.text,start:range.lowerBound,end:range.upperBound,before:old,afterIDs:Set(added.map(\.id)))
                UIImpactFeedbackGenerator(style:.light).impactOccurred()
            }
        } catch { self.error=error.localizedDescription }
    }
    func undoParse() {
        guard let undo=parseUndo, !editingParse else { return }
        if update({ s in
            guard let page=s.captures.first(where:{$0.id==undo.pageID}),page.text==undo.text else { throw StorageError.invalidArchive("Page text has changed; this parse edit can no longer be undone.") }
            let current=s.occurrences.filter{$0.captureID==undo.pageID && $0.start<undo.end && $0.end>undo.start}
            guard Set(current.map(\.id))==undo.afterIDs else { throw StorageError.invalidArchive("This span has changed since the edit.") }
            s.occurrences.removeAll{undo.afterIDs.contains($0.id)}; s.occurrences += undo.before
        }) { parseUndo=nil }
    }
}
