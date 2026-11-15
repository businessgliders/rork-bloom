import AVFoundation
import SwiftUI
import UIKit

/// Full-screen camera for scanning a label or photographing a pill. Uses AVFoundation directly
/// (built-in or external cameras) and returns one still image.
struct CameraCaptureView: View {
    enum Purpose {
        case label, photo

        var title: String { self == .label ? "Scan the label" : "Photo of your pill or box" }
        var hint: String {
            self == .label
                ? "Fill the frame with the medication name and directions. Text is read on your iPhone."
                : (AppStore.shared.isShared
                    ? "Shown next to the medication so it's easy to spot. Shared with your partner."
                    : "Stays on your iPhone. Shown next to the medication so it's easy to spot.")
        }
    }

    var purpose: Purpose
    var onCapture: (UIImage) -> Void
    var onCancel: () -> Void

    @State private var camera = CameraController()
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.state {
            case .starting:
                ProgressView().tint(.white)
            case .running:
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
            case .denied:
                message(
                    icon: "camera.fill",
                    title: "Camera access is off",
                    body: "Allow camera access in Settings to scan a label. You can also choose a photo instead.",
                    action: ("Open Settings", {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    })
                )
            case .unavailable:
                message(icon: "camera.badge.ellipsis", title: "No camera found", body: "Choose a photo from your library instead.", action: nil)
            }

            VStack {
                HStack {
                    Button {
                        camera.stop()
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.ultraThinMaterial, in: .circle)
                    }
                    .accessibilityLabel("Close camera")
                    Spacer()
                }
                .padding(.horizontal, 20)

                VStack(spacing: 4) {
                    Text(purpose.title)
                        .font(.bloom(.headline, weight: .heavy))
                    Text(purpose.hint)
                        .font(.bloom(.footnote))
                        .multilineTextAlignment(.center)
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 32)
                .padding(.top, 4)

                if purpose == .label && camera.state == .running {
                    // Sits between the hint and the shutter so it never overlaps them, on any screen shape.
                    labelFrame
                } else {
                    Spacer()
                }

                if camera.state == .running {
                    Button {
                        capture()
                    } label: {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                            Circle().fill(camera.isCapturing ? Theme.blush : .white).frame(width: 64, height: 64)
                        }
                    }
                    .buttonStyle(PressableStyle())
                    .disabled(camera.isCapturing)
                    .accessibilityLabel(purpose == .label ? "Scan label" : "Take photo")
                    .accessibilityIdentifier("camera-shutter")
                    .padding(.bottom, 24)
                }
            }
        }
        .task { await camera.start() }
        .onDisappear { camera.stop() }
        .statusBarHidden()
    }

    private var labelFrame: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 3, dash: [14, 10]))
            .aspectRatio(1.4, contentMode: .fit)
            .frame(maxWidth: 360, maxHeight: .infinity)
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func message(icon: String, title: String, body: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .semibold))
                .foregroundStyle(Theme.blush)
            Text(title)
                .font(.bloom(.title3, weight: .heavy))
            Text(body)
                .font(.bloom(.subheadline))
                .multilineTextAlignment(.center)
                .opacity(0.8)
            if let action {
                Button(action.0, action: action.1)
                    .buttonStyle(BloomSoftButtonStyle(tint: .white, fill: Theme.blush))
                    .frame(maxWidth: 240)
            }
        }
        .foregroundStyle(.white)
        .padding(32)
    }

    private func capture() {
        Haptics.tap()
        camera.takePhoto { image in
            guard let image else { return }
            camera.stop()
            Haptics.success()
            onCapture(image)
        }
    }
}

// MARK: - Controller

@Observable
final class CameraController: NSObject, AVCapturePhotoCaptureDelegate {
    enum State: Equatable { case starting, running, denied, unavailable }

    var state: State = .starting
    var isCapturing = false

    @ObservationIgnored let session = AVCaptureSession()
    @ObservationIgnored private let output = AVCapturePhotoOutput()
    @ObservationIgnored private var completion: ((UIImage?) -> Void)?
    @ObservationIgnored private let queue = DispatchQueue(label: "bloom.camera")

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else { state = .denied; return }
        default:
            state = .denied
            return
        }

        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(iOS 17.0, *) { types.append(.external) }
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        let device = devices.first(where: { $0.position == .back }) ?? devices.first
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
            state = .unavailable
            return
        }

        session.beginConfiguration()
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        if session.inputs.isEmpty, session.canAddInput(input) { session.addInput(input) }
        if session.outputs.isEmpty, session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        let session = self.session
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                session.startRunning()
                continuation.resume()
            }
        }
        state = session.isRunning ? .running : .unavailable
    }

    func stop() {
        let session = self.session
        queue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    func takePhoto(_ completion: @escaping (UIImage?) -> Void) {
        guard self.completion == nil else { return }
        guard let connection = output.connection(with: .video), connection.isEnabled, connection.isActive else {
            completion(nil)
            return
        }
        self.completion = completion
        isCapturing = true
        let settings = AVCapturePhotoSettings()
        if output.supportedFlashModes.contains(.auto) { settings.flashMode = .auto }
        output.capturePhoto(with: settings, delegate: self)
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let data = error == nil ? photo.fileDataRepresentation() : nil
        Task { @MainActor in
            let completion = self.completion
            self.completion = nil
            self.isCapturing = false
            completion?(data.flatMap(UIImage.init(data:)))
        }
    }
}

// MARK: - Preview layer

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
