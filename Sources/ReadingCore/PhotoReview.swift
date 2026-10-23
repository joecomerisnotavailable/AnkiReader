import Foundation

extension LibraryState {
    public func isReviewed(_ page: PageCapture) -> Bool {
        page.reviewCompleted ?? (sessions.first { $0.id == page.sessionID }?.completed ?? false)
    }
    public mutating func migratePhotoReviews() {
        for i in captures.indices where captures[i].reviewCompleted == nil { captures[i].reviewCompleted = isReviewed(captures[i]) }
        for i in captures.indices where captures[i].reviewMarks == nil {
            var marks:[String:ReviewMark]=[:]
            for id in captures[i].excludedLexemeIDs ?? [] {
                if let override=knowledge[id]?.override { marks[id]=override ? .known : .unknown }
            }
            for occurrence in occurrences where occurrence.captureID==captures[i].id && occurrence.selected { marks[occurrence.lexemeID] = .selected }
            captures[i].reviewMarks=marks
        }
    }
    public mutating func finishPhotos(_ ids: Set<String>) {
        migratePhotoReviews()
        for item in Recommender.ranked(state: self, captureIDs: ids, showAll: true) where item.selected {
            guard retained[item.id] == nil else { continue }
            let sessionID = captures.first { $0.id == item.occurrence.captureID }?.sessionID
            let source = sessions.first { $0.id == sessionID }?.title ?? ""
            var word=RetainedWord(lexeme: item.lexeme, occurrence: item.occurrence, source: source)
            if let guid=retainedGUIDs?[item.id] { word.guid=guid }
            retained[item.id] = word
        }
        for i in captures.indices where ids.contains(captures[i].id) { captures[i].reviewCompleted = true }
        for i in sessions.indices {
            let pages = captures.filter { $0.sessionID == sessions[i].id }
            if !pages.isEmpty { sessions[i].completed = pages.allSatisfy { $0.reviewCompleted == true } }
        }
    }
    public mutating func classify(_ lexemeID: String, known: Bool, pageID: String) {
        migratePhotoReviews()
        var value = knowledge[lexemeID] ?? Knowledge(); value.override = known; knowledge[lexemeID] = value
        let pending = Set(captures.filter { !isReviewed($0) }.map(\.id))
        let selectedPages=Set(occurrences.filter{$0.lexemeID==lexemeID && $0.selected}.map(\.captureID))
        for i in occurrences.indices where occurrences[i].lexemeID == lexemeID {
            if occurrences[i].captureID == pageID || (known && pending.contains(occurrences[i].captureID)) { occurrences[i].selected = false }
        }
        if let i = captures.firstIndex(where: { $0.id == pageID }) {
            var excluded = captures[i].excludedLexemeIDs ?? []; excluded.insert(lexemeID); captures[i].excludedLexemeIDs = excluded
            captures[i].reviewMarks?[lexemeID] = known ? .known : .unknown
        }
        if known {
            for i in captures.indices where pending.contains(captures[i].id) && selectedPages.contains(captures[i].id) {
                captures[i].reviewMarks?[lexemeID] = .known
            }
        }
    }
    public func reviewMark(_ lexemeID:String,pageID:String)->ReviewMark? {
        if occurrences.contains(where:{$0.captureID==pageID && $0.lexemeID==lexemeID && $0.selected}) { return .selected }
        return captures.first{$0.id==pageID}?.reviewMarks?[lexemeID]
    }
    public mutating func clearReviewMark(_ lexemeID:String,pageID:String) {
        migratePhotoReviews()
        if let i=captures.firstIndex(where:{$0.id==pageID}) {
            captures[i].reviewMarks?.removeValue(forKey:lexemeID)
            captures[i].excludedLexemeIDs?.remove(lexemeID)
        }
        for i in occurrences.indices where occurrences[i].captureID==pageID && occurrences[i].lexemeID==lexemeID { occurrences[i].selected=false }
    }
    @discardableResult public mutating func removeRetained(_ id:String)->RetainedWord? {
        guard let word=retained.removeValue(forKey:id) else { return nil }
        if retainedGUIDs==nil { retainedGUIDs=[:] }; retainedGUIDs?[id]=word.guid
        for i in occurrences.indices where occurrences[i].lexemeID==id { occurrences[i].selected=false }
        for i in captures.indices where captures[i].reviewMarks?[id] == .selected { captures[i].reviewMarks?.removeValue(forKey:id) }
        return word
    }
    public func finalReview(pageID:String)->(marked:[Recommendation],unmarked:[Recommendation]) {
        let all=Recommender.ranked(state:self,captureIDs:[pageID],showAll:true)
        let marked=all.filter{reviewMark($0.id,pageID:pageID) != nil}
        let unmarked=Recommender.ranked(state:self,captureIDs:[pageID]).filter{reviewMark($0.id,pageID:pageID)==nil}
        return (marked,unmarked)
    }
    public mutating func saveExample(occurrenceID: String, text: String, start: Int?, end: Int?) throws {
        guard let i = occurrences.firstIndex(where: { $0.id == occurrenceID }), let page = captures.first(where: { $0.id == occurrences[i].captureID }) else { return }
        guard !occurrences[i].surface.isEmpty, text.contains(occurrences[i].surface) else { throw StorageError.invalidArchive("Keep the target word in the example.") }
        if let start, let end {
            guard start >= 0, end <= page.text.unicodeScalars.count, start <= occurrences[i].start, end >= occurrences[i].end else { throw StorageError.invalidArchive("The context range must include this occurrence.") }
        }
        occurrences[i].sentence = text; occurrences[i].exampleStart = start; occurrences[i].exampleEnd = end; occurrences[i].manualExample = true
        occurrences[i].fragment = ExampleContext.isFragment(text: page.text, start: start, end: end)
    }
}

