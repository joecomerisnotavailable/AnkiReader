import SwiftUI
import UIKit
import Combine

enum PageInteraction { case browsing,dragging,joining,editing }

@MainActor final class PhotoPageCoordinator: ObservableObject {
    @Published var interaction=PageInteraction.browsing
    @Published var editorOccurrence:Occurrence?
    @Published var joinRange:Range<Int>?
    @Published var editFocusRequest=0
    @Published var undoNotice=false
    var onOutsideTap:(()->Void)?
    func startEditing(_ occurrence:Occurrence) { joinRange=nil;interaction = .editing;editorOccurrence=occurrence;photoTap(occurrence);editFocusRequest += 1 }
    func stopEditing() { editorOccurrence=nil;interaction = .browsing }
    @Published var showAll=false
    @Published var pageOrder=false
    @Published var wordsOnly=false
    @Published var textGrid=false
    @Published var activeOccurrenceID:String?
    @Published var scrollWordID:String?
    @Published var scrollRequest=0
    @Published var revealRequest=0
    @Published var resetRequest=0
    @Published var splitOccurrence:Occurrence?
    @Published var detailOccurrence:Occurrence?
    @Published var stableOrder:[String]=[]
    var relativeZoom:CGFloat=1
    var offset=CGPoint.zero
    var dragSession=TermDragSession()
    var onTap:((String)->Void)?
    var onSplit:((String)->Void)?
    var onMerge:((String,String)->Void)?
    var onInvalidDrop:((String,String?)->Void)?
    func photoTap(_ occurrence:Occurrence) {
        activeOccurrenceID=occurrence.id; scrollWordID=occurrence.lexemeID; scrollRequest += 1
    }
    func rowTap(_ occurrence:Occurrence) { photoTap(occurrence);wordsOnly=false;revealRequest += 1 }
    func focus(in occurrences:[Occurrence],lexemeID:String)->Occurrence? {
        occurrences.first{$0.id==activeOccurrenceID && $0.lexemeID==lexemeID} ?? occurrences.filter{$0.lexemeID==lexemeID}.sorted{$0.start<$1.start}.first
    }
}

struct ZoomablePage: UIViewRepresentable {
    let url:URL
    var grid:TextGridPage? = nil
    let regions:[TermRegion]
    let occurrences:[Occurrence]
    let visibleIDs:Set<String>
    let scores:[String:Double]
    @ObservedObject var page:PhotoPageCoordinator
    func makeUIView(context:Context)->PhotoScrollView { PhotoScrollView(page:page) }
    func updateUIView(_ view:PhotoScrollView,context:Context) {
        if let grid { view.configureGrid(grid,occurrences:occurrences,visibleIDs:visibleIDs,scores:scores) }
        else { view.configure(url:url,regions:regions,occurrences:occurrences,visibleIDs:visibleIDs,scores:scores) }
        if view.lastEditFocus != page.editFocusRequest { view.lastEditFocus=page.editFocusRequest;view.focusForEditing(page.activeOccurrenceID) }
        if view.lastReset != page.resetRequest { view.lastReset=page.resetRequest; view.resetZoom() }
        if view.lastReveal != page.revealRequest { view.lastReveal=page.revealRequest; view.reveal(page.activeOccurrenceID) }
    }
}

