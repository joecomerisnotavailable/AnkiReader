import AppKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
let candidates = files.compactMap { url -> (URL, NSImage)? in
    guard ["jpg","jpeg","png"].contains(url.pathExtension), let image = NSImage(contentsOf: url), image.size.height > image.size.width * 1.12 else { return nil }
    return (url,image)
}
print("Portrait images: \(candidates.count)")
let strideSize = max(1, candidates.count / 30)
let selected = stride(from: 0, to: candidates.count, by: strideSize).prefix(30).map { candidates[$0] }
let sheet = NSImage(size: NSSize(width: 1200, height: 1500))
sheet.lockFocus()
NSColor.white.setFill(); NSRect(x:0,y:0,width:1200,height:1500).fill()
for (i, pair) in selected.enumerated() {
    let x = CGFloat(i % 6)*200, y = 1500-CGFloat(i / 6+1)*300
    pair.1.draw(in: NSRect(x:x,y:y+25,width:200,height:270))
    ("\(i): \(pair.0.lastPathComponent.prefix(8))" as NSString).draw(at:NSPoint(x:x+5,y:y+5),withAttributes:[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.black])
}
sheet.unlockFocus()
let bitmap = NSBitmapImageRep(data:sheet.tiffRepresentation!)!
try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("contact-sheet.png"))
try JSONSerialization.data(withJSONObject:selected.map{$0.0.lastPathComponent},options:.prettyPrinted).write(to:root.appendingPathComponent("portrait-selection.json"))
