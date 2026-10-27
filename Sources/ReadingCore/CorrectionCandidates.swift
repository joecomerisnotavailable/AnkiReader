import Foundation
public enum CorrectionCandidates {
    public static func characterReplacement(original:String,offset:Int,length:Int,candidate:String)->String? {
        guard candidate.count==1,!candidate.allSatisfy(\.isWhitespace),offset>=0,length>0,offset+length<=original.unicodeScalars.count else { return nil }
        return JapaneseText.slice(original,0,offset)+candidate+JapaneseText.slice(original,offset+length,original.unicodeScalars.count)
    }

    /// Accept only exact surrounding context. Ambiguous crop recognition remains
    /// available as copyable text, never as an automatic source replacement.
    public static func replacement(candidate:String,context:String,start:Int,end:Int)->String? {
        guard start>=0,end<=context.unicodeScalars.count,start<end else { return nil }
        let prefix=JapaneseText.slice(context,0,start),suffix=JapaneseText.slice(context,end,context.unicodeScalars.count)
        guard candidate.hasPrefix(prefix),candidate.hasSuffix(suffix),candidate.unicodeScalars.count>prefix.unicodeScalars.count+suffix.unicodeScalars.count else { return nil }
        let value=JapaneseText.slice(candidate,prefix.unicodeScalars.count,candidate.unicodeScalars.count-suffix.unicodeScalars.count)
        return value.isEmpty ? nil : value
    }
}
