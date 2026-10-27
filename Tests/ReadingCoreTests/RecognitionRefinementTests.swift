import XCTest
@testable import ReadingCore
#if canImport(ImageIO)
import ImageIO
import CoreGraphics
#endif

final class RecognitionRefinementTests:XCTestCase {
    private func line(_ text:String)->TextLine {
        var value=TextLine(text:text,region:Region(x:0.3,y:0.1,width:0.05,height:0.8))
        value.corners=TermGeometry.rectangle(value.region)
        value.elements=[TextElementGeometry(text:text,start:0,end:text.unicodeScalars.count,corners:value.corners!)]
        return value
    }
    private func chunk(_ text:String,_ from:Double=0,_ to:Double=1)->RecognitionRefinement.Chunk {
        let quad=TermGeometry.slice(TermGeometry.rectangle(Region(x:0.3,y:0.1,width:0.05,height:0.8)),from:from,to:to,vertical:true)
        let cells=(0..<text.count).map{TermGeometry.slice(quad,from:Double($0)/Double(text.count),to:Double($0+1)/Double(text.count),vertical:true)}
        return .init(text:text,from:from,to:to,cells:cells,estimatedCellCount:Double(text.count))
    }
    func testMissingCharacterAndLocalGeometry() throws {
        let original=line("注目をめている"),proposal=chunk("注目を集めている")
        let result=RecognitionRefinement.refine(line:original,chunks:[proposal],vertical:true)
        XCTAssertEqual(result.text,"注目を集めている");XCTAssertEqual(result.id,original.id)
        XCTAssertEqual(original.text,"注目をめている")
        XCTAssertEqual(result.elements?.count,8)
        XCTAssertEqual(result.elements?[3].text,"集")
        XCTAssertEqual(result.elements?[0].corners,proposal.cells[0])
        XCTAssertEqual(result.elements?[1].corners,proposal.cells[1])
        XCTAssertTrue(result.elements!.allSatisfy{$0.estimated==true})
    }
    func testRefusesSubstitutionDeletionAmbiguityAndWrongCount() {
        let original=line("注目を乗めている")
        XCTAssertEqual(RecognitionRefinement.refine(line:original,chunks:[chunk("注目を集めている")],vertical:true),original)
        let repeated=line("注目をめている注目をめている")
        XCTAssertEqual(RecognitionRefinement.refine(line:repeated,chunks:[chunk("注目を集めている",0,0.5)],vertical:true),repeated)
        var wrong=chunk("注目を集めている");wrong.estimatedCellCount=6
        XCTAssertEqual(RecognitionRefinement.refine(line:line("注目をめている"),chunks:[wrong],vertical:true).text,"注目をめている")
        XCTAssertEqual(RecognitionRefinement.refine(line:line("日本のの学校"),chunks:[chunk("日本の学校")],vertical:true).text,"日本のの学校")
    }
    func testOffsetsAndFallbacksPreserveMixedText() throws {
        let original=line("U-kuな、注目をめている新鋭の水彩")
        let value=RecognitionRefinement.refine(line:original,chunks:[chunk("な、注目を集めている",4.0/18,13.0/18)],vertical:true)
        XCTAssertEqual(value.text,"U-kuな、注目を集めている新鋭の水彩")
        for element in value.elements! { XCTAssertEqual(JapaneseText.slice(value.text,element.start,element.end),element.text) }
        let sorted=value.elements!.sorted{$0.start<$1.start}
        XCTAssertEqual(sorted.first?.start,0)
        XCTAssertEqual(sorted.last?.end,value.text.unicodeScalars.count)
        for pair in zip(sorted,sorted.dropFirst()) { XCTAssertEqual(pair.0.end,pair.1.start) }
    }
    func testRefinedCellsDrawOneHighlightPerTermWithoutRefitting() throws {
        for vertical in [true,false] {
            var original=line("注目をめている")
            let q=vertical ? [ImagePoint(x:0.7,y:0.1),ImagePoint(x:0.75,y:0.11),ImagePoint(x:0.71,y:0.9),ImagePoint(x:0.66,y:0.89)] : TermGeometry.rectangle(Region(x:0.1,y:0.3,width:0.8,height:0.05))
            original.corners=q;original.elements=[.init(text:original.text,start:0,end:7,corners:q)]
            let cells=(0..<8).map{TermGeometry.slice(q,from:Double($0)/8,to:Double($0+1)/8,vertical:vertical)}
            let proposal=RecognitionRefinement.Chunk(text:"注目を集めている",from:0,to:1,cells:cells,estimatedCellCount:8,clearBoundaries:Array(repeating:true,count:9))
            let refined=RecognitionRefinement.refine(line:original,chunks:[proposal],vertical:vertical)
            var page=PageCapture(sessionID:"s",imagePath:"photo",fingerprint:"p")
            page.layout=vertical ? "Vertical" : "Horizontal"
            page.recognition=Recognition(engine:"fixture",lines:[refined],elapsed:0)
            let word=Occurrence(captureID:page.id,lexemeID:"notice",surface:"注目",start:0,end:2,sentence:page.text,fragment:true)
            let regions=TermGeometry.regions(page:page,occurrences:[word])
            XCTAssertEqual(regions.count,1)
            let region=try XCTUnwrap(regions.first)
            XCTAssertEqual(region.characterCount,2)
            XCTAssertEqual(region.corners,TermGeometry.slice(q,from:0,to:0.25,vertical:vertical))
            XCTAssertTrue(region.imageAligned);XCTAssertNil(region.anchor)
            XCTAssertEqual(region.leadingGap,true);XCTAssertEqual(region.trailingGap,true)
            // Overlay refinement must not refit these saved image-derived cells.
            let blank=PageRaster(width:100,height:100,pixels:Array(repeating:255,count:10000))
            XCTAssertEqual(InkGeometry.refine(regions,raster:blank),regions)
            // Shattering keeps the same cells, while two physical columns stay separate.
            let shattered=(0..<2).map{Occurrence(captureID:page.id,lexemeID:"c\($0)",surface:JapaneseText.slice(page.text,$0,$0+1),start:$0,end:$0+1,sentence:page.text,fragment:true)}
            XCTAssertEqual(TermGeometry.regions(page:page,occurrences:shattered).map(\.corners),Array(cells.prefix(2)))
            var next=refined;next.id="second-column"
            next.elements=next.elements?.map { item in
                var copy=item;copy.corners=copy.corners.map{ImagePoint(x:$0.x-(vertical ? 0.1 : 0),y:$0.y+(vertical ? 0 : 0.1))};return copy
            }
            page.recognition!.lines.append(next)
            let spanning=Occurrence(captureID:page.id,lexemeID:"cross-column",surface:"いる注目",start:6,end:10,sentence:page.text,fragment:true)
            let multi=TermGeometry.regions(page:page,occurrences:[spanning])
            XCTAssertEqual(multi.count,2);XCTAssertEqual(multi.map(\.characterCount),[2,2])
            // Independently fitted crops can disagree by a few pixels at a
            // shared edge. That is not a new term boundary.
            var edge=page.recognition!.lines[0].elements![1]
            edge.corners=TermGeometry.slice(q,from:0.12,to:0.25,vertical:vertical)
            page.recognition!.lines[0].elements![1]=edge
            XCTAssertEqual(TermGeometry.regions(page:page,occurrences:[word]).count,1)
            // A substantial unexplained gap must still remain separate.
            page.recognition!.lines[0].elements![1].corners=TermGeometry.slice(q,from:0.17,to:0.25,vertical:vertical)
            XCTAssertEqual(TermGeometry.regions(page:page,occurrences:[word]).count,2)
        }
    }
    func testLaterRefinementPreservesEarlierCellAnchors() throws {
        let original=line("注目をめている新鋭の水彩画家")
        var first=chunk("注目を集めている",0,7.0/14)
        first.clearBoundaries=Array(repeating:true,count:9)
        let refined=RecognitionRefinement.refine(line:original,chunks:[first],vertical:true)
        let second=chunk("新鋭の水彩画家",8.0/15,1)
        let again=RecognitionRefinement.refine(line:refined,chunks:[second],vertical:true)
        XCTAssertEqual(again.text,refined.text)
        XCTAssertEqual(Array(again.elements!.prefix(8)),Array(refined.elements!.prefix(8)))
        XCTAssertTrue(again.elements!.prefix(8).allSatisfy{$0.refinedGaps == [true,true]})
    }
    func testIndependentPitchAndSafeCropBoundaries() throws {
        for vertical in [true,false] {
            let width=180,height=900
            var pixels=[UInt8](repeating:255,count:width*height)
            for cell in 0..<20 {
                for y in (30+cell*40)..<(30+cell*40+30) { for x in 70..<104 { pixels[y*width+x]=20 } }
            }
            let q=TermGeometry.rectangle(Region(x:70.0/Double(width),y:24.0/Double(height),width:34.0/Double(width),height:800.0/Double(height)))
            var raster=PageRaster(width:width,height:height,pixels:pixels),quad=q
            if !vertical {
                var transposed=[UInt8](repeating:255,count:width*height)
                for y in 0..<height { for x in 0..<width {transposed[x*height+y]=pixels[y*width+x]} }
                raster=PageRaster(width:height,height:width,pixels:transposed)
                quad=TermGeometry.pageCorners(q.map{ImagePoint(x:$0.y,y:$0.x)})
            }
            let profile=try XCTUnwrap(InkColumnProfile.measure(corners:quad,vertical:vertical,raster:raster))
            XCTAssertEqual(profile.pitchFraction,0.05,accuracy:0.003)
            XCTAssertGreaterThanOrEqual(profile.chunks.count,2)
            for chunk in profile.chunks {
                XCTAssertLessThanOrEqual(chunk.estimatedCells,11)
                if chunk.to<1 { let y=24+Int(chunk.to*800);XCTAssertGreaterThanOrEqual((y-30)%40,30) }
            }
        }
    }
    func testSavedColumnProfile() throws {
        guard let path=ProcessInfo.processInfo.environment["REFINEMENT_CAPTURE"] else { return }
        #if canImport(ImageIO)
        let root=URL(fileURLWithPath:path)
        let page=try JSONDecoder().decode(PageCapture.self,from:Data(contentsOf:root.appendingPathComponent("target.json")))
        let source=CGImageSourceCreateWithURL(root.appendingPathComponent("page.jpg") as CFURL,nil)!
        let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:4096] as CFDictionary)!
        let w=image.width,h=image.height
        var pixels=[UInt8](repeating:255,count:w*h)
        pixels.withUnsafeMutableBytes { bytes in
            let context=CGContext(data:bytes.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue)!
            context.draw(image,in:CGRect(x:0,y:0,width:w,height:h))
        }
        let raster=PageRaster(width:w,height:h,pixels:pixels)
        let line=try XCTUnwrap(page.recognition?.lines.first{$0.text.contains("注目を")})
        let start=Date(),profile=try XCTUnwrap(InkColumnProfile.measure(corners:line.corners!,vertical:true,raster:raster))
        print("LOCAL COLUMN: pitch slots=\(1/profile.pitchFraction), profile ms=\(Date().timeIntervalSince(start)*1000), chunks=\(profile.chunks)")
        XCTAssertEqual(1/profile.pitchFraction,38,accuracy:1)
        let json:[String:Any] = ["pitch":profile.pitchFraction,"confidence":profile.confidence,"chunks":profile.chunks.map{["from":$0.from,"to":$0.to,"cells":$0.estimatedCells]}]
        try JSONSerialization.data(withJSONObject:json,options:.prettyPrinted).write(to:root.appendingPathComponent("planned-chunks.json"))
        // Explicit opt-in: only this reported column's small crops, not a page
        // benchmark or a replay of the library's OCR jobs.
        if let executable=ProcessInfo.processInfo.environment["REFINEMENT_TESSERACT"] {
            var chunks=[RecognitionRefinement.Chunk]()
            let began=Date()
            for (i,chunk) in profile.chunks.enumerated() {
                let crop=try XCTUnwrap(InkColumnProfile.crop(raster:raster,corners:line.corners!,vertical:true,from:chunk.from,to:chunk.to))
                let provider=CGDataProvider(data:Data(crop.pixels) as CFData)!
                let cg=CGImage(width:crop.width,height:crop.height,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:crop.width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
                let url=root.appendingPathComponent("chunk-\(i).png")
                let destination=CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
                CGImageDestinationAddImage(destination,cg,nil);CGImageDestinationFinalize(destination)
                let process=Process(),pipe=Pipe()
                process.executableURL=URL(fileURLWithPath:executable)
                process.arguments=[url.path,"stdout","--tessdata-dir",FileManager.default.currentDirectoryPath+"/Resources/tessdata","-l","jpn_vert","--psm","7"]
                process.standardOutput=pipe
                try process.run()
                let text=String(data:pipe.fileHandleForReading.readDataToEndOfFile(),encoding:.utf8)!.filter{!$0.isWhitespace}
                process.waitUntilExit()
                let q=TermGeometry.slice(line.corners!,from:chunk.from,to:chunk.to,vertical:true)
                let fit=CharacterCellGeometry.fit(CharacterAnchor(corners:q,text:text,vertical:true),raster:raster)
                print("LOCAL CROP \(i): \(text), cells \(chunk.estimatedCells), clear \(fit?.clear ?? [])")
                guard let fit,fit.clear.filter({$0}).count>=max(3,Int(Double(text.count+1)*0.75)) else { continue }
                let cells=(0..<text.count).map{TermGeometry.slice(q,from:fit.boundaries[$0],to:fit.boundaries[$0+1],vertical:true)}
                chunks.append(.init(text:text,from:chunk.from,to:chunk.to,cells:cells,estimatedCellCount:chunk.estimatedCells,clearBoundaries:fit.clear))
            }
            let refined=RecognitionRefinement.refine(line:line,chunks:chunks,vertical:true)
            print("LOCAL REFINEMENT \(Date().timeIntervalSince(began)*1000)ms: \(refined.text)")
            try JSONEncoder().encode(refined).write(to:root.appendingPathComponent("refined-line.json"))
            XCTAssertTrue(refined.text.contains("注目を集めている"))
            let element=try XCTUnwrap(refined.elements?.first{$0.text=="注"})
            // Independently measured on this photograph: 注 starts around .654
            // of page height, before the original count-based estimate (~.679).
            XCTAssertEqual(element.corners.map(\.y).min()!,0.654,accuracy:0.012)
        }
        #endif
    }
}
