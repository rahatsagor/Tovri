import AppKit
import Combine
import Sparkle

/// Sparkle auto-updates. Releases are verified with the EdDSA key in Info.plist, so updates work
/// without an Apple Developer ID.
final class Updater: NSObject, ObservableObject, NSMenuItemValidation {
    static let shared = Updater()

    @Published private(set) var canCheck = false
    @Published private(set) var lastChecked: Date?

    private var controller: SPUStandardUpdaterController!
    private var observation: NSKeyValueObservation?

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    /// Debug builds and builds without a feed and signing key never update, so a development copy
    /// cannot replace itself with a release.
    var isConfigured: Bool {
        #if DEBUG
        return false
        #else
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let url = URL(string: feed), url.scheme == "https", url.host != nil,
              let decoded = Data(base64Encoded: key), decoded.count == 32
        else { return false }
        return true
        #endif
    }

    /// Why updates are off, in words for the person using this copy.
    var unavailableReason: String {
        #if DEBUG
        return "Debug builds never check for updates, so a development copy can’t replace itself with a release."
        #else
        return "This copy of Tovri was built without an update key. Install a release from GitHub or Homebrew to get automatic updates."
        #endif
    }

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func start() {
        guard isConfigured else { return }
        controller.startUpdater()
        lastChecked = controller.updater.lastUpdateCheckDate
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            DispatchQueue.main.async { self?.canCheck = updater.canCheckForUpdates }
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        guard isConfigured else {
            let alert = NSAlert()
            alert.messageText = "Updates aren’t available in this build"
            alert.informativeText = unavailableReason
            alert.runModal()
            return
        }
        controller.checkForUpdates(sender)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(checkForUpdates(_:)) else { return true }
        // An unconfigured build keeps the item enabled so it can explain why updates are off.
        return !isConfigured || canCheck
    }
}

extension Updater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastChecked = updater.lastUpdateCheckDate
    }
}
