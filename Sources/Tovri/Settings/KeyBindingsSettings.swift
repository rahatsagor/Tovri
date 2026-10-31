import SwiftUI

struct ShortcutRecorder: NSViewRepresentable {
    var shortcut: KeyShortcut?
    var onChange: (KeyShortcut?) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderField {
        let v = ShortcutRecorderField()
        v.shortcut = shortcut
        v.onChange = onChange
        return v
    }

    func updateNSView(_ v: ShortcutRecorderField, context: Context) {
        v.shortcut = shortcut
        v.onChange = onChange
    }
}

struct KeyBindingsSettings: View {
    @ObservedObject private var bindings = KeyBindings.shared
    @State private var query = ""
    @State private var onlyCustomized = false

    private var filtered: [CommandBinding] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return bindings.commands.filter { c in
            (!onlyCustomized || c.isCustomized) &&
            (q.isEmpty || c.title.lowercased().contains(q) || c.path.lowercased().contains(q) ||
             (c.shortcut?.display.lowercased().contains(q) ?? false))
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search commands or shortcuts", text: $query)
                    .textFieldStyle(.plain)
                Toggle("Customized", isOn: $onlyCustomized)
                    .toggleStyle(.checkbox)
                Button("Reset All") { bindings.resetAll() }
                    .disabled(!bindings.commands.contains { $0.isCustomized })
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))

            List(filtered) { c in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.title)
                        Text(c.path).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    let clashes = bindings.conflicts(for: c.shortcut, excluding: c.id)
                    if !clashes.isEmpty {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .help("Also used by: " + clashes.map { $0.title }.joined(separator: ", "))
                    }
                    ShortcutRecorder(shortcut: c.shortcut) { bindings.set($0, for: c.id) }
                        .frame(width: 130, height: 24)
                    Button {
                        bindings.reset(c.id)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Reset to default (\(c.defaultShortcut?.display ?? "none"))")
                    .opacity(c.isCustomized ? 1 : 0)
                    .disabled(!c.isCustomized)
                }
                .padding(.vertical, 2)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))

            Text("Click a shortcut and press new keys. Esc cancels, ⌫ removes the shortcut.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }
}
