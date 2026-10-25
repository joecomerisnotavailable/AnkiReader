import Foundation

public struct AnalyzedPage: Sendable {
    public var recognition: Recognition
    public var lexemes: [Lexeme]
    public var occurrences: [Occurrence]
}

public enum ReadingPipeline {
    public static func analyze(captureID: String, recognition: Recognition, text: String? = nil,
                               tokenizer: MorphologicalAnalyzer, dictionary: DictionaryIndex, preferences: [String: Lexeme] = [:]) throws -> AnalyzedPage {
        let body = text ?? recognition.text
        var offsets: [(String, Int, Int, Double?)] = []
        var cursor = 0
        if text == nil {
            for line in recognition.lines where !line.isRuby {
                let end = cursor + line.text.unicodeScalars.count
                offsets.append((line.id, cursor, end, line.confidence)); cursor = end
            }
        }
        var words: [String: Lexeme] = [:], occurrences: [Occurrence] = []
        for token in try tokenizer.tokenize(body) {
            guard !token.surface.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var word = try dictionary.resolve(token)
            if let preference = preferences[token.surface], !preference.reading.isEmpty,
               JapaneseText.kana(preference.reading) == JapaneseText.kana(token.reading) { word = preference }
            word.partOfSpeech = token.partOfSpeech
            words[word.id] = word
            let example = JapaneseText.example(text: body, start: token.start, end: token.end)
            let lines = offsets.filter { $0.1 < token.end && $0.2 > token.start }
            occurrences.append(Occurrence(captureID: captureID, lexemeID: word.id, surface: token.surface,
                start: token.start, end: token.end, lineIDs: lines.map { $0.0 }, sentence: example.0,
                fragment: example.1, confidence: lines.compactMap { $0.3 }.min()))
        }
        return AnalyzedPage(recognition: recognition, lexemes: Array(words.values), occurrences: occurrences)
    }
}

extension LibraryState {
    /// Reprocessing replaces machine output only. Explicit repairs and selections survive.
    public mutating func apply(_ page: AnalyzedPage, captureID: String) {
        guard let index = captures.firstIndex(where: { $0.id == captureID }) else { return }
        let old = occurrences.filter { $0.captureID == captureID }
        let selected = Set(old.filter(\.selected).map(\.lexemeID))
        let repaired = old.filter { previous in
            previous.corrected || previous.manualExample == true || (previous.selected && !page.occurrences.contains { $0.lexemeID == previous.lexemeID })
        }
        occurrences.removeAll { $0.captureID == captureID }
        occurrences += repaired
        for var occurrence in page.occurrences {
            if repaired.contains(where: { $0.start < occurrence.end && $0.end > occurrence.start }) { continue }
            occurrence.selected = selected.contains(occurrence.lexemeID)
            occurrences.append(occurrence)
        }
        for word in page.lexemes where !repaired.contains(where: { $0.lexemeID == word.id }) { lexemes[word.id] = word }
        captures[index].recognition = page.recognition
        captures[index].processingVersion = "mlkit-8.0.0-layout-2-sudachi-0.6.10-jmdict-v1"
        let source = sessions.first { $0.id == captures[index].sessionID }?.source
        if let prior = captures.first(where: { other in
            other.id != captureID && other.status == .ready && sessions.first { $0.id == other.sessionID }?.source == source && PageIdentity.samePage(other.text, captures[index].text)
        }) { captures[index].fingerprint = prior.fingerprint }
        captures[index].status = .ready
        captures[index].error = nil
    }

    public mutating func select(_ lexemeID: String, occurrenceID: String, pages: Set<String>, selected: Bool) {
        migratePhotoReviews()
        for i in captures.indices where pages.contains(captures[i].id) {
            if selected { captures[i].reviewMarks?[lexemeID] = .selected }
            else if captures[i].reviewMarks?[lexemeID] == .selected { captures[i].reviewMarks?.removeValue(forKey:lexemeID) }
        }
        if selected {
            for i in captures.indices where pages.contains(captures[i].id) { captures[i].excludedLexemeIDs?.remove(lexemeID) }
        }
        for i in occurrences.indices where occurrences[i].lexemeID == lexemeID && pages.contains(occurrences[i].captureID) {
            occurrences[i].selected = selected && occurrences[i].id == occurrenceID
        }
    }
}

