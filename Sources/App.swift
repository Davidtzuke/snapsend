import AppKit
import Carbon.HIToolbox
import ServiceManagement

@main
@MainActor
enum SnapSendMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

enum Preferences {
    private static let mirrorKey = "mirrorPhotos"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [mirrorKey: true])
    }

    static var mirrorPhotos: Bool {
        get { UserDefaults.standard.bool(forKey: mirrorKey) }
        set { UserDefaults.standard.set(newValue, forKey: mirrorKey) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var hotKey: GlobalHotKey?
    private let capture = CapturePanelController()
    private let takePhotoItem = NSMenuItem(title: "Take Photo", action: #selector(AppDelegate.takePhoto), keyEquivalent: "")
    private let mirrorItem = NSMenuItem(title: "Mirror Selfies", action: #selector(AppDelegate.toggleMirror), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(AppDelegate.toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        PhotoStore.purge()

        // ⌃⌥⌘C, "C" for camera. Change the key here if it clashes with another app.
        hotKey = GlobalHotKey(
            keyCode: UInt32(kVK_ANSI_C),
            modifiers: UInt32(controlKey | optionKey | cmdKey)
        ) { [weak self] in
            self?.capture.toggle()
        }

        setUpStatusItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        PhotoStore.purge()
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "SnapSend")

        let menu = NSMenu()
        menu.delegate = self

        takePhotoItem.target = self
        if hotKey != nil {
            takePhotoItem.keyEquivalent = "c"
            takePhotoItem.keyEquivalentModifierMask = [.control, .option, .command]
        }
        menu.addItem(takePhotoItem)
        menu.addItem(.separator())

        mirrorItem.target = self
        menu.addItem(mirrorItem)
        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit SnapSend", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        item.menu = menu
        statusItem = item
    }

    func menuWillOpen(_ menu: NSMenu) {
        mirrorItem.state = Preferences.mirrorPhotos ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func takePhoto() {
        capture.show()
    }

    @objc private func toggleMirror() {
        Preferences.mirrorPhotos.toggle()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("SnapSend: could not change login item: \(error.localizedDescription)")
            NSSound.beep()
        }
    }
}
