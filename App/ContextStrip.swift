import SwiftUI
import UIKit

struct ContextStrip:UIViewRepresentable {
    var text:String
    var occurrences:[Occurrence]
    var scores:[String:Double]
    @ObservedObject var page:PhotoPageCoordinator
    var annotations:[String:String]=[:]
    var disabled:Bool
    var action:(String,Occurrence)->Void
    func makeUIView(context:Context)->ContextStripView { ContextStripView() }
    func updateUIView(_ view:ContextStripView,context:Context) {
        view.page=page;view.action=action;view.isUserInteractionEnabled = !disabled
        view.configure(text:text,items:occurrences,scores:scores,annotations:annotations)
    }
}
final class ContextStripView:UIView,UIGestureRecognizerDelegate,UIEditMenuInteractionDelegate {
    let scroll=UIScrollView(),content=UIView()
    private let discard=UILabel(),selection=UIView(),left=ContextCursor(),right=ContextCursor()
    private var labels:[String:ContextTermLabel]=[:],badges:[String:UILabel]=[:],items:[Occurrence]=[],scores:[String:Double]=[:]
    private struct LayoutToken:Equatable {
        var id:String; var surface:String; var start:Int; var fontSize:CGFloat
    }
    private var layoutKey:[LayoutToken]=[]
    private var layoutSize=CGSize.zero
    private var text="",boundsX:[(Int,CGFloat)]=[]
    private var hold:UILongPressGestureRecognizer!
    private var editMenu:UIEditMenuInteraction!
    private var menuSource:Occurrence?
    private var source:Occurrence?,origin=CGPoint.zero,target:Occurrence?,moved=false,discarding=false
    private var lastFocus:String?,lastScroll = -1
    private let haptic=UISelectionFeedbackGenerator()
    private var ticker:CADisplayLink?
    private var edgeSpeed:CGFloat=0
    private var cursorIndex:Int?
    private var finger=CGPoint.zero
    var page:PhotoPageCoordinator!
    var action:((String,Occurrence)->Void)?
    override init(frame:CGRect) {
        super.init(frame:frame);backgroundColor = .secondarySystemBackground
        scroll.accessibilityIdentifier="context-strip";scroll.delaysContentTouches=false;scroll.showsHorizontalScrollIndicator=true
        addSubview(scroll);scroll.addSubview(content)
        selection.backgroundColor=UIColor.systemYellow.withAlphaComponent(0.2);selection.isUserInteractionEnabled=false;content.addSubview(selection)
        for (i,handle) in [left,right].enumerated() {
            handle.backgroundColor = .systemBlue;handle.layer.cornerRadius=5;handle.tag=i
            handle.isAccessibilityElement=true;handle.accessibilityLabel=i==0 ? "Join start" : "Join end"
            handle.accessibilityTraits = .adjustable
            handle.adjust={ [weak self] delta in self?.adjustCursor(i,delta:delta) }
            content.addSubview(handle)
            let pan=UIPanGestureRecognizer(target:self,action:#selector(moveCursor(_:)));handle.addGestureRecognizer(pan);scroll.panGestureRecognizer.require(toFail:pan)
        }
        discard.textAlignment = .center;discard.backgroundColor = .systemRed;discard.textColor = .white;discard.layer.cornerRadius=8;discard.clipsToBounds=true;discard.isHidden=true;addSubview(discard)
        hold=UILongPressGestureRecognizer(target:self,action:#selector(held(_:)));hold.minimumPressDuration=0.35;hold.allowableMovement=8;hold.delegate=self
        scroll.addGestureRecognizer(hold);scroll.panGestureRecognizer.require(toFail:hold)
        let tap=UITapGestureRecognizer(target:self,action:#selector(tapped(_:)));tap.require(toFail:hold);scroll.addGestureRecognizer(tap)
        editMenu=UIEditMenuInteraction(delegate:self);addInteraction(editMenu)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layoutSubviews() { super.layoutSubviews();scroll.frame=bounds;discard.frame=CGRect(x:16,y:-52,width:max(44,bounds.width-32),height:48);layoutTokens() }
    func configure(text:String,items:[Occurrence],scores:[String:Double],annotations:[String:String]) {
        self.text=text;self.items=items.sorted{$0.start<$1.start};self.scores=scores
        let ids=Set(items.map(\.id))
        for id in Array(labels.keys) where !ids.contains(id) { labels.removeValue(forKey:id)?.removeFromSuperview();badges.removeValue(forKey:id)?.removeFromSuperview() }
        for item in items {
            let label=labels[item.id] ?? ContextTermLabel()
            if labels[item.id]==nil { labels[item.id]=label;content.addSubview(label) }
            label.text=item.surface.replacingOccurrences(of:"\n",with:"↵").replacingOccurrences(of:" ",with:"␠")
            label.font=UIFontMetrics(forTextStyle:.largeTitle).scaledFont(for:UIFont.systemFont(ofSize:42))
            label.textAlignment = .center;label.layer.cornerRadius=5;label.clipsToBounds=true
            let score=scores[item.id] ?? -1
            let color:UIColor=score<0 ? .systemGray : score>=0.55 ? .systemGreen : score>=0.3 ? .systemBlue : .systemOrange
            label.backgroundColor=color.withAlphaComponent(0.22);label.layer.borderColor=(item.id==page.activeOccurrenceID ? UIColor.label : color).cgColor
            label.layer.borderWidth=item.id==page.activeOccurrenceID ? 3 : 1
            label.isAccessibilityElement=true;label.accessibilityLabel=item.surface;label.accessibilityIdentifier="context-\(item.start)";label.accessibilityTraits = .button
            label.activate={ [weak self] in self?.page.rowTap(item);return true }
            label.accessibilityValue=annotations[item.id]
            let badge=badges[item.id] ?? UILabel();badges[item.id]=badge
            if badge.superview==nil { content.addSubview(badge) }
            badge.text=annotations[item.id]
            if let text=annotations[item.id],let separator=text.range(of:" → ") {
                let attributed=NSMutableAttributedString(string:text)
                attributed.addAttribute(.strikethroughStyle,value:NSUnderlineStyle.single.rawValue,range:NSRange(text.startIndex..<separator.lowerBound,in:text));badge.attributedText=attributed
            }
            badge.font = .preferredFont(forTextStyle:.caption2);badge.textColor = .systemOrange;badge.textAlignment = .right;badge.isAccessibilityElement=false
            label.accessibilityCustomActions=["Focus","Edit","Join","Shatter","Discard"].map { name in UIAccessibilityCustomAction(name:name) { [weak self] _ in
                guard let self else { return false }
                if name=="Focus" { self.page.rowTap(item) } else { self.action?(name,item) };return true
            } }
        }
        layoutTokens()
        if lastFocus != page.activeOccurrenceID || lastScroll != page.scrollRequest {
            lastFocus=page.activeOccurrenceID;lastScroll=page.scrollRequest
            if let id=lastFocus,let label=labels[id],page.interaction != .dragging && page.interaction != .joining {
                scroll.setContentOffset(CGPoint(x:max(0,min(label.frame.midX-bounds.width/2,scroll.contentSize.width-bounds.width)),y:0),animated:!UIAccessibility.isReduceMotionEnabled)
            }
        }
    }
    private func layoutTokens() {
        let key=items.map{LayoutToken(id:$0.id,surface:$0.surface,start:$0.start,fontSize:labels[$0.id]?.font.pointSize ?? 0)}
        guard key != layoutKey || bounds.size != layoutSize else { layoutSelection();return }
        layoutKey=key;layoutSize=bounds.size
        var x:CGFloat=10;boundsX=[]
        for item in items {
            guard let label=labels[item.id] else { continue }
            let font=label.font!,surface=label.text ?? ""
            let width=max(44,(surface as NSString).size(withAttributes:[.font:font]).width+16)
            label.frame=CGRect(x:x,y:6,width:width,height:max(44,bounds.height-14))
            badges[item.id]?.frame=CGRect(x:x+3,y:max(0,bounds.height-22),width:width-6,height:18)
            var prefix="",offset=item.start
            boundsX.append((offset,x+8))
            for char in item.surface {
                prefix += String(char).replacingOccurrences(of:"\n",with:"↵").replacingOccurrences(of:" ",with:"␠")
                offset += String(char).unicodeScalars.count
                boundsX.append((offset,x+8+(prefix as NSString).size(withAttributes:[.font:font]).width))
            }
            x += width+4
        }
        content.frame=CGRect(x:0,y:0,width:max(bounds.width,x+6),height:bounds.height);scroll.contentSize=content.bounds.size
        layoutSelection()
    }
    private func layoutSelection() {
        guard let range=page?.joinRange else { left.isHidden=true;right.isHidden=true;selection.isHidden=true;return }
        left.isHidden=false;right.isHidden=false;selection.isHidden=false
        let a=boundsX.first{$0.0==range.lowerBound}?.1 ?? 0,b=boundsX.last{$0.0==range.upperBound}?.1 ?? 0
        left.frame=CGRect(x:a-11,y:0,width:22,height:bounds.height);right.frame=CGRect(x:b-11,y:0,width:22,height:bounds.height)
        selection.frame=CGRect(x:a,y:0,width:max(0,b-a),height:bounds.height)
        content.bringSubviewToFront(selection);content.bringSubviewToFront(left);content.bringSubviewToFront(right)
    }
    private func hit(_ p:CGPoint)->Occurrence? { items.first{labels[$0.id]?.frame.contains(p)==true} }
    @objc private func tapped(_ gesture:UITapGestureRecognizer) {
        if page.interaction == .editing { page.onOutsideTap?();return }
        guard page.interaction != .joining,let item=hit(gesture.location(in:content)) else { return };page.rowTap(item)
    }
    @objc private func moveCursor(_ gesture:UIPanGestureRecognizer) {
        guard var range=page.joinRange else { return }
        let p=gesture.location(in:content);finger=gesture.location(in:self);cursorIndex=gesture.view===left ? 0 : 1
        if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed { stopAutoScroll();cursorIndex=nil }
        else { autoScroll(finger.x) }
        guard let nearest=boundsX.min(by:{abs($0.1-p.x)<abs($1.1-p.x)}) else { return }
        if gesture.view===left { range=min(nearest.0,range.upperBound-1)..<range.upperBound }
        else { range=range.lowerBound..<max(nearest.0,range.lowerBound+1) }
        // Only use an actual grapheme boundary; handles never cross.
        if boundsX.contains(where:{$0.0==range.lowerBound}),boundsX.contains(where:{$0.0==range.upperBound}) { page.joinRange=range;layoutSelection() }
    }
    private func adjustCursor(_ handle:Int,delta:Int) {
        guard let range=page.joinRange else { return }
        let offsets=Array(Set(boundsX.map{$0.0})).sorted()
        let current=handle==0 ? range.lowerBound : range.upperBound
        guard let i=offsets.firstIndex(of:current),offsets.indices.contains(i+delta) else { return }
        let next=offsets[i+delta]
        if handle==0,next<range.upperBound { page.joinRange=next..<range.upperBound }
        if handle==1,next>range.lowerBound { page.joinRange=range.lowerBound..<next }
        layoutSelection()
    }
    private func autoScroll(_ x:CGFloat) {
        edgeSpeed=x<32 ? -5 : x>bounds.width-32 ? 5 : 0
        if edgeSpeed==0 { stopAutoScroll();return }
        if ticker==nil {
            let link=CADisplayLink(target:self,selector:#selector(tick));link.add(to:.main,forMode:.common);ticker=link
        }
    }
    private func stopAutoScroll() { ticker?.invalidate();ticker=nil;edgeSpeed=0 }
    @objc private func tick() {
        scroll.contentOffset.x=max(0,min(scroll.contentOffset.x+edgeSpeed,scroll.contentSize.width-bounds.width))
        if let index=cursorIndex,let range=page.joinRange,let near=boundsX.min(by:{abs($0.1-finger.x-scroll.contentOffset.x)<abs($1.1-finger.x-scroll.contentOffset.x)}) {
            if index==0,near.0<range.upperBound { page.joinRange=near.0..<range.upperBound }
            if index==1,near.0>range.lowerBound { page.joinRange=range.lowerBound..<near.0 }
            layoutSelection()
        } else if let source {
            let candidate=hit(CGPoint(x:finger.x+scroll.contentOffset.x,y:finger.y))
            target=candidate.flatMap{ParseGesture.neighbors(of:source.id,in:items).contains($0.id) ? $0 : nil}
        }
    }
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldReceive touch:UITouch)->Bool {
        if gestureRecognizer===hold,source != nil { cancelDrag();hold.isEnabled=false;hold.isEnabled=true;return false }
        return page?.interaction != .joining && page?.interaction != .editing && (page?.interaction != .dragging || source != nil)
    }
    @objc private func held(_ gesture:UILongPressGestureRecognizer) {
        let p=gesture.location(in:self)
        switch gesture.state {
        case .began:
            guard let item=hit(gesture.location(in:content)) else { return }
            source=item;origin=p;moved=false;target=nil;discarding=false;page.interaction = .dragging
            scroll.panGestureRecognizer.isEnabled=false;haptic.selectionChanged()
        case .changed:
            guard let source else { return };finger=p;moved = moved || hypot(p.x-origin.x,p.y-origin.y)>8
            discard.isHidden = !moved;discard.text="Discard “\(source.surface)”"
            let was=discarding;discarding=discard.frame.contains(p)
            discard.alpha=discarding ? 1 : 0.65
            let candidate=hit(gesture.location(in:content))
            let valid=candidate.flatMap{ParseGesture.neighbors(of:source.id,in:items).contains($0.id) ? $0 : nil}
            if target?.id != valid?.id || was != discarding { haptic.selectionChanged() }
            target=valid
            for item in items { labels[item.id]?.alpha=(item.id==source.id || item.id==target?.id) ? 1 : 0.65 }
            if !discarding { autoScroll(p.x) } else { stopAutoScroll() }
        case .ended:
            guard let source else { cancelDrag();return }
            let target=self.target,remove=discarding,dragged=moved;cancelDrag()
            if remove { action?("Discard",source) }
            else if dragged,let target { action?("Merge:\(target.id)",source) }
            else if !dragged {
                menuSource=source
                editMenu.presentEditMenu(with:UIEditMenuConfiguration(identifier:source.id as NSString,sourcePoint:p))
            }
        case .cancelled,.failed:cancelDrag()
        default:break
        }
    }
    private func cancelDrag() { stopAutoScroll();cursorIndex=nil;source=nil;target=nil;discard.isHidden=true;scroll.panGestureRecognizer.isEnabled=true;for label in labels.values { label.alpha=1 };if page?.interaction == .dragging { page.interaction = .browsing } }
    override func didMoveToWindow() { super.didMoveToWindow();if window==nil { cancelDrag() } }
    func editMenuInteraction(_ interaction:UIEditMenuInteraction,menuFor configuration:UIEditMenuConfiguration,suggestedActions:[UIMenuElement])->UIMenu? {
        guard let item=menuSource else { return nil }
        return UIMenu(children:["Edit","Join","Shatter"].map { name in UIAction(title:name,attributes:name=="Shatter" && item.surface.count<2 ? .disabled : []) { [weak self] _ in self?.source=nil;self?.action?(name,item) } })
    }
}

private final class ContextTermLabel:UILabel {
    var activate:(()->Bool)?
    override func accessibilityActivate()->Bool { activate?() ?? false }
}
private final class ContextCursor:UIView {
    var adjust:((Int)->Void)?
    override func accessibilityIncrement(){adjust?(1)}
    override func accessibilityDecrement(){adjust?(-1)}
}
