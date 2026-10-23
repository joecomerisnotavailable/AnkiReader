import Foundation

/// Conservative near-duplicate check for repeated photos of the same prose page.
/// Short captures keep their original byte fingerprint to avoid collapsing snippets.
public enum PageIdentity {
    public static func samePage(_ left: String, _ right: String) -> Bool {
        let a = Array(left.filter { !$0.isWhitespace }), b = Array(right.filter { !$0.isWhitespace })
        guard min(a.count,b.count) >= 100, Double(min(a.count,b.count))/Double(max(a.count,b.count)) >= 0.9 else { return false }
        func grams(_ chars: [Character]) -> Set<String> {
            Set((0...(chars.count-5)).map { String(chars[$0..<$0+5]) })
        }
        let aa = grams(a), bb = grams(b)
        return Double(aa.intersection(bb).count)/Double(max(1,aa.union(bb).count)) >= 0.92
    }
}
