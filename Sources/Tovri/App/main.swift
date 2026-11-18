import AppKit

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--verify-sparkle-update" {
    MainActor.assumeIsolated {
        Updater.runLoopbackVerification(outputPath: CommandLine.arguments[2])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
