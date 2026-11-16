import AVFoundation
import SwiftUI

struct Photo: Identifiable, Equatable {
    let id = UUID()
    let image: CGImage

    static func == (lhs: Photo, rhs: Photo) -> Bool { lhs.id == rhs.id }
}

@MainActor
@Observable
final class CaptureModel {
    enum Phase: Equatable {
        case starting
        case live
        case review(Photo)
        /// On the clipboard, waiting for a manual ⌘V because Accessibility access is off.
        case copied(Photo)
        case denied
        case unavailable
    }

    var phase: Phase = .starting
    var mirrorPreview = true
}

struct CaptureActions {
    var capture: @MainActor () -> Void
    var retake: @MainActor () -> Void
    var send: @MainActor (Photo) -> Void
    var close: @MainActor () -> Void
    var openCameraSettings: @MainActor () -> Void
}

struct CaptureView: View {
    static let stageSize = CGSize(width: 640, height: 360)
    static let barHeight: CGFloat = 72

    let model: CaptureModel
    let session: AVCaptureSession
    let actions: CaptureActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flashCount = 0

    var body: some View {
        VStack(spacing: 0) {
            stage
                .frame(width: Self.stageSize.width, height: Self.stageSize.height)
                .background(.black)
                .overlay { flash }
            controls
                .frame(maxWidth: .infinity)
                .frame(height: Self.barHeight)
                .background(.bar)
        }
        .frame(width: Self.stageSize.width)
        .background {
            // Esc closes, whichever control has focus.
            Button("Close", action: actions.close)
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var stage: some View {
        switch model.phase {
        case .starting:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Starting camera")
        case .live:
            CameraPreview(session: session, mirrored: model.mirrorPreview)
        case .review(let photo), .copied(let photo):
            PhotoView(photo: photo)
        case .denied:
            CameraMessage(
                title: "Camera access is off",
                detail: "Turn it on in System Settings → Privacy & Security → Camera."
            ) {
                Button("Open Settings", action: actions.openCameraSettings)
            }
        case .unavailable:
            CameraMessage(title: "No camera found", detail: "Connect a camera, then try again.") {
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch model.phase {
        case .review(let photo):
            HStack(spacing: 12) {
                Button("Retake", action: actions.retake)
                    .keyboardShortcut(.delete, modifiers: [])
                Spacer()
                Button {
                    actions.send(photo)
                } label: {
                    Label("Send to WhatsApp", systemImage: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 16)
        case .copied:
            HStack(spacing: 12) {
                Text("Photo copied. Click the chat, then press ⌘V.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: actions.close)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.horizontal, 16)
        default:
            Button("Take Photo", action: snap)
                .buttonStyle(ShutterButtonStyle())
                .accessibilityLabel("Take Photo")
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.phase != .live)
                .help("Take photo (Space)")
        }
    }

    private var flash: some View {
        Color.white
            .keyframeAnimator(initialValue: 0.0, trigger: flashCount) { view, opacity in
                view.opacity(opacity)
            } keyframes: { _ in
                LinearKeyframe(0.8, duration: 0.02)
                CubicKeyframe(0, duration: 0.3)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func snap() {
        actions.capture()
        guard case .review = model.phase else { return }
        AccessibilityNotification.Announcement("Photo taken").post()
        if !reduceMotion {
            flashCount += 1
        }
    }
}

private struct PhotoView: View {
    let photo: Photo

    var body: some View {
        Image(photo.image, scale: 1, label: Text("Your photo"))
            .resizable()
            .scaledToFit()
            .onDrag {
                PhotoStore.saveJPEG(photo.image).flatMap { NSItemProvider(contentsOf: $0) } ?? NSItemProvider()
            }
            .help("Drag the photo into any chat or folder")
    }
}

private struct CameraMessage<Actions: View>: View {
    let title: String
    let detail: String
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "video.slash")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            actions
        }
        .padding(24)
    }
}

private struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShutterButton(isPressed: configuration.isPressed)
    }
}

private struct ShutterButton: View {
    let isPressed: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(.white, lineWidth: 3)
            Circle()
                .fill(.white)
                .padding(6)
                .scaleEffect(isPressed ? 0.88 : 1)
        }
        .frame(width: 48, height: 48)
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(Circle())
        .animation(.easeOut(duration: 0.12), value: isPressed)
    }
}

// MARK: - Live preview

private struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let mirrored: Bool

    func makeNSView(context: Context) -> PreviewView {
        PreviewView(session: session)
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.mirrored = mirrored
    }
}

private final class PreviewView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer

    var mirrored = true {
        didSet { applyMirroring() }
    }

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        // Aspect-fit shows the whole frame, so the photo matches the preview exactly.
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
        super.init(frame: .zero)
        layer = previewLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyMirroring()
    }

    private func applyMirroring() {
        guard let connection = previewLayer.connection, connection.isVideoMirroringSupported else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        connection.isVideoMirrored = mirrored
    }
}
