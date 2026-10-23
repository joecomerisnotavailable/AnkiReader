import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let names=try JSONDecoder().decode([String].self,from:Data(contentsOf:root.appendingPathComponent("novel-selection.json")))
let output=root.appendingPathComponent("normalized")
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
for name in names {
    guard let source=CGImageSourceCreateWithURL(root.appendingPathComponent(name) as CFURL,nil),
          let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:4032] as CFDictionary),
          let destination=CGImageDestinationCreateWithURL(output.appendingPathComponent(name) as CFURL,UTType.jpeg.identifier as CFString,1,nil) else {continue}
    CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.96] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {fatalError("Failed to normalize \(name)")}
}
