import Foundation
import UIKit
#if !UI_FIXTURE
import SwiftyTesseract
#endif

/// Runs on ReadingWorker's serial queue. Reuses ML Kit's column locations;
/// retries only short, pixel-bounded pieces of inconsistent long columns.
final class ColumnRecognitionRefiner {
    #if !UI_FIXTURE
    private var engines: [Bool:Tesseract] = [:]
    #endif
    func refine(_ recognition:Recognition,image:UIImage,vertical:Bool,preferredLineID:String? = nil,preferredLineFraction:Double? = nil) throws -> Recognition {
        #if UI_FIXTURE
        return recognition
        #else
        let started=Date()
        guard let cg=image.cgImage,let raster=PhotoRaster.make(cg,maximumDimension:4096) else { return recognition }
        var result=recognition
        // Profile lazily, focus first, with separate planning and retry budgets.
        // Scanning a long page must not consume all time available for a crop.
        var order=Array(recognition.lines.indices)
        if let index=order.first(where:{recognition.lines[$0].id==preferredLineID}) {
            order.removeAll{$0==index};order.insert(index,at:0)
        }
        var planningTime:TimeInterval=0,retryTime:TimeInterval=0,retries=0,columns=0
        for index in order {
            guard planningTime<0.4,retryTime<1.5,retries<12,columns<2 else { break }
            let line=recognition.lines[index]
            guard !line.isRuby,line.text.count>=14 else { continue }
            // Already fine-grained results do not need another recognition pass.
            guard (line.elements ?? []).contains(where:{$0.text.count>=12}) else { continue }
            let planningStart=Date()
            let measured=InkColumnProfile.measure(corners:line.corners ?? TermGeometry.rectangle(line.region),vertical:vertical,raster:raster)
            planningTime += Date().timeIntervalSince(planningStart)
            guard let profile=measured else { continue }
            let estimate=1/profile.pitchFraction
            let discrepancy=abs(Double(line.text.count)-estimate)/max(1,estimate)
            let mixed=line.text.unicodeScalars.contains{$0.isASCII && CharacterSet.alphanumerics.contains($0)}
            guard discrepancy>0.045 || mixed else { continue }
            columns += 1
            let q=TermGeometry.pageCorners(line.corners ?? TermGeometry.rectangle(line.region))
            var chunks=[RecognitionRefinement.Chunk]()
            var planned=profile.chunks
            if line.id==preferredLineID,let focus=preferredLineFraction {
                planned.sort { abs(($0.from+$0.to)/2-focus)<abs(($1.from+$1.to)/2-focus) }
            }
            for chunk in planned {
                if retries>=12 || retryTime>1.5 { break }
                let retryStart=Date()
                defer {retryTime += Date().timeIntervalSince(retryStart)}
                guard let crop=crop(raster:raster,corners:q,vertical:vertical,from:chunk.from,to:chunk.to),let data=crop.pngData() else { continue }
                if engines[vertical]==nil {
                    engines[vertical]=Tesseract(language:vertical ? .custom("jpn_vert") : .japanese) {
                        set("tessedit_pageseg_mode",value:"7")
                    }
                }
                retries += 1
                guard let raw=try? engines[vertical]!.performOCR(on:data).get() else { continue }
                let text=raw.filter{!$0.isWhitespace}
                guard text.count>=4,text.count<=12,abs(Double(text.count)-chunk.estimatedCells)<=0.7 else { continue }
                let quad=TermGeometry.slice(q,from:chunk.from,to:chunk.to,vertical:vertical)
                let anchor=CharacterAnchor(corners:quad,text:text,vertical:vertical)
                guard let fit=CharacterCellGeometry.fit(anchor,raster:raster),fit.clear.filter({$0}).count>=max(3,Int(Double(text.count+1)*0.75)) else { continue }
                let cells=(0..<text.count).map{TermGeometry.slice(quad,from:fit.boundaries[$0],to:fit.boundaries[$0+1],vertical:vertical)}
                chunks.append(.init(text:text,from:chunk.from,to:chunk.to,cells:cells,estimatedCellCount:chunk.estimatedCells,clearBoundaries:fit.clear))
            }
            result.lines[index]=RecognitionRefinement.refine(line:line,chunks:chunks,vertical:vertical)
        }
        if result.rawLines==nil { result.rawLines=recognition.lines }
        result.elapsed += Date().timeIntervalSince(started)
        return result
        #endif
    }
    private func crop(raster:PageRaster,corners q:[ImagePoint],vertical:Bool,from:Double,to:Double)->UIImage? {
        guard let crop=InkColumnProfile.crop(raster:raster,corners:q,vertical:vertical,from:from,to:to) else { return nil }
        let pixels=crop.pixels,w=crop.width,h=crop.height
        guard let provider=CGDataProvider(data:Data(pixels) as CFData),let image=CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent) else { return nil }
        return UIImage(cgImage:image)
    }
}
