import Foundation
import Vision
import ImageIO
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let selected=try JSONDecoder().decode([String].self,from:Data(contentsOf:root.appendingPathComponent("novel-selection.json")))
var results:[[String:Any]]=[]
for name in selected {
    let start=Date()
    let request=VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages=["ja-JP","en-US"]
    request.usesLanguageCorrection=true
    do {
        try VNImageRequestHandler(url:root.appendingPathComponent("normalized").appendingPathComponent(name)).perform([request])
        let lines=(request.results ?? []).compactMap { o -> [String:Any]? in
            guard let t=o.topCandidates(1).first else{return nil}
            return ["text":t.string,"confidence":t.confidence,"x":o.boundingBox.minX,"y":1-o.boundingBox.maxY,"width":o.boundingBox.width,"height":o.boundingBox.height]
        }
        results.append(["image":name,"seconds":Date().timeIntervalSince(start),"lines":lines])
        print("\(name): \(lines.count) lines, \(String(format:"%.2f",Date().timeIntervalSince(start)))s")
    } catch { results.append(["image":name,"error":error.localizedDescription]) }
    try JSONSerialization.data(withJSONObject:results,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("vision-mac.json"),options:.atomic)
}
