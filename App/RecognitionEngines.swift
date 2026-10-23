import Foundation
import UIKit
import Vision
import SwiftyTesseract
import MLKitVision
import MLKitTextRecognitionCommon
import MLKitTextRecognitionJapanese

enum EngineChoice:String,CaseIterable,Codable,Identifiable {
    case vision="Apple Vision", mlkit="ML Kit Japanese", tesseract="Tesseract"
    var id:String { rawValue }
}
enum PageLayout:String,CaseIterable,Codable,Identifiable {
    case vertical="Vertical",horizontal="Horizontal"
    var id:String {rawValue}
}
protocol PageRecognizer { func recognize(_ image:UIImage,layout:PageLayout) throws -> Recognition }
enum PageGeometry {
    static func ordered(_ lines: [TextLine], layout: PageLayout) -> [TextLine] {
        PageLayoutRepair.ordered(lines, vertical: layout == .vertical)
    }
}
final class AppleRecognizer:PageRecognizer {
    func recognize(_ image:UIImage,layout:PageLayout) throws -> Recognition {
        let start=Date()
        guard let cg=image.cgImage else { throw StorageError.database("Cannot decode image") }
        let request=VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages=["ja-JP","en-US"]; request.usesLanguageCorrection=true
        try VNImageRequestHandler(cgImage:cg,orientation:.up).perform([request])
        let lines=(request.results ?? []).compactMap { observation -> TextLine? in
            guard let text=observation.topCandidates(1).first else {return nil}
            let b=observation.boundingBox
            return TextLine(text:text.string,region:Region(x:b.minX,y:1-b.maxY,width:b.width,height:b.height),confidence:Double(text.confidence))
        }
        return Recognition(engine:"Apple Vision revision \(request.revision)",lines:PageGeometry.ordered(lines,layout:layout),elapsed:Date().timeIntervalSince(start))
    }
}
final class GoogleRecognizer:PageRecognizer {
    private let recognizer=TextRecognizer.textRecognizer(options:JapaneseTextRecognizerOptions())
    func recognize(_ image:UIImage,layout:PageLayout) throws -> Recognition {
        let start=Date(), input=VisionImage(image:image)
        input.orientation = .up
        let result=try recognizer.results(in:input)
        let lines=result.blocks.flatMap(\.lines).map { line -> TextLine in
            let r=line.frame, w=image.size.width,h=image.size.height
            var saved = TextLine(text:line.text,region:Region(x:r.minX/w,y:r.minY/h,width:r.width/w,height:r.height/h))
            saved.corners = line.cornerPoints.map { ImagePoint(x:$0.cgPointValue.x/w,y:$0.cgPointValue.y/h) }
            var cursor = line.text.startIndex
            saved.elements = line.elements.compactMap { element in
                guard let range = line.text.range(of:element.text,range:cursor..<line.text.endIndex) else { return nil }
                cursor = range.upperBound
                return TextElementGeometry(text:element.text,start:line.text[..<range.lowerBound].unicodeScalars.count,end:line.text[..<range.upperBound].unicodeScalars.count,corners:element.cornerPoints.map { ImagePoint(x:$0.cgPointValue.x/w,y:$0.cgPointValue.y/h) })
            }
            return saved
        }
        var recognition = Recognition(engine:"ML Kit Japanese 8.0.0",lines:PageGeometry.ordered(lines,layout:layout),elapsed:Date().timeIntervalSince(start))
        recognition.rawLines = lines
        return recognition
    }
}
final class TesseractRecognizer:PageRecognizer {
    private var engines:[PageLayout:Tesseract]=[:]
    func recognize(_ image:UIImage,layout:PageLayout) throws -> Recognition {
        let start=Date()
        if engines[layout]==nil {
            engines[layout]=Tesseract(language:layout == .vertical ? .custom("jpn_vert") : .japanese) {
                set("tessedit_pageseg_mode",value:layout == .vertical ? "5" : "3")
            }
        }
        guard let data=image.pngData(),let engine=engines[layout] else {throw StorageError.database("Cannot prepare OCR image")}
        let (_,blocks)=try engine.recognizedBlocks(from:data,for:.textline).get()
        let lines=blocks.map { b -> TextLine in
            let r=b.boundingBox.cgRect,w=Double(image.cgImage!.width),h=Double(image.cgImage!.height)
            return TextLine(text:b.text.trimmingCharacters(in:.whitespacesAndNewlines).replacingOccurrences(of:" ",with:""),region:Region(x:r.minX/w,y:r.minY/h,width:r.width/w,height:r.height/h),confidence:Double(b.confidence)/100)
        }
        return Recognition(engine:"Tesseract 4.1.1 / \(layout.rawValue)",lines:PageGeometry.ordered(lines,layout:layout),elapsed:Date().timeIntervalSince(start))
    }
}
extension UIImage {
    func normalized() -> UIImage {
        let format=UIGraphicsImageRendererFormat(); format.scale=1
        return UIGraphicsImageRenderer(size:size,format:format).image { _ in draw(in:CGRect(origin:.zero,size:size)) }
    }
}
