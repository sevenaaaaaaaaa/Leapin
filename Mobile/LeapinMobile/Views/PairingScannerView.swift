import SwiftUI
import AVFoundation

/// Camera sheet that reads the Mac's pairing QR ("leapin://pair?...") and pairs in
/// one step.
///
/// Typing an IP and a 40-character token is the step people give up on, so the scan
/// path is the primary one; manual entry stays available underneath.
struct PairingScannerView: View {
    @Environment(ConsoleStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var onPaired: () -> Void = {}

    @State private var message: String?
    @State private var connecting = false
    @State private var showManual = false

    var body: some View {
        NavigationStack {
            ZStack {
                CameraScanner(isPaused: connecting) { payload in
                    handle(payload)
                }
                .ignoresSafeArea()

                VStack(spacing: 12) {
                    Text("对准 Mac 上的配对二维码")
                        .font(LPFont.section)
                        .foregroundStyle(LP.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(.ultraThinMaterial, in: Capsule())

                    Spacer()

                    if let message {
                        Text(message)
                            .font(LPFont.caption)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(LP.danger.opacity(0.9), in: RoundedRectangle(cornerRadius: LP.radiusSmall, style: .continuous))
                            .padding(.horizontal, LP.gutter)
                    }
                    if connecting { ProgressView().tint(.white) }

                    Button("改为手动输入") { showManual = true }
                        .font(LPFont.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 24)
                }
            }
            .navigationTitle("扫码配对")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $showManual) {
                NavigationStack {
                    SetupView()
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("关闭") { showManual = false }
                            }
                        }
                }
            }
            .onChange(of: store.endpoint) { _, value in
                if value != nil { dismiss(); onPaired() }
            }
        }
    }

    private func handle(_ payload: String) {
        guard !connecting else { return }
        guard let endpoint = ConsoleEndpoint.parse(pairingURL: payload) else {
            message = "这不是 Leapin 的配对码"
            return
        }
        connecting = true
        message = nil
        Task {
            let ok = await store.connect(to: endpoint)
            connecting = false
            if ok {
                dismiss()
                onPaired()
            } else {
                message = store.lastError ?? "连接失败，确认手机和 Mac 在同一个 Wi-Fi"
            }
        }
    }
}

// MARK: - Camera

private struct CameraScanner: UIViewRepresentable {
    var isPaused: Bool
    var onCode: (String) -> Void

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        context.coordinator.start(preview: view.previewLayer, onCode: onCode)
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.setPaused(isPaused)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let session = AVCaptureSession()
        private let queue = DispatchQueue(label: "app.leapin.mobile.scanner")
        private var onCode: ((String) -> Void)?
        private var handled = false
        private var paused = false

        func start(preview: AVCaptureVideoPreviewLayer, onCode: @escaping (String) -> Void) {
            self.onCode = onCode
            preview.session = session
            preview.videoGravity = .resizeAspectFill

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }
            let configure = { [weak self] in
                guard let self else { return }
                self.session.beginConfiguration()
                if self.session.canAddInput(input) { self.session.addInput(input) }
                let output = AVCaptureMetadataOutput()
                if self.session.canAddOutput(output) {
                    self.session.addOutput(output)
                    output.setMetadataObjectsDelegate(self, queue: self.queue)
                    output.metadataObjectTypes = [.qr]
                }
                self.session.commitConfiguration()
                self.session.startRunning()
            }
            if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                queue.async(execute: configure)
            } else {
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    if granted { self.queue.async(execute: configure) }
                }
            }
        }

        func setPaused(_ paused: Bool) {
            self.paused = paused
            if !paused { handled = false }
        }

        func stop() {
            session.stopRunning()
        }

        func metadataOutput(_ output: AVCaptureMetadataOutput,
                            didOutput metadataObjects: [AVMetadataObject],
                            from connection: AVCaptureConnection) {
            guard !paused, !handled,
                  let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = object.stringValue else { return }
            handled = true
            let callback = onCode
            DispatchQueue.main.async { callback?(value) }
        }
    }
}

private final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
