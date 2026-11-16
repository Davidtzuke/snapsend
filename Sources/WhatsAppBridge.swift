import AppKit
import Carbon.HIToolbox

enum PhotoStore {
    static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SnapSend", isDirectory: true)

    static func purge() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes a JPEG named like a macOS screenshot, so a dragged file reads well in chats.
    static func saveJPEG(_ image: CGImage) -> URL? {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = directory.appendingPathComponent("Photo \(formatter.string(from: .now)).jpg")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            NSLog("SnapSend: could not save photo: \(error.localizedDescription)")
            return nil
        }
    }

    /// Puts the photo on the clipboard as PNG and TIFF, the same pair a macOS screenshot uses.
    static func copyToPasteboard(_ image: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]),
              let tiff = rep.tiffRepresentation else {
            return false
        }
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(tiff, forType: .tiff)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.writeObjects([item])
    }
}

@MainActor
enum WhatsAppBridge {
    static let bundleID = "net.whatsapp.WhatsApp"

    /// Pastes the clipboard into whichever WhatsApp chat is open, bringing WhatsApp
    /// forward first if needed. WhatsApp then shows its own preview with a caption field.
    /// The caller checks Accessibility access before calling this.
    static func pasteIntoOpenChat() async {
        // A held Return would otherwise auto-repeat into WhatsApp and send the preview.
        await waitForReturnKeyRelease()

        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID {
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                NSLog("SnapSend: WhatsApp is not installed; photo left on the clipboard")
                NSSound.beep()
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    NSLog("SnapSend: could not open WhatsApp: \(error.localizedDescription)")
                }
            }
        }

        guard await waitUntilFrontmost() else {
            NSLog("SnapSend: WhatsApp did not come forward; photo left on the clipboard")
            NSSound.beep()
            return
        }

        // Let WhatsApp focus its message field. A cold launch needs longer to load chats.
        try? await Task.sleep(for: wasRunning ? .milliseconds(250) : .seconds(3))
        postCommandV()
    }

    private static func waitForReturnKeyRelease(timeout: Duration = .seconds(1)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while isReturnKeyDown, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static var isReturnKeyDown: Bool {
        CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_Return))
            || CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_KeypadEnter))
    }

    private static func waitUntilFrontmost(timeout: Duration = .seconds(6)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
