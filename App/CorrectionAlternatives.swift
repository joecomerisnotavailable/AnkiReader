import Foundation
import UIKit
import Vision
import os

struct PhotoCorrectionCandidate:Identifiable,Sendable {
    var id:String { text }
    var text:String
    var replacement:String?
    var engine:String
}
struct CorrectionCrop {
    var image:UIImage
    var text:String
    var start:Int
    var end:Int
}
enum CorrectionPhoto {
    static func crop(page:PageCapture,target:Occurrence,image:UIImage,raster:PageRaster?,cache:inout InkGeometryCache)->CorrectionCrop? {
        guard let cg=image.cgImage else { return nil }
        let window=target.start..<target.end
        var anchor=target;anchor.start=window.lowerBound;anchor.end=window.upperBound
        let raw=TermGeometry.regions(page:page,occurrences:[anchor])
        let regions=raster.map{InkGeometry.refine(raw,raster:$0,cache:&cache)} ?? raw
        let points=regions.flatMap(\.corners)
        guard let x=points.map(\.x).min(),let y=points.map(\.y).min(),let x2=points.map(\.x).max(),let y2=points.map(\.y).max() else { return nil }
        // Native normalized pixels, padding retains glyph edges without a full-page pass.
        let rect=CGRect(x:x*Double(cg.width),y:y*Double(cg.height),width:(x2-x)*Double(cg.width),height:(y2-y)*Double(cg.height)).insetBy(dx:-6,dy:-6).intersection(CGRect(x:0,y:0,width:cg.width,height:cg.height)).integral
        guard let clipped=cg.cropping(to:rect) else { return nil }
        return CorrectionCrop(image:UIImage(cgImage:clipped),text:JapaneseText.slice(page.text,window.lowerBound,window.upperBound),start:window.lowerBound,end:window.upperBound)
    }
}
actor PhotoCorrectionService {
    static let shared=PhotoCorrectionService()
    private var cache:[String:[PhotoCorrectionCandidate]]=[:]
    func candidates(page:PageCapture,target:Occurrence,all:[Occurrence],url:URL) async throws -> [PhotoCorrectionCandidate] {
        #if UI_FIXTURE
        if ProcessInfo.processInfo.arguments.contains("--alternatives-fixture") {
            return [PhotoCorrectionCandidate(text:"なだめる",replacement:"なだめる",engine:"fixture")]
        }
        #endif
        let key="\(page.id):\(page.textRevision ?? 0):\(target.start):\(target.end)"
        if let saved=cache[key] { return saved }
        let work=Task.detached(priority:.userInitiated) { () throws -> [PhotoCorrectionCandidate] in
            let original=JapaneseText.slice(page.text,target.start,target.end)
            guard original.count<=6 else { throw StorageError.invalidArchive("Select the character you want to correct in the text field, then try alternatives.") }
            guard page.photoRemoved != true,let image=UIImage(contentsOfFile:url.path)?.normalized(),let cg=image.cgImage else {
                throw StorageError.invalidArchive("The saved photo is unavailable. You can still type or draw the correction.")
            }
            let raster=PhotoRaster.make(cg)
            var geometryCache=InkGeometryCache(),foundCrop=false
            var offset=target.start,ranked:[(Int,PhotoCorrectionCandidate)]=[]
            for character in original {
                try Task.checkCancellation()
                let width=String(character).unicodeScalars.count
                var cell=target;cell.start=offset;cell.end=offset+width
                defer { offset += width }
                guard let crop=CorrectionPhoto.crop(page:page,target:cell,image:image,raster:raster,cache:&geometryCache),let cg=crop.image.cgImage else { continue }
                foundCrop=true
                let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
                request.recognitionLanguages=["ja-JP"];request.usesLanguageCorrection=false
                _ = try? VNImageRequestHandler(cgImage:cg,orientation:.up).perform([request])
                var values:[(String,String)]=[]
                for observation in request.results ?? [] {
                    values += observation.topCandidates(5).map{($0.string,"Vision character crop")}
                }
                try Task.checkCancellation()
                if let ml=try? GoogleRecognizer().recognize(crop.image,layout:page.layout=="Horizontal" ? .horizontal : .vertical) { values.append((ml.text,"ML Kit character crop")) }
                for (rank,pair) in values.enumerated() {
                    let candidate=pair.0.trimmingCharacters(in:.whitespacesAndNewlines)
                    guard candidate.count==1,candidate != String(character),
                          let changed=CorrectionCandidates.characterReplacement(original:original,offset:offset-target.start,length:width,candidate:candidate) else { continue }
                    ranked.append((rank,PhotoCorrectionCandidate(text:changed,replacement:changed,engine:pair.1)))
                }
            }
            guard foundCrop else { throw StorageError.invalidArchive("This character has no mapped photo location. You can still type or draw it.") }
            var seen=Set<String>()
            return ranked.sorted{$0.0<$1.0}.map(\.1).filter{seen.insert($0.text).inserted}.prefix(5).map{$0}
        }
        let result=try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
        if cache.count>=32 { cache.removeAll() };cache[key]=result
        return result
    }
}
