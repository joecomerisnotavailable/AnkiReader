import Foundation

/// Layout-only repair; the engine's raw lines remain available on the capture.
public enum PageLayoutRepair {
    public static func ordered(_ input: [TextLine], vertical: Bool) -> [TextLine] {
        func compact(_ text: String) -> String { text.filter { !$0.isWhitespace } }
        func overlap(_ a: Region, _ b: Region) -> Double {
            let width = max(0, min(a.x+a.width, b.x+b.width)-max(a.x,b.x))
            let height = max(0, min(a.y+a.height, b.y+b.height)-max(a.y,b.y))
            return width*height / max(0.000001, min(a.width*a.height,b.width*b.height))
        }
        // Some engine results contain a whole column and its smaller sublines.
        // Suppress only a geometrically contained, text-identical repetition.
        let lines = input.enumerated().filter { i, line in
            let text = compact(line.text)
            return !input.enumerated().contains { j, other in
                let candidate = compact(other.text)
                return i != j && !text.isEmpty && candidate.contains(text) && overlap(line.region, other.region) > 0.85 &&
                    (candidate.count > text.count || (candidate.count == text.count && j < i))
            }
        }.map(\.element)
        let sizes = lines.map { vertical ? $0.region.width : $0.region.height }.sorted()
        let median = sizes.isEmpty ? 0 : sizes[sizes.count/2]
        var result = lines
        for i in result.indices {
            let line = result[i], size = vertical ? line.region.width : line.region.height
            let text = compact(line.text)
            let kanaOnly = !text.isEmpty && text.unicodeScalars.allSatisfy { (0x3041...0x3096).contains($0.value) || (0x30a1...0x30fa).contains($0.value) || $0.value == 0x30fc }
            // Width alone misclassified complete body sentences in the saved iPhone run.
            result[i].isRuby = kanaOnly && text.count <= 12 && median > 0 && size < median*0.5 && lines.contains { other in
                guard other.id != line.id else { return false }
                if vertical {
                    return other.region.width >= median*0.85 && abs(line.region.x-(other.region.x+other.region.width)) < median*0.65 && line.region.y >= other.region.y-0.01 && line.region.y+line.region.height <= other.region.y+other.region.height+0.01
                }
                return other.region.height >= median*0.85 && abs(line.region.y+line.region.height-other.region.y) < median*0.65 && line.region.x >= other.region.x-0.01 && line.region.x+line.region.width <= other.region.x+other.region.width+0.01
            }
        }
        // Build explicit column/row clusters; a pairwise tolerance comparator is not transitive.
        let primary = result.sorted { vertical ? $0.region.x > $1.region.x : $0.region.y < $1.region.y }
        var groups: [[TextLine]] = []
        for line in primary {
            let center = vertical ? line.region.x+line.region.width/2 : line.region.y+line.region.height/2
            if let index = groups.firstIndex(where: { group in
                let anchor = group[0].region
                let other = vertical ? anchor.x+anchor.width/2 : anchor.y+anchor.height/2
                return abs(center-other) <= max(median*0.55, 0.002)
            }) { groups[index].append(line) } else { groups.append([line]) }
        }
        return groups.flatMap { group in group.sorted { vertical ? $0.region.y < $1.region.y : $0.region.x < $1.region.x } }
    }
}
