import XCTest
@testable import ReadingCore

private enum ReferenceRecommender {
    public static func ranked(state:LibraryState,captureIDs:Set<String>,showAll:Bool = false) -> [Recommendation] {
        let groups=Dictionary(grouping:state.occurrences.filter { o in
            captureIDs.contains(o.captureID) && (showAll || o.selected || !(state.captures.first { $0.id == o.captureID }?.excludedLexemeIDs?.contains(o.lexemeID) ?? false))
        },by:\.lexemeID)
        return groups.compactMap { id,occurrences -> Recommendation? in
            guard let lexeme=state.lexemes[id] else { return nil }
            let selected=occurrences.contains{$0.selected}
            let known=state.knowledge[id]?.isKnown ?? false
            let basic=state.basicWords.contains(lexeme.expression)
            let stop=["助詞","助動詞","補助記号","空白"].contains{lexeme.partOfSpeech.hasPrefix($0)}
            if !showAll && !selected && (known || basic || stop || state.retained[id] != nil) { return nil }
            let best=occurrences.sorted { a,b in
                if a.selected != b.selected { return a.selected }
                if a.fragment != b.fragment { return !a.fragment }
                let au=unknownCount(a,state),bu=unknownCount(b,state)
                if au != bu { return au<bu }
                return a.sentence.count<b.sentence.count
            }.first!
            let sourceIDs=Set(state.captures.filter{captureIDs.contains($0.id)}.compactMap{c in state.sessions.first{$0.id==c.sessionID}?.source})
            let relevantPages=Dictionary(uniqueKeysWithValues:state.captures.filter { c in
                c.created.timeIntervalSinceNow > -30*86400 || state.sessions.contains{$0.id==c.sessionID && sourceIDs.contains($0.source)}
            }.map{($0.id,$0.fingerprint)})
            let distinct=Set(state.occurrences.filter{$0.lexemeID==id}.compactMap{relevantPages[$0.captureID]}).count
            let unknown=unknownCount(best,state)
            let accessibility=1.0/Double(max(1,unknown)) * (best.fragment ? 0.7 : 1)
            let score=0.45*lexeme.commonness+0.35*min(1,Double(max(0,distinct-1))/4)+0.20*accessibility
            var reasons:[String]=[]
            if lexeme.commonness>=0.7 { reasons.append("Common") }
            if distinct>1 { reasons.append("Seen on \(distinct) pages") }
            if unknown<=1 { reasons.append("Only estimated unknown") }
            if known { reasons.append("Known") }; if basic { reasons.append("Basic") }
            return Recommendation(lexeme:lexeme,occurrence:best,score:score,reasons:reasons,secondary:lexeme.uncertain == true || lexeme.dictionaryID==nil || lexeme.partOfSpeech.contains("固有名詞") || (best.confidence ?? 1)<0.5,selected:selected)
        }.sorted {
            if $0.selected != $1.selected { return $0.selected }
            if $0.secondary != $1.secondary { return !$0.secondary }
            if $0.score != $1.score { return $0.score>$1.score }
            return $0.id<$1.id
        }
    }
    private static func unknownCount(_ occurrence:Occurrence,_ state:LibraryState) -> Int {
        Set(state.occurrences.filter{$0.captureID==occurrence.captureID && $0.sentence==occurrence.sentence}.filter { o in
            guard let l=state.lexemes[o.lexemeID] else { return true }
            return !(state.knowledge[l.id]?.isKnown ?? false) && !state.basicWords.contains(l.expression) && !["助詞","助動詞","補助記号","空白"].contains{l.partOfSpeech.hasPrefix($0)}
        }.map(\.lexemeID)).count
    }
}

final class RecommendationPerformanceTests:XCTestCase {
    func testIndexedRankingMatchesOriginal() throws {
        var state=LibraryState()
        let session=ReadingSession(source:"Novel");state.sessions=[session]
        for p in 0..<12 {
            var page=PageCapture(sessionID:session.id,imagePath:"p",fingerprint:"page-\(p/2)")
            page.created=Date().addingTimeInterval(-Double(p)*86400)
            for n in 0..<100 {
                let id="word-\(n%37)"
                state.lexemes[id]=Lexeme(id:id,expression:id,commonness:Double(n%10)/10,partOfSpeech:n%11==0 ? "助詞" : "名詞",dictionaryID:id)
                var o=Occurrence(captureID:page.id,lexemeID:id,surface:id,start:n,end:n+1,sentence:"Sentence \(n/10)",fragment:n%3==0)
                o.selected=n%23==0
                state.occurrences.append(o)
            }
            page.excludedLexemeIDs=["word-2"]
            state.captures.append(page)
        }
        state.basicWords=["word-3"]
        try compare(state)
    }
    func testSavedLibraryTimingAndEquivalence() throws {
        guard let path=ProcessInfo.processInfo.environment["EDIT_PERFORMANCE_LIBRARY"] else { return }
        let state=try JSONDecoder().decode(LibraryState.self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        try compare(state)
    }
    private func compare(_ state:LibraryState) throws {
        let ids=Set(state.captures.prefix(2).map(\.id))
        for showAll in [false,true] {
            let start=Date();let before=ReferenceRecommender.ranked(state:state,captureIDs:ids,showAll:showAll)
            let oldTime=Date().timeIntervalSince(start)
            let next=Date();let after=Recommender.ranked(state:state,captureIDs:ids,showAll:showAll)
            let newTime=Date().timeIntervalSince(next)
            XCTAssertEqual(before.map(\.id),after.map(\.id))
            for (a,b) in zip(before,after) {
                XCTAssertEqual(a.occurrence.id,b.occurrence.id);XCTAssertEqual(a.score,b.score)
                XCTAssertEqual(a.reasons,b.reasons);XCTAssertEqual(a.selected,b.selected);XCTAssertEqual(a.secondary,b.secondary)
            }
            print("Ranking \(state.occurrences.count) occurrences, showAll=\(showAll): original \(oldTime*1000) ms, indexed \(newTime*1000) ms")
        }
    }
}
