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

    @MainActor
    static func runLoopbackVerification(outputPath: String) -> Never {
        func writeReport(_ payload: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
            try? data.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
        }

        #if DEBUG
        writeReport(["ok": false, "stage": "refused", "error": "Loopback Sparkle verification is disabled in debug builds."])
        Darwin.exit(2)
        #else
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let url = URL(string: feed),
              url.scheme == "http",
              url.host == "127.0.0.1",
              let decoded = Data(base64Encoded: key),
              decoded.count == 32
        else {
            writeReport(["ok": false, "stage": "refused", "error": "Requires an http://127.0.0.1 SUFeedURL and valid 32-byte SUPublicEDKey."])
            Darwin.exit(2)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let driver = LoopbackVerifyDriver { payload in
            writeReport(payload)
        }
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: driver)

        DispatchQueue.main.async {
            do {
                try updater.start()
                updater.checkForUpdates()
            } catch {
                driver.fail(stage: "start", error: error)
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            driver.timeout()
        }

        app.run()
        Darwin.exit(0)
        #endif
    }
}

#if !DEBUG
@MainActor
private final class LoopbackVerifyDriver: NSObject, SPUUserDriver, SPUUpdaterDelegate {
    private let report: ([String: Any]) -> Void
    private var foundVersion: String?
    private var foundBuild: String?
    private var downloadedBytes: UInt64 = 0
    private var extracted = false
    private var readyHandled = false
    private var finished = false

    init(report: @escaping ([String: Any]) -> Void) {
        self.report = report
    }

    func fail(stage: String, error: any Error) {
        guard !finished else { return }
        finished = true
        report(["ok": false, "stage": stage, "error": error.localizedDescription])
        DispatchQueue.main.async { Darwin.exit(1) }
    }

    func timeout() {
        guard !finished else { return }
        finished = true
        report(["ok": false, "stage": "timeout", "error": "Sparkle update verification timed out."])
        Darwin.exit(3)
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: false, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        foundVersion = appcastItem.displayVersionString
        foundBuild = appcastItem.versionString
        reply(.install)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        fail(stage: "updateNotFound", error: error)
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        fail(stage: "updaterError", error: error)
        acknowledgement()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        downloadedBytes += length
    }

    func showDownloadDidStartExtractingUpdate() {
        extracted = true
    }

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard !finished else {
            reply(.dismiss)
            return
        }
        finished = true
        readyHandled = true
        report([
            "ok": true,
            "stage": "readyToInstall",
            "foundVersion": foundVersion ?? "",
            "foundBuild": foundBuild ?? "",
            "downloadedBytes": downloadedBytes,
            "extracted": extracted,
        ])
        // Dismiss without relaunching UI, then terminate immediately so Sparkle's Autoupdate
        // daemon finishes Stage 2 & Stage 3 bundle replacement on disk cleanly.
        reply(.dismiss)
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func dismissUpdateInstallation() {}

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        guard !readyHandled else { return }
        if let error {
            fail(stage: "didFinishUpdateCycle", error: error)
        } else if !finished {
            finished = true
            report(["ok": false, "stage": "didFinishUpdateCycle", "error": "Update cycle finished without becoming ready to install."])
            DispatchQueue.main.async { Darwin.exit(1) }
        }
    }
}
#endif