final class PhotoScrollView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    let scroll=UIScrollView()
    private let canvas=UIView()
    private let photograph=UIImageView()
    private let gridText=GridGlyphView()
    private var gridLayout:TextGridPage?
    private var gridMode=false
    private var savedViews:[Bool:(zoom:CGFloat,offset:CGPoint)]=[:]
    private var restoreOffset:CGPoint?
    private let overlays=CALayer()
    private let page:PhotoPageCoordinator
    private var imageURL:URL?
    private var shapes:[String:CAShapeLayer]=[:]
    private var regions:[TermRegion]=[]
    private var rawRegions:[TermRegion]=[]
    private var raster:PageRaster?
    private var inkCache=InkGeometryCache()
    private var alignmentTask:Task<Void,Never>?
    private var alignmentVersion=0
    private var occurrences:[Occurrence]=[]
    private var visibleIDs=Set<String>()
    private var scores:[String:Double]=[:]
    private var fit:CGFloat=1
    private var previousSize=CGSize.zero
    private var dragSession:TermDragSession { get { page.dragSession } set { page.dragSession=newValue } }
    private var sourceID:String? { dragSession.sourceID }
    private var targetID:String? { dragSession.targetID }
    private var pressPoint=CGPoint.zero
    private var hold:UILongPressGestureRecognizer!
    private var neighbors:Set<String> { dragSession.neighbors }
    private let haptic=UISelectionFeedbackGenerator()
    private var pendingReveal:String?
    var lastEditFocus=0
    var lastReset=0
    var lastReveal=0
    init(page:PhotoPageCoordinator) {
        self.page=page; super.init(frame:.zero)
        backgroundColor = .black; scroll.backgroundColor = .black
        scroll.delegate=self; scroll.maximumZoomScale=8; scroll.bouncesZoom=true
        scroll.showsHorizontalScrollIndicator=false; scroll.showsVerticalScrollIndicator=false
        addSubview(scroll); scroll.addSubview(canvas); canvas.addSubview(photograph); canvas.addSubview(gridText); canvas.layer.addSublayer(overlays)
        gridText.isHidden=true; gridText.isUserInteractionEnabled=false
        photograph.contentMode = .scaleToFill
        let tap=UITapGestureRecognizer(target:self,action:#selector(tapped(_:)))
        let double=UITapGestureRecognizer(target:self,action:#selector(doubleTapped(_:))); double.numberOfTapsRequired=2
        hold=UILongPressGestureRecognizer(target:self,action:#selector(held(_:))); hold.minimumPressDuration=0.35; hold.allowableMovement=8; hold.delegate=self
        tap.require(toFail:double); tap.require(toFail:hold)
        canvas.addGestureRecognizer(tap); canvas.addGestureRecognizer(double); canvas.addGestureRecognizer(hold)
        scroll.pinchGestureRecognizer?.addTarget(self,action:#selector(pinching(_:)))
        isAccessibilityElement=false
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) has not been implemented") }
    private func switchMode(_ grid:Bool) {
        guard gridMode != grid else { return }
        savedViews[gridMode]=(scroll.zoomScale/max(fit,0.00001),scroll.contentOffset)
        cancelDrag(); alignmentTask?.cancel(); alignmentVersion += 1
        gridMode=grid; photograph.isHidden=grid; gridText.isHidden = !grid
        page.relativeZoom=savedViews[grid]?.zoom ?? 1; restoreOffset=savedViews[grid]?.offset
        previousSize = .zero; rawRegions=[]
    }
    func configureGrid(_ grid:TextGridPage,occurrences:[Occurrence],visibleIDs:Set<String>,scores:[String:Double]) {
        let entering = !gridMode; switchMode(true)
        if entering || gridLayout != grid {
            cancelDrag(); gridLayout=grid; gridText.layout=grid
            let relative=page.relativeZoom
            if !entering { restoreOffset=scroll.contentOffset }
            scroll.zoomScale=1
            canvas.bounds=CGRect(x:0,y:0,width:grid.width,height:grid.height); canvas.frame=canvas.bounds
            gridText.frame=canvas.bounds; overlays.frame=canvas.bounds
            page.relativeZoom=relative; previousSize = .zero; setNeedsLayout()
        }
        if regions != grid.regions || self.visibleIDs != visibleIDs || self.scores != scores {
            self.regions=grid.regions; self.visibleIDs=visibleIDs; self.scores=scores; self.occurrences=occurrences; redraw()
        } else { self.occurrences=occurrences }
    }
    func configure(url:URL,regions:[TermRegion],occurrences:[Occurrence],visibleIDs:Set<String>,scores:[String:Double]) {
        let entering=gridMode; switchMode(false)
        if imageURL != url || entering {
            alignmentTask?.cancel(); alignmentVersion += 1; raster=nil; inkCache=InkGeometryCache(); rawRegions=[]
            imageURL=url; photograph.image=UIImage(contentsOfFile:url.path)?.normalized()
            let size=photograph.image?.size ?? CGSize(width:1,height:1)
            let relative=page.relativeZoom
            scroll.zoomScale=1
            canvas.bounds=CGRect(origin:.zero,size:size); canvas.frame=canvas.bounds; photograph.frame=canvas.bounds; overlays.frame=canvas.bounds
            page.relativeZoom=relative; previousSize = .zero; setNeedsLayout()
        }
        let changed=rawRegions != regions
        if changed || self.visibleIDs != visibleIDs || self.scores != scores {
            cancelDrag(); if changed { rawRegions=regions; self.regions=regions }
            self.visibleIDs=visibleIDs; self.scores=scores; self.occurrences=occurrences; redraw()
            if changed { alignToInk() }
        } else { self.occurrences=occurrences }
    }
    private func alignToInk() {
        alignmentTask?.cancel(); alignmentVersion += 1
        let version=alignmentVersion, input=rawRegions, cached=raster, cachedFits=inkCache, image=photograph.image?.cgImage
        alignmentTask=Task { [weak self] in
            let result=await Task.detached(priority:.userInitiated) { () -> (PageRaster?,[TermRegion],InkGeometryCache) in
                let raster=cached ?? image.flatMap(PhotoRaster.make)
                var cache=cachedFits
                return (raster,raster.map{InkGeometry.refine(input,raster:$0,cache:&cache)} ?? input,cache)
            }.value
            guard !Task.isCancelled, let self, version==self.alignmentVersion else { return }
            self.raster=result.0; self.inkCache=result.2; self.cancelDrag(); self.regions=result.1; self.redraw()
        }
    }
    override func layoutSubviews() {
        super.layoutSubviews(); scroll.frame=bounds
        guard bounds.width>0,bounds.height>0 else { return }
        if previousSize != bounds.size {
            let relative=previousSize == .zero ? page.relativeZoom : scroll.zoomScale/fit
            previousSize=bounds.size
            fit=min(bounds.width/canvas.bounds.width,bounds.height/canvas.bounds.height)
            scroll.minimumZoomScale=fit; scroll.maximumZoomScale=fit*8
            scroll.zoomScale=min(scroll.maximumZoomScale,max(fit,fit*relative)); centerImage()
            if let offset=restoreOffset { restoreOffset=nil; scroll.setContentOffset(offset,animated:false) }
            if let id=pendingReveal { pendingReveal=nil; reveal(id) }
        } else { centerImage() }
    }
    func viewForZooming(in scrollView:UIScrollView)->UIView? { canvas }
    func scrollViewDidZoom(_ scrollView:UIScrollView) { centerImage(); page.relativeZoom=scroll.zoomScale/max(fit,0.00001); updateLineWidths() }
    func scrollViewDidScroll(_ scrollView:UIScrollView) { page.offset=scroll.contentOffset }
    private func centerImage() {
        scroll.contentInset=UIEdgeInsets(top:max(0,(bounds.height-canvas.frame.height)/2),left:max(0,(bounds.width-canvas.frame.width)/2),bottom:0,right:0)
    }
    func resetZoom() { cancelDrag(); scroll.setZoomScale(fit,animated:true); scroll.setContentOffset(CGPoint(x:-scroll.contentInset.left,y:-scroll.contentInset.top),animated:true) }
    private func path(_ region:TermRegion)->UIBezierPath {
        let path=UIBezierPath()
        for (i,p) in region.corners.enumerated() {
            let point=CGPoint(x:p.x*canvas.bounds.width,y:p.y*canvas.bounds.height)
            if i==0 { path.move(to:point) } else { path.addLine(to:point) }
        }
        path.close(); return path
    }
    private func band(_ id:String)->UIColor {
        let score=scores[id] ?? 0
        if score<0 { return .systemGray }
        return score>=0.55 ? .systemGreen : score>=0.3 ? .systemBlue : .systemOrange
    }
    private func redraw() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        overlays.sublayers=nil; shapes=[:]
        for region in regions {
            let id=region.occurrenceID
            guard visibleIDs.contains(id) || neighbors.contains(id) || id==sourceID else { continue }
            let shape=CAShapeLayer(); shape.path=path(region).cgPath
            let color=band(id)
            shape.fillColor=color.withAlphaComponent(visibleIDs.contains(id) ? 0.22 : 0.10).cgColor
            shape.strokeColor=nil
            shape.lineWidth=1/max(scroll.zoomScale,0.01)
            shape.lineDashPattern=region.estimated ? [3/max(scroll.zoomScale,0.01),3/max(scroll.zoomScale,0.01)].map { NSNumber(value:Double($0)) } : nil
            overlays.addSublayer(shape); shapes[region.id]=shape
            // Only draw the longitudinal edges until a safe ink gap is found.
            // A rectangular stroke would put the uncertain end edge through glyphs.
            let sides=CAShapeLayer(), outline=UIBezierPath(), q=region.corners
            if q.count==4 {
                for pair in (region.vertical ? [[q[0],q[3]],[q[1],q[2]]] : [[q[0],q[1]],[q[3],q[2]]]) {
                    outline.move(to:CGPoint(x:pair[0].x*canvas.bounds.width,y:pair[0].y*canvas.bounds.height))
                    outline.addLine(to:CGPoint(x:pair[1].x*canvas.bounds.width,y:pair[1].y*canvas.bounds.height))
                }
                sides.path=outline.cgPath; sides.strokeColor=color.withAlphaComponent(0.65).cgColor
                sides.lineWidth=shape.lineWidth; sides.lineDashPattern=shape.lineDashPattern; overlays.addSublayer(sides)
            }
            // A transverse separator at each region's trailing edge distinguishes same-color neighbors.
            if region.corners.count==4 && region.trailingGap == true {
                let bar=CAShapeLayer()
                let edge=TermGeometry.separator(region)
                let p=UIBezierPath(); p.move(to:CGPoint(x:edge[0].x*canvas.bounds.width,y:edge[0].y*canvas.bounds.height)); p.addLine(to:CGPoint(x:edge[1].x*canvas.bounds.width,y:edge[1].y*canvas.bounds.height))
                bar.path=p.cgPath; bar.strokeColor=UIColor.label.withAlphaComponent(0.8).cgColor; bar.lineWidth=1.5/max(scroll.zoomScale,0.01); overlays.addSublayer(bar)
            }
        }
        CATransaction.commit(); updateAccessibility()
    }
    private func updateLineWidths() {
        for layer in overlays.sublayers ?? [] {
            guard let shape=layer as? CAShapeLayer else { continue }
            shape.lineWidth=1/max(scroll.zoomScale,0.01)
            if shape.lineDashPattern != nil { shape.lineDashPattern=[NSNumber(value:Double(3/max(scroll.zoomScale,0.01))),NSNumber(value:Double(3/max(scroll.zoomScale,0.01)))] }
        }
    }
    private func hit(_ point:CGPoint,includingHidden:Bool=false)->String? {
        regions.filter { (visibleIDs.contains($0.occurrenceID) || (includingHidden && neighbors.contains($0.occurrenceID))) && path($0).contains(point) }
            .min { path($0).bounds.width*path($0).bounds.height < path($1).bounds.width*path($1).bounds.height }?.occurrenceID
    }
    /// Drag targets are restricted before hit ranking. A large source box or an
    /// overlapping unrelated OCR box must not mask the adjacent destination.
    private func mergeTarget(at point:CGPoint)->String? {
        regions.filter { neighbors.contains($0.occurrenceID) && path($0).contains(point) }
            .min { a,b in
                let x=path(a).bounds,y=path(b).bounds
                return hypot(x.midX-point.x,x.midY-point.y)<hypot(y.midX-point.x,y.midY-point.y)
            }?.occurrenceID
    }
    @objc private func tapped(_ recognizer:UITapGestureRecognizer) { if page.interaction == .editing { page.onOutsideTap?();return };if let id=hit(recognizer.location(in:canvas)) { page.onTap?(id) } }
    @objc private func doubleTapped(_ recognizer:UITapGestureRecognizer) {
        cancelDrag()
        if scroll.zoomScale>fit*1.1 { scroll.setZoomScale(fit,animated:true) }
        else {
            let point=recognizer.location(in:canvas), scale=fit*3
            scroll.zoom(to:CGRect(x:point.x-bounds.width/scale/2,y:point.y-bounds.height/scale/2,width:bounds.width/scale,height:bounds.height/scale),animated:true)
        }
    }
    @objc private func pinching(_ recognizer:UIPinchGestureRecognizer) { if recognizer.state == .began && sourceID != nil { cancelDrag(); hold.isEnabled=false; hold.isEnabled=true } }
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith other:UIGestureRecognizer)->Bool { other === scroll.pinchGestureRecognizer || gestureRecognizer === scroll.pinchGestureRecognizer }
    @objc private func held(_ recognizer:UILongPressGestureRecognizer) {
        let point=recognizer.location(in:canvas)
        switch recognizer.state {
        case .began:
            guard page.interaction == .browsing,let id=hit(point) else { return }
            dragSession.begin(id,occurrences:occurrences);page.interaction = .dragging;pressPoint=point
            scroll.panGestureRecognizer.isEnabled=false; haptic.prepare(); haptic.selectionChanged(); redraw()
            for region in regions where region.occurrenceID==id { shapes[region.id]?.shadowColor=UIColor.black.cgColor; shapes[region.id]?.shadowOpacity=0.6; shapes[region.id]?.shadowRadius=4/max(scroll.zoomScale,0.01) }
        case .changed:
            guard let id=sourceID else { return }
            let delta=CGPoint(x:point.x-pressPoint.x,y:point.y-pressPoint.y)
            let previous=targetID
            dragSession.update(distance:Double(hypot(delta.x,delta.y)*scroll.zoomScale),candidate:mergeTarget(at:point))
            if previous != targetID { haptic.selectionChanged() }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            for region in regions {
                let layer=shapes[region.id]
                layer?.opacity=region.occurrenceID==targetID ? 1 : 0.85
                layer?.fillColor=band(region.occurrenceID).withAlphaComponent(region.occurrenceID==targetID ? 0.6 : 0.22).cgColor
                if region.occurrenceID==id { layer?.setAffineTransform(CGAffineTransform(translationX:delta.x,y:delta.y)) }
            }
            CATransaction.commit()
        case .ended:
            let source=sourceID, moved=dragSession.moved, attempted=hit(point,includingHidden:true)
            let result=dragSession.end();page.interaction = .browsing;scroll.panGestureRecognizer.isEnabled=true;redraw()
            switch result {
            case .split(let source): page.onSplit?(source)
            case .merge(let source,let target): page.onMerge?(source,target)
            case .cancelled: if moved,let source { page.onInvalidDrop?(source,attempted) }
            }
        case .cancelled,.failed: cancelDrag()
        default: break
        }
    }
    private func cancelDrag() {
        let wasActive=sourceID != nil
        dragSession.cancel();if page.interaction == .dragging { page.interaction = .browsing };scroll.panGestureRecognizer.isEnabled=true
        if wasActive { redraw() }
    }
    func focusForEditing(_ id:String?) {
        guard let id,bounds.width>0 else { return }
        let matches=regions.filter{$0.occurrenceID==id}
        guard let first=matches.first else { return }
        let rect=matches.dropFirst().reduce(path(first).bounds){$0.union(path($1).bounds)}
        let scale=min(scroll.maximumZoomScale,max(fit,min(bounds.width*0.65/max(1,rect.width),bounds.height*0.3/max(1,rect.height))))
        scroll.setZoomScale(scale,animated:false)
        let target=CGPoint(x:rect.midX*scale-bounds.width/2,y:rect.midY*scale-bounds.height*0.80)
        scroll.setContentOffset(CGPoint(x:max(-scroll.contentInset.left,min(target.x,scroll.contentSize.width-bounds.width+scroll.contentInset.right)),y:max(-scroll.contentInset.top,min(target.y,scroll.contentSize.height-bounds.height+scroll.contentInset.bottom))),animated:false)
    }
    func reveal(_ id:String?) {
        guard let id else { return }
        guard bounds.width>0,bounds.height>0 else { pendingReveal=id; return }
        let matches=regions.filter{$0.occurrenceID==id}
        guard let first=matches.first else { return }
        let rect=matches.dropFirst().reduce(path(first).bounds) { $0.union(path($1).bounds) }
        // Convert to the scroll view's content coordinates; scrolling does not change zoom.
        let scaled=canvas.convert(rect,to:scroll)
        scroll.scrollRectToVisible(scaled.insetBy(dx:-12,dy:-12),animated:!UIAccessibility.isReduceMotionEnabled)
        for region in matches {
            guard let layer=shapes[region.id] else { continue }
            let animation=CABasicAnimation(keyPath:"fillColor")
            animation.fromValue=band(id).withAlphaComponent(0.75).cgColor; animation.toValue=layer.fillColor; animation.duration=UIAccessibility.isReduceMotionEnabled ? 1 : 0.8
            layer.add(animation,forKey:"focus")
        }
    }
    private func updateAccessibility() {
        accessibilityElements=occurrences.filter{visibleIDs.contains($0.id)}.compactMap { occurrence in
            guard let region=regions.first(where:{$0.occurrenceID==occurrence.id}) else { return nil }
            let element=PhotoTermAccessibility(container:self)
            element.accessibilityLabel=occurrence.surface; element.accessibilityTraits = .button
            element.frameProvider={ [weak self] in
                guard let self else { return .zero }
                return UIAccessibility.convertToScreenCoordinates(self.canvas.convert(self.path(region).bounds,to:self),in:self)
            }
            element.activate={ [weak self] in self?.page.onTap?(occurrence.id) }
            element.accessibilityCustomActions=[UIAccessibilityCustomAction(name:"Split term") { [weak self] _ in self?.page.onSplit?(occurrence.id); return true }]
            return element
        }
    }
}

private final class GridGlyphView:UIView {
    var layout:TextGridPage? { didSet { setNeedsDisplay() } }
    override func draw(_ rect:CGRect) {
        UIColor.systemBackground.setFill(); UIRectFill(bounds)
        guard let layout else { return }
        let font=UIFont.systemFont(ofSize:25)
        let verticalForms=["「":"﹁","」":"﹂","『":"﹃","』":"﹄","（":"︵","）":"︶","ー":"丨","…":"︙"]
        for glyph in layout.glyphs {
            let r=CGRect(x:glyph.box.x*bounds.width,y:glyph.box.y*bounds.height,width:glyph.box.width*bounds.width,height:glyph.box.height*bounds.height)
            let text=layout.vertical ? (verticalForms[glyph.text] ?? glyph.text) : glyph.text
            let attributes:[NSAttributedString.Key:Any]=[.font:font,.foregroundColor:UIColor.label]
            let size=(text as NSString).size(withAttributes:attributes)
            var origin=CGPoint(x:r.midX-size.width/2,y:r.midY-size.height/2)
            if layout.vertical && ["。","、"].contains(text) { origin.x += 7; origin.y -= 6 }
            (text as NSString).draw(at:origin,withAttributes:attributes)
        }
    }
}

enum PhotoRaster {
    static func make(_ image:CGImage)->PageRaster? {
        let scale=min(1,2048/Double(max(image.width,image.height)))
        let width=max(1,Int(Double(image.width)*scale)),height=max(1,Int(Double(image.height)*scale))
        var pixels=[UInt8](repeating:255,count:width*height)
        let drawn=pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context=CGContext(data:bytes.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .high
            context.draw(image,in:CGRect(x:0,y:0,width:width,height:height)); return true
        }
        return drawn ? PageRaster(width:width,height:height,pixels:pixels) : nil
    }
}
final class PhotoTermAccessibility:UIAccessibilityElement {
    var activate:(()->Void)?
    var frameProvider:(()->CGRect)?
    override var accessibilityFrame:CGRect { get { frameProvider?() ?? super.accessibilityFrame } set { super.accessibilityFrame=newValue } }
    init(container:Any) { super.init(accessibilityContainer:container) }
    override func accessibilityActivate()->Bool { activate?(); return true }
}
