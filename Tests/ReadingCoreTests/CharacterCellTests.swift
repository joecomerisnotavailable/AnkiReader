import XCTest
@testable import ReadingCore
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

final class CharacterCellTests:XCTestCase {
    func testSharedCellsPreservePunctuationAndBothDirections() throws {
        for vertical in [true,false] {
            var pixels=[UInt8](repeating:255,count:240*240)
            // Four full-pitch cells. The second glyph is a tiny punctuation mark.
            for cell in 0..<4 {
                let along=40+cell*40
                for a in (along+6)..<(along+(cell==1 ? 12 : 34)) {
                    for b in 80..<(cell==1 ? 87 : 114) {
                        pixels[vertical ? a*240+b : b*240+a]=20
                    }
                }
            }
            let box=vertical ? Region(x:80.0/240,y:40.0/240,width:34.0/240,height:160.0/240) : Region(x:40.0/240,y:80.0/240,width:160.0/240,height:34.0/240)
            let anchor=CharacterAnchor(corners:TermGeometry.rectangle(box),text:"私。日本",vertical:vertical)
            let fit=try XCTUnwrap(CharacterCellGeometry.fit(anchor,raster:PageRaster(width:240,height:240,pixels:pixels)))
            XCTAssertEqual(fit.boundaries.count,5)
            for i in 0..<4 { XCTAssertEqual(fit.boundaries[i+1]-fit.boundaries[i],0.25,accuracy:0.04) }
            let left=TermRegion(id:"a",occurrenceID:"a",corners:anchor.corners,estimated:true,vertical:vertical,anchor:anchor,characterStart:0,characterEnd:2)
            let right=TermRegion(id:"b",occurrenceID:"b",corners:anchor.corners,estimated:true,vertical:vertical,anchor:anchor,characterStart:2,characterEnd:4)
            let refined=InkGeometry.refine([left,right],raster:PageRaster(width:240,height:240,pixels:pixels))
            var cache=InkGeometryCache()
            let raster=PageRaster(width:240,height:240,pixels:pixels)
            _=InkGeometry.refine([left],raster:raster,cache:&cache)
            // A segmentation edit reuses the same OCR anchor but introduces new regions.
            let warm=InkGeometry.refine([left,right],raster:raster,cache:&cache)
            XCTAssertEqual(warm,refined)
            let changed=CharacterAnchor(corners:anchor.corners,text:"私。日",vertical:vertical)
            var edited=right;edited.anchor=changed;edited.characterEnd=3
            XCTAssertEqual(InkGeometry.refine([edited],raster:raster,cache:&cache),InkGeometry.refine([edited],raster:raster))
            XCTAssertEqual(vertical ? refined[0].corners[3] : refined[0].corners[1],refined[1].corners[0])
        }
    }
    func testMLKitElementIsAnchorInsteadOfBroadLineBox() throws {
        var page=PageCapture(sessionID:"s",imagePath:"p",fingerprint:"p"); page.layout="Vertical"
        let elementQuad=[ImagePoint(x:0.5,y:0.1),ImagePoint(x:0.55,y:0.11),ImagePoint(x:0.51,y:0.51),ImagePoint(x:0.46,y:0.5)]
        var line=TextLine(text:"日本語",region:Region(x:0.1,y:0.1,width:0.6,height:0.7))
        line.elements=[TextElementGeometry(text:"日本語",start:0,end:3,corners:elementQuad)]
        page.recognition=Recognition(engine:"saved",lines:[line],elapsed:0)
        let term=Occurrence(captureID:page.id,lexemeID:"jp",surface:"本",start:1,end:2,sentence:"日本語",fragment:true)
        let region=try XCTUnwrap(TermGeometry.regions(page:page,occurrences:[term]).first)
        XCTAssertEqual(region.anchor?.corners,TermGeometry.pageCorners(elementQuad))
        XCTAssertEqual(region.characterStart,1); XCTAssertEqual(region.characterEnd,2)
        XCTAssertEqual(region.anchor?.text,"日本語")
    }
    func testRejectsBlankAndProportionalLatin() {
        let raster=PageRaster(width:100,height:100,pixels:[UInt8](repeating:255,count:10000))
        let q=TermGeometry.rectangle(Region(x:0.1,y:0.1,width:0.1,height:0.8))
        XCTAssertNil(CharacterCellGeometry.fit(CharacterAnchor(corners:q,text:"日本語",vertical:true),raster:raster))
        XCTAssertNil(CharacterCellGeometry.fit(CharacterAnchor(corners:q,text:"width",vertical:false),raster:raster))
    }

    // Opt-in local placement evaluation using saved OCR only; never invokes OCR.
    func testSavedPhotographs() throws {
        guard let root=ProcessInfo.processInfo.environment["PLACEMENT_CORPUS"] else { return }
        #if canImport(ImageIO)
        let data=try Data(contentsOf:URL(fileURLWithPath:root+"/iphone-benchmark-report.json"))
        let json=try JSONSerialization.jsonObject(with:data) as! [String:Any]
        var times:[Double]=[], accepted=0, total=0
        var output:[[String:Any]]=[]
        for run in json["runs"] as! [[String:Any]] where (run["engine"] as? String)=="ML Kit Japanese" {
            let url=URL(fileURLWithPath:root+"/"+(run["image"] as! String))
            guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:2048] as CFDictionary) else { continue }
            let scale=min(1,2048.0/Double(max(image.width,image.height))), w=Int(Double(image.width)*scale),h=Int(Double(image.height)*scale)
            var pixels=[UInt8](repeating:255,count:w*h)
            pixels.withUnsafeMutableBytes { buffer in
                let context=CGContext(data:buffer.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue)!
                context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
            }
            let recognition=try JSONDecoder().decode(Recognition.self,from:JSONSerialization.data(withJSONObject:run["recognition"]!))
            let raster=PageRaster(width:w,height:h,pixels:pixels), start=Date()
            for line in recognition.lines where !line.isRuby {
                total += 1
                let anchor=CharacterAnchor(corners:TermGeometry.rectangle(line.region),text:line.text,vertical:(run["layout"] as? String) != "Horizontal")
                if let fit=CharacterCellGeometry.fit(anchor,raster:raster) {
                    accepted += 1
                    output.append(["image":run["image"]!,"text":line.text,"vertical":anchor.vertical,"corners":anchor.corners.map{["x":$0.x,"y":$0.y]},"boundaries":fit.boundaries,"clear":fit.clear])
                }
            }
            times.append(Date().timeIntervalSince(start)*1000)
        }
        if let path=ProcessInfo.processInfo.environment["PLACEMENT_OUTPUT"] {
            try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
        }
        times.sort()
        print("SAVED PLACEMENT: photos=\(times.count), accepted grids=\(accepted)/\(total), median=\(times[times.count/2])ms, p95=\(times[min(times.count-1,Int(Double(times.count)*0.95))])ms (Mac; current build configuration; no OCR)")
        XCTAssertEqual(times.count,30)
        #endif
    }
}