public struct ExampleContext: Equatable {
    public var start: Int
    public var end: Int
    public var draft: String
    public init(page: PageCapture, occurrence: Occurrence) {
        let bounds = Self.sentenceRange(text: page.text, start: occurrence.start, end: occurrence.end)
        var inferred = bounds
        if !occurrence.sentence.isEmpty {
            var cursor = page.text.startIndex
            while cursor < page.text.endIndex, let range = page.text.range(of:occurrence.sentence,range:cursor..<page.text.endIndex) {
                let a=page.text[..<range.lowerBound].unicodeScalars.count, b=page.text[..<range.upperBound].unicodeScalars.count
                if a<=occurrence.start && b>=occurrence.end { inferred=a..<b; break }; cursor=range.upperBound
            }
        }
        start = occurrence.exampleStart ?? inferred.lowerBound; end = occurrence.exampleEnd ?? inferred.upperBound
        draft = occurrence.sentence
    }
    private static let stops: Set<Unicode.Scalar> = ["。", "！", "？", "!", "?"]
    public static func sentenceRange(text: String, start: Int, end: Int) -> Range<Int> {
        let chars = Array(text.unicodeScalars)
        var a = min(max(0,start),chars.count), b = min(max(a,end),chars.count)
        while a > 0 && !stops.contains(chars[a-1]) { a -= 1 }
        if b == 0 || !stops.contains(chars[b-1]) {
            while b < chars.count && !stops.contains(chars[b]) { b += 1 }
            if b < chars.count { b += 1 }
        }
        return a..<b
    }
    public mutating func prepend(from text: String) {
        guard start > 0 else { return }
        let range = Self.sentenceRange(text: text, start: start-1, end: start)
        draft = JapaneseText.slice(text, range.lowerBound, start)+draft; start = range.lowerBound
    }
    public mutating func append(from text: String) {
        guard end < text.unicodeScalars.count else { return }
        let range = Self.sentenceRange(text: text, start: end, end: end+1)
        draft += JapaneseText.slice(text, end, range.upperBound); end = range.upperBound
    }
    public mutating func replaceRange(_ range: Range<Int>, from text: String) {
        start = range.lowerBound; end = range.upperBound; draft = JapaneseText.slice(text,start,end)
    }
    public static func isFragment(text: String, start: Int?, end: Int?) -> Bool {
        guard let start, let end else { return true }
        let chars = Array(text.unicodeScalars)
        return start == 0 || end == 0 || end > chars.count || !stops.contains(chars[end-1])
    }
}

public enum ParseGesture {
    public static func neighbors(of id: String, in occurrences: [Occurrence]) -> Set<String> {
        let ordered = occurrences.sorted { $0.start < $1.start }
        guard let i = ordered.firstIndex(where: { $0.id == id }) else { return [] }
        var result = Set<String>()
        if i > 0 { result.insert(ordered[i-1].id) }; if i+1 < ordered.count { result.insert(ordered[i+1].id) }
        return result
    }
    public static func mergeRange(_ first: Occurrence, _ second: Occurrence, in occurrences: [Occurrence]) throws -> Range<Int> {
        guard first.captureID == second.captureID, neighbors(of: first.id, in: occurrences).contains(second.id) else { throw StorageError.invalidArchive("Drag onto the preceding or following term.") }
        return min(first.start,second.start)..<max(first.end,second.end)
    }
    /// Split cursors use extended grapheme boundaries, then map back to scalar offsets.
    public static func segments(_ text: String, cuts: Set<Int>) -> [String] {
        let chars = Array(text), valid = cuts.filter { $0 > 0 && $0 < chars.count }.sorted()
        let points = [0]+valid+[chars.count]
        return zip(points,points.dropFirst()).map { String(chars[$0..<$1]) }
    }
}

/// Gesture decision state is independent of drawing and camera/OCR services.
public struct TermDragSession {
    public enum Result: Equatable { case split(String), merge(String,String), cancelled }
    public private(set) var sourceID:String?
    public private(set) var targetID:String?
    public private(set) var neighbors:Set<String>=[]
    public private(set) var moved=false
    public init() {}
    public mutating func begin(_ id:String,occurrences:[Occurrence]) { sourceID=id; targetID=nil; moved=false; neighbors=ParseGesture.neighbors(of:id,in:occurrences) }
    public mutating func update(distance:Double,candidate:String?) {
        guard sourceID != nil else { return }
        if distance>8 { moved=true }
        targetID=candidate.flatMap { neighbors.contains($0) ? $0 : nil }
    }
    public mutating func end()->Result {
        defer { cancel() }
        guard let sourceID else { return .cancelled }
        if !moved { return .split(sourceID) }
        guard let targetID else { return .cancelled }
        return .merge(sourceID,targetID)
    }
    public mutating func cancel() { sourceID=nil; targetID=nil; neighbors=[]; moved=false }
}