extension LibraryState {
    public mutating func editText(captureID: String, text: String) throws {
        guard let pageIndex = captures.firstIndex(where: { $0.id == captureID }) else { return }
        let original = captures[pageIndex].text
        // Rebase explicit edits only when their original anchor remains unambiguous.
        // A conflicting edit is rejected instead of silently losing a selection.
        var rebased = occurrences
        for i in occurrences.indices where occurrences[i].captureID == captureID && (occurrences[i].corrected || occurrences[i].selected || occurrences[i].manualExample == true) {
            let anchor = JapaneseText.slice(original, occurrences[i].start, occurrences[i].end)
            guard !anchor.isEmpty, let range = text.range(of: anchor), text[range.upperBound...].range(of: anchor) == nil else {
                throw StorageError.invalidArchive("This edit conflicts with a selected or corrected occurrence of ‘\(occurrences[i].surface)’. Deselect it or keep its original text unambiguous before applying the page edit.")
            }
            rebased[i].start = text[..<range.lowerBound].unicodeScalars.count
            rebased[i].end = rebased[i].start+anchor.unicodeScalars.count
            rebased[i].lineIDs = []
            // The draft is independent of page text. Rebase its source range only
            // when the complete saved context still has one unambiguous anchor.
            rebased[i].exampleStart = nil
            rebased[i].exampleEnd = nil
            if let start = occurrences[i].exampleStart, let end = occurrences[i].exampleEnd {
                let context = JapaneseText.slice(original, start, end)
                if !context.isEmpty, let source = text.range(of: context),
                   text[source.upperBound...].range(of: context) == nil {
                    rebased[i].exampleStart = text[..<source.lowerBound].unicodeScalars.count
                    rebased[i].exampleEnd = text[..<source.upperBound].unicodeScalars.count
                }
            }
        }
        occurrences = rebased
        if captures[pageIndex].sourceMap != nil {
            let mapped=CorrectionMapping.rebasePageEdit(captures[pageIndex],to:text)
            captures[pageIndex].sourceMap=mapped.0;captures[pageIndex].corrections=mapped.1
        }
        captures[pageIndex].textRevision=(captures[pageIndex].textRevision ?? 0)+1
        captures[pageIndex].correctedText = text
        captures[pageIndex].status = .pending
    }
    public mutating func replaceSegments(captureID: String, start: Int, end: Int, surfaces: [String], words: [Lexeme]) throws {
        guard let page = captures.first(where: { $0.id == captureID }), surfaces.count == words.count,
              !surfaces.isEmpty, !surfaces.contains(where: \.isEmpty),
              surfaces.joined() == JapaneseText.slice(page.text, start, end) else { throw StorageError.invalidArchive("Keep the original text when changing cuts. Use Edit page text to correct OCR first.") }
        let old = occurrences.filter { $0.captureID == captureID && $0.start < end && $0.end > start }
        guard !old.contains(where: { $0.start < start || $0.end > end }) else { throw StorageError.invalidArchive("Include the whole word at both edges before changing cuts.") }
        occurrences.removeAll { $0.captureID == captureID && $0.start < end && $0.end > start }
        var offset = start
        for (surface, word) in zip(surfaces, words) {
            let next = offset+surface.unicodeScalars.count
            let example = JapaneseText.example(text: page.text, start: offset, end: next)
            let overlapping = old.filter { $0.start < next && $0.end > offset }
            var occurrence = Occurrence(captureID: captureID, lexemeID: word.id, surface: surface, start: offset, end: next, lineIDs: Array(Set(overlapping.flatMap(\.lineIDs))), sentence: example.0, fragment: example.1)
            occurrence.corrected = true; occurrence.selected = overlapping.contains( where: \.selected)
            let saved=overlapping.flatMap(\.preservedExamples)
            occurrence.exampleAlternatives=Array(Set(saved))
            if let manual=overlapping.first(where:{$0.manualExample == true}) { occurrence.sentence=manual.sentence;occurrence.manualExample=true }
            occurrences.append(occurrence); lexemes[word.id] = word; offset = next
        }
    }
}
