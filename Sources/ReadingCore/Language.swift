import Foundation

public enum JapaneseText {
    public static func kana(_ s:String) -> String { s.applyingTransform(.hiraganaToKatakana,reverse:true) ?? s }
    public static func clean(_ s:String) -> String {
        var text=s.replacingOccurrences(of:"<rt[^>]*>.*?</rt>",with:"",options:.regularExpression)
        text=text.replacingOccurrences(of:"<[^>]+>",with:"",options:.regularExpression)
        text=text.replacingOccurrences(of:"\\[[^\\]]*\\]",with:"",options:.regularExpression)
        for (a,b) in [("&nbsp;"," "),("&amp;","&"),("&lt;","<"),("&gt;",">"),("&quot;","\""),("&#39;","'")] { text=text.replacingOccurrences(of:a,with:b) }
        return text.trimmingCharacters(in:.whitespacesAndNewlines).precomposedStringWithCanonicalMapping
    }
    public static func slice(_ text:String,_ start:Int,_ end:Int) -> String {
        let scalars=Array(text.unicodeScalars); let a=max(0,min(start,scalars.count)); let b=max(a,min(end,scalars.count))
        return String(String.UnicodeScalarView(scalars[a..<b]))
    }
    public static func example(text:String,start:Int,end:Int) -> (String,Bool) {
        let chars=Array(text.unicodeScalars); let punctuation:Set<Unicode.Scalar>=["。","！","？","!","?"]
        var a=min(max(0,start),chars.count), b=min(max(end,a),chars.count)
        while a>0 && !punctuation.contains(chars[a-1]) { a-=1 }
        while b<chars.count && !punctuation.contains(chars[b]) { b+=1 }
        let completeEnd=b<chars.count || (b>0 && punctuation.contains(chars[b-1]))
        if b<chars.count { b+=1 }
        // Long punctuation-free OCR should not produce a page-sized flashcard.
        let clipped = b-a > 240
        if clipped { a = max(a, start-100); b = min(b, max(end, a+240)) }
        return (slice(text,a,b),a==0 || !completeEnd || clipped)
    }
}
public struct MorphToken: Codable, Sendable {
    public var surface:String; public var lemma:String; public var reading:String; public var partOfSpeech:String; public var start:Int; public var end:Int; public var unknown:Bool
}
public protocol MorphologicalAnalyzer { func tokenize(_ text:String) throws -> [MorphToken] }
public final class DictionaryIndex {
    private let db:Database
    public init(url:URL) throws { db=try Database(url:url,readOnly:true) }
    public func lookup(_ expression:String,reading:String? = nil, strictReading:Bool = false) throws -> [Lexeme] {
        let rows=try db.rows("SELECT DISTINCT e.id,e.expression,e.reading,e.definitions,e.commonness,e.pos FROM entries e JOIN forms f ON f.entry_id=e.id WHERE f.form=? LIMIT 40",values:[expression])
        let items=rows.compactMap { r -> Lexeme? in
            guard r.count==6 else { return nil }
            return Lexeme(id:r[0],expression:r[1],reading:r[2],definitions:(try? JSONDecoder().decode([String].self,from:Data(r[3].utf8))) ?? [],commonness:Double(r[4]) ?? 0.2,partOfSpeech:r[5],dictionaryID:r[0].components(separatedBy:":").first)
        }
        guard let reading, !reading.isEmpty else { return items }
        let matched=items.filter{JapaneseText.kana($0.reading)==JapaneseText.kana(reading)}
        return matched.isEmpty && !strictReading ? items : matched
    }
    public func resolve(_ token:MorphToken) throws -> Lexeme {
        let candidates=try lookup(token.lemma,reading:token.reading)
        if var first=candidates.first {
            first.uncertain = candidates.count > 1 || (!token.reading.isEmpty && JapaneseText.kana(first.reading) != JapaneseText.kana(token.reading))
            return first
        }
        let surfaceCandidates = try lookup(token.surface,reading:token.reading)
        if var surface=surfaceCandidates.first {
            surface.uncertain = surfaceCandidates.count > 1 || (!token.reading.isEmpty && JapaneseText.kana(surface.reading) != JapaneseText.kana(token.reading))
            return surface
        }
        return Lexeme(id:"custom:\(token.lemma):\(JapaneseText.kana(token.reading))",expression:token.lemma,reading:JapaneseText.kana(token.reading),partOfSpeech:token.partOfSpeech)
    }
}
public struct Recommendation: Identifiable {
    public var id:String { lexeme.id }; public var lexeme:Lexeme; public var occurrence:Occurrence; public var score:Double; public var reasons:[String]; public var secondary:Bool; public var selected:Bool
}
public enum Recommender {
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
