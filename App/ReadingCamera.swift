import SwiftUI
import AVFoundation
import CoreMotion
import Vision

/// Preview stays live only until the first capture. Returning to it requires Next page.
struct ReadingCamera: UIViewControllerRepresentable {
    var automatic: Bool
    var captured: (Data) -> Void
    var failed: (String) -> Void
    func makeUIViewController(context: Context) -> ReadingCameraController {
        let controller = ReadingCameraController()
        controller.automatic = automatic; controller.captured = captured; controller.failed = failed
        return controller
    }
    func updateUIViewController(_ controller: ReadingCameraController, context: Context) { controller.automatic = automatic }
    static func dismantleUIViewController(_ controller: ReadingCameraController, coordinator: ()) { controller.stop() }
}

final class ReadingCameraController: UIViewController, AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "reading.camera")
    private let motion = CMMotionManager()
    private let photos = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    private var preview: AVCaptureVideoPreviewLayer?
    private var capturedOnce = false
    private var stopped = false
    private var steadySince: Date?
    private var lastFrame = Date.distantPast
    private var lastRectangle: CGRect?
    private var hint = UILabel()
    var automatic = true
    var captured: ((Data) -> Void)?
    var failed: ((String) -> Void)?
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .black
        hint.text = "Point at a page · hold still"; hint.textColor = .white; hint.textAlignment = .center
        hint.backgroundColor = UIColor.black.withAlphaComponent(0.5); hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        let shutter = UIButton(type: .system); shutter.setImage(UIImage(systemName: "circle.inset.filled", withConfiguration: UIImage.SymbolConfiguration(pointSize: 54)), for: .normal)
        shutter.tintColor = .white; shutter.accessibilityLabel = "Capture page"; shutter.translatesAutoresizingMaskIntoConstraints = false
        shutter.addTarget(self, action: #selector(manualCapture), for: .touchUpInside); view.addSubview(shutter)
        NSLayoutConstraint.activate([hint.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),hint.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),hint.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),hint.heightAnchor.constraint(equalToConstant: 40),shutter.centerXAnchor.constraint(equalTo: view.centerXAnchor),shutter.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),shutter.heightAnchor.constraint(equalToConstant: 70)])
        Task { [weak self] in
            guard let self else { return }
            let allowed: Bool
            if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { allowed = true }
            else { allowed = await AVCaptureDevice.requestAccess(for: .video) }
            if allowed { queue.async { self.configure() } }
            else { hint.text = "Enable Camera in Settings, or import a photo" }
        }
    }
    private func configure() {
        guard !stopped else { return }
        do {
            session.beginConfiguration(); session.sessionPreset = .photo
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { throw StorageError.database("Camera unavailable. Import a photo instead.") }
            self.device = device
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(photos) else { throw StorageError.database("Cannot configure camera") }
            session.addInput(input); session.addOutput(photos)
            let frames = AVCaptureVideoDataOutput(); frames.alwaysDiscardsLateVideoFrames = true
            frames.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            if session.canAddOutput(frames) { session.addOutput(frames); frames.setSampleBufferDelegate(self, queue: queue) }
            session.commitConfiguration()
            motion.deviceMotionUpdateInterval = 0.1; motion.startDeviceMotionUpdates()
            DispatchQueue.main.async {
                let layer = AVCaptureVideoPreviewLayer(session: self.session); layer.videoGravity = .resizeAspectFill
                self.view.layer.insertSublayer(layer, at: 0); self.preview = layer; self.view.setNeedsLayout()
            }
            session.startRunning()
        } catch { session.commitConfiguration(); DispatchQueue.main.async { self.failed?(error.localizedDescription) } }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); preview?.frame = view.bounds }
    @objc private func manualCapture() { queue.async { self.takePhoto() } }
    private func takePhoto() {
        guard !capturedOnce, session.isRunning else { return }
        capturedOnce = true
        if let connection = photos.connection(with: .video), connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        photos.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
        DispatchQueue.main.async { self.hint.text = "Saving page…" }
    }
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error { queue.async { self.capturedOnce = false }; DispatchQueue.main.async { self.failed?(error.localizedDescription) }; return }
        guard let data = photo.fileDataRepresentation() else { queue.async { self.capturedOnce = false }; return }
        stop()
        DispatchQueue.main.async { self.captured?(data) }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard automatic, !capturedOnce, Date().timeIntervalSince(lastFrame) > 0.3 else { return }
        lastFrame = Date()
        guard let motion = motion.deviceMotion, let device, !device.isAdjustingFocus, !device.isAdjustingExposure else { steadySince = nil; return }
        let r = motion.rotationRate, a = motion.userAcceleration
        guard abs(r.x)+abs(r.y)+abs(r.z) < 0.12, abs(a.x)+abs(a.y)+abs(a.z) < 0.08 else { steadySince = nil; return }
        let request = VNDetectRectanglesRequest(); request.maximumObservations = 1; request.minimumConfidence = 0.65
        request.minimumSize = 0.35; request.minimumAspectRatio = 0.3; request.maximumAspectRatio = 1
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              (try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right).perform([request])) != nil,
              let rect = request.results?.first?.boundingBox else { steadySince = nil; lastRectangle = nil; return }
        if let previous = lastRectangle, abs(previous.midX-rect.midX)+abs(previous.midY-rect.midY)+abs(previous.width-rect.width)+abs(previous.height-rect.height) < 0.04 {
            if steadySince == nil { steadySince = Date() }
            if Date().timeIntervalSince(steadySince!) > 1.2 { takePhoto() }
        } else { steadySince = nil }
        lastRectangle = rect
    }
    func stop() { motion.stopDeviceMotionUpdates(); queue.async { self.stopped = true; if self.session.isRunning { self.session.stopRunning() } } }
}
