import AppKit
import SwiftUI

/// A floating panel that takes keyboard input without activating SnapSend,
/// so WhatsApp stays the active app and ⌘V lands in the open chat.
final class CapturePanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

@MainActor
final class CapturePanelController: NSObject, NSWindowDelegate {
    private let camera = CameraController()
    private let model = CaptureModel()
    private lazy var panel: CapturePanel = makePanel()
    /// Bumped on every camera start and stop, so a slow start can tell it's stale.
    private var generation = 0
    private var cameraWanted = false
    private var spaceObserver: NSObjectProtocol?

    override init() {
        super.init()
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.dismissUnlessWaiting() }
        }
    }

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard !panel.isVisible else {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        // Files from the last session have been dropped wherever they went by now.
        PhotoStore.purge()
        position(panel)
        panel.makeKeyAndOrderFront(nil)
        startCamera()
    }

    func hide() {
        // Reset first: ordering out resigns key, which calls back into dismissUnlessWaiting.
        model.phase = .starting
        stopCamera()
        panel.orderOut(nil)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        model.phase = .starting
        stopCamera()
    }

    func windowDidResignKey(_ notification: Notification) {
        dismissUnlessWaiting()
    }

    /// Closes the panel once the user moves on, so the camera never runs unseen.
    /// Stays open while a permission prompt or the camera settings hint needs it.
    private func dismissUnlessWaiting() {
        guard panel.isVisible else { return }
        switch model.phase {
        case .live, .review, .copied:
            hide()
        case .starting, .denied, .unavailable:
            break
        }
    }

    // MARK: - Camera

    private func startCamera() {
        generation += 1
        cameraWanted = true
        let current = generation
        let willPrompt = CameraController.needsPermissionPrompt
        model.phase = .starting

        Task {
            guard await CameraController.requestAccess() else {
                if current == generation { model.phase = .denied }
                return
            }
            guard current == generation else { return }
            if willPrompt {
                // The system prompt took keyboard focus.
                panel.makeKey()
            }
            do {
                let facesUser = try await camera.start()
                guard current == generation else {
                    // A stop raced ahead of this start; make sure the camera ends up off.
                    if !cameraWanted { camera.stop() }
                    return
                }
                model.mirrorPreview = facesUser
                await waitForFirstFrame()
                guard current == generation else { return }
                model.phase = .live
            } catch {
                NSLog("SnapSend: camera failed to start: \(error)")
                if current == generation { model.phase = .unavailable }
            }
        }
    }

    private func stopCamera() {
        generation += 1
        cameraWanted = false
        camera.stop()
    }

    private func waitForFirstFrame(timeout: Duration = .seconds(5)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !camera.hasFrame, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
    }

    // MARK: - Actions

    private func capture() {
        let mirrored = Preferences.mirrorPhotos && model.mirrorPreview
        guard model.phase == .live, let image = camera.snapshot(mirrored: mirrored) else {
            NSSound.beep()
            return
        }
        model.phase = .review(Photo(image: image))
    }

    private func retake() {
        model.phase = .live
    }

    private func send(_ photo: Photo) {
        guard PhotoStore.copyToPasteboard(photo.image) else {
            NSSound.beep()
            return
        }
        guard CGPreflightPostEventAccess() else {
            // Shows the Accessibility prompt. Until it's granted, the user pastes by hand.
            _ = CGRequestPostEventAccess()
            model.phase = .copied(photo)
            return
        }
        hide()
        Task { await WhatsAppBridge.pasteIntoOpenChat() }
    }

    private func openCameraSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Window

    private func makePanel() -> CapturePanel {
        let size = NSSize(
            width: CaptureView.stageSize.width,
            height: CaptureView.stageSize.height + CaptureView.barHeight
        )
        let panel = CapturePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.title = "SnapSend"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Camera UI reads best dark, like Photo Booth and FaceTime.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.hide() }

        let actions = CaptureActions(
            capture: { [weak self] in self?.capture() },
            retake: { [weak self] in self?.retake() },
            send: { [weak self] photo in self?.send(photo) },
            close: { [weak self] in self?.hide() },
            openCameraSettings: { [weak self] in self?.openCameraSettings() }
        )
        panel.contentView = NSHostingView(
            rootView: CaptureView(model: model, session: camera.session, actions: actions)
        )
        return panel
    }

    /// Centers the panel slightly above the middle of the screen the pointer is on.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else {
            panel.center()
            return
        }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.08
        ))
    }
}
