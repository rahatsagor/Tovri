import SwiftUI

struct UpdatesSettings: View {
    @ObservedObject private var updater = Updater.shared

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        Form {
            Section("Updates") {
                if updater.isConfigured {
                    Toggle("Check for updates automatically", isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.automaticallyChecks = $0 }))
                    Toggle("Download and install updates automatically", isOn: Binding(get: { updater.automaticallyDownloads }, set: { updater.automaticallyDownloads = $0 }))
                        .disabled(!updater.automaticallyChecks)
                    LabeledContent {
                        Button("Check Now") { updater.checkForUpdates(nil) }
                            .disabled(!updater.canCheck)
                    } label: {
                        Text(version)
                        if let last = updater.lastChecked {
                            Text("Last checked \(last.formatted(.relative(presentation: .named)))")
                        }
                    }
                } else {
                    LabeledContent {
                        Text("Updates are off in this build.")
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(version)
                        Text(updater.unavailableReason)
                    }
                }
            }
            Section("About") {
                LabeledContent("Release notes") {
                    Link("View on GitHub", destination: ProjectLinks.releases)
                }
                LabeledContent("Source code") {
                    Link("github.com/rahatsagor/Tovri", destination: ProjectLinks.repository)
                }
            }
        }
        .formStyle(.grouped)
    }
}
