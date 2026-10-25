import SwiftUI
import UIKit
import Combine
#if canImport(MLKitDigitalInkRecognition)
import MLKitDigitalInkRecognition
import MLKitCommon
#endif

struct InkTouch { var point:CGPoint;var time:Int }
@MainActor final class HandwritingModel:ObservableObject {
    @Published var ready=false
    @Published var downloading=false
    @Published var status=""
    @Published var candidates:[String]=[]
    @Published var busy=false
    private var generation=0
    private var task:Task<Void,Never>?
    #if canImport(MLKitDigitalInkRecognition)
    private var model:DigitalInkRecognitionModel?
    private var recognizer:DigitalInkRecognizer?
    private var observers:[NSObjectProtocol]=[]
    init() {
        if let identifier=try? DigitalInkRecognitionModelIdentifier.from(languageTag:"ja") {
            model=DigitalInkRecognitionModel(modelIdentifier:identifier)
        }
        refresh()
        for name in [Notification.Name.mlkitModelDownloadDidSucceed,Notification.Name.mlkitModelDownloadDidFail] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] notification in
                Task { @MainActor in
                    guard let self,let remote=notification.userInfo?[ModelDownloadUserInfoKey.remoteModel] as? DigitalInkRecognitionModel,remote.modelIdentifier.languageTag=="ja" else { return }
                    self.downloading=false;self.refresh()
                    self.status=(notification.userInfo?[ModelDownloadUserInfoKey.error] as? Error)?.localizedDescription ?? (self.ready ? "Ready for offline handwriting" : "Download failed. Please retry.")
                }
            })
        }
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
    private func refresh() { ready=model.map{ModelManager.modelManager().isModelDownloaded($0)} ?? false }
    func download() {
        guard let model else { status="Japanese handwriting model is unavailable.";return }
        downloading=true;status="Downloading Japanese handwriting model…"
        ModelManager.modelManager().download(model,conditions:ModelDownloadConditions(allowsCellularAccess:true,allowsBackgroundDownloading:true))
    }
    func remove() {
        guard let model else { return };cancel();recognizer=nil
        ModelManager.modelManager().deleteDownloadedModel(model) { [weak self] error in
            Task { @MainActor in self?.refresh();self?.status=error?.localizedDescription ?? "Model removed. Typing is still available." }
        }
    }
    func changed(_ strokes:[[InkTouch]]) {
        cancel();guard ready,let model,!strokes.isEmpty else { return }
        let token=generation
        task=Task {
            try? await Task.sleep(nanoseconds:450_000_000)
            guard !Task.isCancelled,token==generation else { return }
            busy=true
            if recognizer==nil { recognizer=DigitalInkRecognizer.digitalInkRecognizer(options:DigitalInkRecognizerOptions(model:model)) }
            let ink=Ink(strokes:strokes.map{Stroke(points:$0.map{StrokePoint(x:Float($0.point.x),y:Float($0.point.y),t:$0.time)})})
            recognizer?.recognize(ink:ink) { [weak self] result,error in
                Task { @MainActor in
                    guard let self,token==self.generation else { return }
                    self.busy=false;self.status=error?.localizedDescription ?? ""
                    self.candidates=Array((result?.candidates.map(\.text) ?? []).prefix(8))
                }
            }
        }
    }
    #else
    init() { ready=ProcessInfo.processInfo.arguments.contains("--drawing-fixture") || ProcessInfo.processInfo.arguments.contains("--ink-ready") }
    func download() { status="Handwriting requires the device build." }
    func remove() {}
    func changed(_ strokes:[[InkTouch]]) {}
    #endif
    func cancel() { generation += 1;task?.cancel();candidates=[];busy=false }
}
struct InkCanvas:UIViewRepresentable {
    @Binding var strokes:[[InkTouch]]
    var onBegin:()->Void
    var onChange:()->Void
    func makeUIView(context:Context)->InkCanvasView { InkCanvasView() }
    func updateUIView(_ view:InkCanvasView,context:Context) {
        if !view.isDrawing { view.strokes=strokes };view.began=onBegin
        view.changed={ strokes=$0;onChange() };view.setNeedsDisplay()
    }
}
final class InkCanvasView:UIView {
    var strokes:[[InkTouch]]=[]
    private var lockedScrolls:[(UIScrollView,Bool)]=[]
    var isDrawing=false
    var began:(()->Void)?
    var changed:(([[InkTouch]])->Void)?
    override init(frame:CGRect) { super.init(frame:frame);isMultipleTouchEnabled=false;backgroundColor = .systemBackground
        let stroke=InkStrokeRecognizer(target:self,action:#selector(trackStroke(_:)));addGestureRecognizer(stroke) }
    required init?(coder:NSCoder) { fatalError() }
    private func lockScrolling() {
        var ancestor=superview
        while let view=ancestor {
            if let scroll=view as? UIScrollView { lockedScrolls.append((scroll,scroll.isScrollEnabled));scroll.isScrollEnabled=false }
            ancestor=view.superview
        }
    }
    private func unlockScrolling() { for (scroll,enabled) in lockedScrolls { scroll.isScrollEnabled=enabled };lockedScrolls=[] }
    override func didMoveToWindow() { super.didMoveToWindow();if window==nil { unlockScrolling() } }
    private func append(_ touch:UITouch) { strokes[strokes.count-1].append(InkTouch(point:touch.location(in:self),time:Int(touch.timestamp*1000)));setNeedsDisplay() }
    @objc private func trackStroke(_ recognizer:InkStrokeRecognizer) {
        switch recognizer.state {
        case .began:
            isDrawing=true;lockScrolling();began?();strokes.append(recognizer.samples)
        case .changed:
            if !strokes.isEmpty { strokes[strokes.count-1] += recognizer.samples }
        case .ended:
            if !strokes.isEmpty { strokes[strokes.count-1] += recognizer.samples }
            isDrawing=false;unlockScrolling();changed?(strokes)
        case .cancelled,.failed:
            if isDrawing,!strokes.isEmpty { strokes.removeLast() }
            isDrawing=false;unlockScrolling();changed?(strokes)
        default:break
        }
        setNeedsDisplay()
    }
    override func draw(_ rect:CGRect) {
        UIColor.label.setStroke()
        for stroke in strokes {
            guard let first=stroke.first else { continue };let path=UIBezierPath();path.lineWidth=4;path.lineCapStyle = .round;path.move(to:first.point)
            for point in stroke.dropFirst() { path.addLine(to:point.point) };path.stroke()
        }
    }
}

/// Claims a stroke immediately, before a sheet/scroll pan can cancel raw touches.
private final class InkStrokeRecognizer:UIGestureRecognizer {
    var samples:[InkTouch]=[]
    private func sample(_ touches:Set<UITouch>,_ event:UIEvent) {
        guard let touch=touches.first else { return }
        samples=(event.coalescedTouches(for:touch) ?? [touch]).map { InkTouch(point:$0.location(in:view),time:Int($0.timestamp*1000)) }
    }
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent) { sample(touches,event);state = .began }
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent) { sample(touches,event);state = .changed }
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent) { sample(touches,event);state = .ended }
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent) { state = .cancelled }
    override func canBePrevented(by preventingGestureRecognizer:UIGestureRecognizer)->Bool { false }
    override func reset() { samples=[];super.reset() }
}
