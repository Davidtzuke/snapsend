import AVFoundation
import CoreImage

enum CameraError: Error {
    case noDevice
    case cannotAddInput
    case cannotAddOutput
}

/// Owns the capture session and keeps the most recent frame so a snapshot
/// matches exactly what the preview showed.
///
/// Thread safety: session configuration and start/stop run on `sessionQueue`.
/// `latestFrame` and `acceptsFrames` are guarded by `frameLock`. Everything else is immutable.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "snapsend.camera.session")
    private let frameQueue = DispatchQueue(label: "snapsend.camera.frames")
    private let ciContext = CIContext()
    private let frameLock = NSLock()
    private var latestFrame: CVPixelBuffer?
    private var acceptsFrames = false
    private var configuredDeviceID: String?

    static var needsPermissionPrompt: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined
    }

    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    var hasFrame: Bool {
        frameLock.withLock { latestFrame != nil }
    }

    /// Starts the camera the system prefers (built-in, external, or an iPhone via Continuity Camera).
    /// Returns true when that camera faces the user, so the preview should be mirrored.
    func start() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                do {
                    let facesUser = try self.configureIfNeeded()
                    self.frameLock.withLock {
                        self.latestFrame = nil
                        self.acceptsFrames = true
                    }
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    continuation.resume(returning: facesUser)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            // Drop frames still in flight so nothing from this session lingers in memory.
            self.frameLock.withLock {
                self.acceptsFrames = false
                self.latestFrame = nil
            }
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }

    /// The latest camera frame as an image, or nil if no frame has arrived yet.
    func snapshot(mirrored: Bool) -> CGImage? {
        guard let frame = frameLock.withLock({ latestFrame }) else { return nil }
        var image = CIImage(cvPixelBuffer: frame)
        if mirrored {
            image = image.oriented(.upMirrored)
        }
        return ciContext.createCGImage(image, from: image.extent)
    }

    // MARK: - Session queue only

    private func configureIfNeeded() throws -> Bool {
        guard let device = AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video) else {
            throw CameraError.noDevice
        }
        // Continuity Camera uses the iPhone's rear lens, which should not be mirrored.
        let facesUser = device.deviceType != .continuityCamera
        guard configuredDeviceID != device.uniqueID else { return facesUser }

        // Open the new device before touching the session, so a busy or unplugged
        // camera leaves the old setup intact.
        let input = try AVCaptureDeviceInput(device: device)
        configuredDeviceID = nil

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        for oldInput in session.inputs {
            session.removeInput(oldInput)
        }
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)

        if session.outputs.isEmpty {
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)
            guard session.canAddOutput(output) else { throw CameraError.cannotAddOutput }
            session.addOutput(output)
        }

        if session.canSetSessionPreset(.high) {
            session.sessionPreset = .high
        }
        configuredDeviceID = device.uniqueID
        return facesUser
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (frame queue)

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let frame = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameLock.withLock {
            if acceptsFrames {
                latestFrame = frame
            }
        }
    }
}
