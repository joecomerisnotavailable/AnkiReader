import Foundation

public struct PitchPattern:Codable,Hashable,Sendable {
    public var position:Int
    public var label:String
}
public enum PitchAccent {
    public static func morae(_ reading:String)->[String] {
        var values:[String]=[]
        let small=Set("ゃゅょぁぃぅぇぉゎ")
        for character in JapaneseText.kana(reading).precomposedStringWithCanonicalMapping {
            if small.contains(character),!values.isEmpty { values[values.count-1].append(character) }
            else { values.append(String(character)) }
        }
        return values
    }
    /// Includes a final particle point to distinguish unaccented and final-mora drop.
    public static func heights(moraCount:Int,drop:Int)->[Bool] {
        guard moraCount>0,drop>=0,drop<=moraCount else { return [] }
        return (0...moraCount).map { i in i==0 ? drop==1 : drop==0 || i<drop }
    }
}
public final class PitchIndex {
    private let database:Database
    private let available:Bool
    public init(url:URL)throws {
        database=try Database(url:url,readOnly:true)
        available = !(try database.rows("SELECT name FROM sqlite_master WHERE name='pitch'")).isEmpty
    }
    public func lookup(expression:String,reading:String)throws->[PitchPattern] {
        guard available else { return [] }
        let rows=try database.rows("SELECT patterns FROM pitch WHERE form=? AND reading=?",values:[expression,JapaneseText.kana(reading)])
        let count=PitchAccent.morae(reading).count
        return try rows.flatMap { try JSONDecoder().decode([PitchPattern].self,from:Data($0[0].utf8)) }.filter{$0.position>=0 && $0.position<=count}
    }
}
