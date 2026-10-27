// Diagnostic only: rectify one saved ML Kit column and measure ink along it.
// No OCR is run; the text content never determines sampling or candidate pitch.
import Foundation
import CoreGraphics
import ImageIO

let args=CommandLine.arguments
precondition(args.count==5,"column_profile.swift target.json image.jpg line-index output-prefix")
let json=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:args[1]))) as! [String:Any]
let recognition=json["recognition"] as! [String:Any]
let lines=recognition["lines"] as! [[String:Any]]
let line=lines[Int(args[3])!]
let raw=line["corners"] as! [[String:Double]]
var corners=raw.map{CGPoint(x:$0["x"]!,y:$0["y"]!)}
let center=CGPoint(x:corners.map(\.x).reduce(0,+)/4,y:corners.map(\.y).reduce(0,+)/4)
corners.sort{atan2($0.y-center.y,$0.x-center.x)<atan2($1.y-center.y,$1.x-center.x)}
// This diagnostic handles near-vertical quadrilaterals, choosing the two top corners.
let sorted=corners.sorted{$0.y<$1.y}, upper=Array(sorted.prefix(2)).sorted{$0.x<$1.x}, lower=Array(sorted.suffix(2)).sorted{$0.x<$1.x}
let q=[upper[0],upper[1],lower[1],lower[0]]
let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:args[2]) as CFURL,nil)!
let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil)! as NSDictionary
let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:4096,kCGImageSourceShouldAllowFloat:false,kCGImageSourceShouldCacheImmediately:true] as CFDictionary)!
let w=image.width,h=image.height
var rgba=[UInt8](repeating:255,count:w*h*4)
rgba.withUnsafeMutableBytes{ bytes in
 let ctx=CGContext(data:bytes.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 ctx.draw(image,in:CGRect(x:0,y:0,width:w,height:h));ctx.flush()
}
var pixels=[UInt8]();pixels.reserveCapacity(w*h)
for i in 0..<w*h {let r=Int(rgba[i*4]),g=Int(rgba[i*4+1]),b=Int(rgba[i*4+2]);pixels.append(UInt8((r*30+g*59+b*11)/100))}
guard pixels.contains(where:{$0<230}) else { fatalError("Image decoding produced a blank raster; run this local diagnostic outside the sandbox.") }
func dist(_ a:CGPoint,_ b:CGPoint)->Double{hypot((a.x-b.x)*Double(w),(a.y-b.y)*Double(h))}
let along=(dist(q[0],q[3])+dist(q[1],q[2]))/2, across=(dist(q[0],q[1])+dist(q[3],q[2]))/2
let started=Date()
let rh=Int(ceil(along)),rw=Int(ceil(across))
func lerp(_ a:CGPoint,_ b:CGPoint,_ t:Double)->CGPoint{CGPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t)}
func point(_ t:Double,_ u:Double)->CGPoint{lerp(lerp(q[0],q[3],t),lerp(q[1],q[2],t),u)}
var rectified=[UInt8](repeating:255,count:rh*rw)
for y in 0..<rh{for x in 0..<rw{let p=point(Double(y)/Double(rh-1),Double(x)/Double(rw-1));let ix=max(0,min(w-1,Int(p.x*Double(w)))),iy=max(0,min(h-1,Int(p.y*Double(h))));rectified[y*rw+x]=pixels[iy*w+ix]}}
let sortedPixels=rectified.sorted(),paper=Double(sortedPixels[sortedPixels.count*85/100]),ink=Double(sortedPixels[sortedPixels.count*10/100]),threshold=paper-max(25,(paper-ink)*0.32)
let profile=(0..<rh).map{y in Double((rw/10..<rw*9/10).filter{Double(rectified[y*rw+$0])<threshold}.count)/Double(rw*8/10)}
var smooth=[Double]()
for i in 0..<rh { let a=max(0,i-2),b=min(rh-1,i+2);var sum=0.0;for j in a...b {sum += profile[j]};smooth.append(sum/Double(b-a+1)) }
// Blank bands; punctuation may create longer bands and internal glyph gaps may appear.
var gaps:[[Int]]=[],start:Int?
for i in 0..<rh{if smooth[i]<=0.035{if start==nil{start=i}}else if let s=start{if i-s>=3{gaps.append([s,i-1])};start=nil}}
if let s=start{gaps.append([s,rh-1])}
let means=smooth.reduce(0,+)/Double(rh)
let lo=Int(across*0.75),hi=Int(across*1.55)
var correlations:[[String:Double]]=[]
for lag in lo...hi{let a=Array(smooth.dropLast(lag)),b=Array(smooth.dropFirst(lag));let num=zip(a,b).map{($0-means)*($1-means)}.reduce(0,+);let den=sqrt(a.map{pow($0-means,2)}.reduce(0,+)*b.map{pow($0-means,2)}.reduce(0,+));correlations.append(["pitch":Double(lag),"correlation":num/max(1e-9,den)])}
let elapsed=Date().timeIntervalSince(started)
let output:[String:Any]=["profileMilliseconds":elapsed*1000,"imageWidth":w,"imageHeight":h,"sourceOrientation":props[kCGImagePropertyOrientation] ?? "none","rectifiedWidth":rw,"rectifiedHeight":rh,"acrossPixels":across,"text":line["text"]!,"threshold":threshold,"profile":smooth,"gaps":gaps,"pitchCorrelations":correlations.sorted{$0["correlation"]!>$1["correlation"]!},"corners":q.map{["x":$0.x,"y":$0.y]}]
try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:args[4]+".json"))
let provider=CGDataProvider(data:Data(rectified) as CFData)!
let out=CGImage(width:rw,height:rh,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:rw,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
let dest=CGImageDestinationCreateWithURL(URL(fileURLWithPath:args[4]+".png") as CFURL,"public.png" as CFString,1,nil)!
CGImageDestinationAddImage(dest,out,nil);CGImageDestinationFinalize(dest)
let best=correlations.sorted{$0["correlation"]!>$1["correlation"]!}.prefix(5)
print("upright \(w)x\(h); rectified \(rw)x\(rh), width \(across); top pitch hypotheses \(best)")
