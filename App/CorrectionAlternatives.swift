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
    static func crop(page:PageCapture,target:Occurrence,all:[Occurrence],url:URL,context:Bool)->CorrectionCrop? {
        guard page.photoRemoved != true,let image=UIImage(contentsOfFile:url.path)?.normalized(),let cg=image.cgImage else { return nil }
        let window=context ? CorrectionMapping.window(target,in:all,text:page.text) : target.start..<target.end
        var anchor=target;anchor.start=window.lowerBound;anchor.end=window.upperBound
        let raw=TermGeometry.regions(page:page,occurrences:[anchor])
        let regions=PhotoRaster.make(cg).map{InkGeometry.refine(raw,raster:$0)} ?? raw
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
        let key="\(page.id):\(page.textRevision ?? 0):\(target.start):\(target.end)"
        if let saved=cache[key] { return saved }
        let result=try await Task.detached(priority:.userInitiated) { () throws -> [PhotoCorrectionCandidate] in
            guard let crop=CorrectionPhoto.crop(page:page,target:target,all:all,url:url,context:true),let cg=crop.image.cgImage else { throw StorageError.invalidArchive("The photo or this text's location is unavailable. You can still type or draw the correction.") }
            let started=Date()
            defer { Logger(subsystem:"ReadingCompanion",category:"correction").info("Crop alternatives duration: \(Date().timeIntervalSince(started),privacy:.public) seconds") }
            let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate
            request.recognitionLanguages=["ja-JP","en-US"];request.usesLanguageCorrection=false
            _ = try? VNImageRequestHandler(cgImage:cg,orientation:.up).perform([request])
            let observations=(request.results ?? []).sorted { a,b in
                if page.layout=="Horizontal" { return a.boundingBox.midY>b.boundingBox.midY }
                return a.boundingBox.midX>b.boundingBox.midX
            }
            var proposals:[(String,String)]=[]
            for rank in 0..<5 {
                let parts=observations.compactMap { observation -> String? in
                    let candidates=observation.topCandidates(5)
                    return (rank<candidates.count ? candidates[rank] : candidates.first)?.string
                }
                if !parts.isEmpty { proposals.append((parts.joined(),"Vision")) }
            }
            // One retry on the local crop; never replaces capture recognition.
            if let ml=try? GoogleRecognizer().recognize(crop.image,layout:page.layout=="Horizontal" ? .horizontal : .vertical) { proposals.append((ml.text,"ML Kit crop")) }
            var seen=Set<String>()
            return proposals.compactMap { text,engine -> PhotoCorrectionCandidate? in
                let clean=text.trimmingCharacters(in:.whitespacesAndNewlines)
                guard !clean.isEmpty,seen.insert(clean).inserted else { return nil }
                let replacement=CorrectionCandidates.replacement(candidate:clean,context:crop.text,start:target.start-crop.start,end:target.end-crop.start)
                return PhotoCorrectionCandidate(text:clean,replacement:replacement,engine:engine)
            }.prefix(5).map{$0}
        }.value
        if cache.count>=32 { cache.removeAll() };cache[key]=result
        return result
    }
}
