import SwiftUI

/// The Settings window (Command-,). Every change applies to all windows at once.
struct SettingsView: View {
    @Bindable private var preferences = Preferences.shared
    @ObservedObject private var hostStore = HostProfileStore.shared
    @State private var showAddHost = false
    @State private var importedThemes: [TerminalTheme] = []
    @State private var importError: String?

    var body: some View {
        Form {
            Section("Workspace") {
                Picker("Interface", selection: $preferences.interfaceStyle) {
                    ForEach(InterfaceStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Panes", selection: $preferences.density) {
                    ForEach(Density.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Toggle("Vertical tabs", isOn: $preferences.verticalTabs)
                Toggle("Show pane titles", isOn: $preferences.showPaneTitles)
                LabeledContent("Unfocused panes") {
                    Slider(value: $preferences.unfocusedPaneOpacity, in: 0.5...1) { Text("Unfocused panes") }
                        .labelsHidden()
                }
                .help("How visible panes without focus stay, like Ghostty's unfocused-split-opacity.")
            }
            Section("Theme") {
                Toggle("Follow macOS appearance", isOn: $preferences.followSystemAppearance)
                if preferences.followSystemAppearance {
                    Picker("Light theme", selection: $preferences.lightThemeName) {
                        ForEach(preferences.themes.filter(\.isLight)) { Text($0.name).tag($0.name) }
                    }
                    Picker("Dark theme", selection: $preferences.darkThemeName) {
                        ForEach(preferences.themes.filter { !$0.isLight }) { Text($0.name).tag($0.name) }
                    }
                } else {
                    Picker("Theme", selection: Binding(get: { preferences.themeName }, set: { preferences.selectTheme($0) })) {
                        ForEach(preferences.themes) { Text($0.name).tag($0.name) }
                    }
                }
                Button("Import Ghostty Themes…") { importThemes() }
            }
            Section("Terminal") {
                TextField("Font", text: $preferences.fontName)
                LabeledContent("Text size") {
                    HStack {
                        Slider(value: $preferences.fontSize, in: 9...24, step: 1) { Text("Text size") }.labelsHidden()
                        Text("\(Int(preferences.fontSize)) pt").monospacedDigit().frame(width: 42, alignment: .trailing)
                    }
                }
                Toggle("Thicken text", isOn: $preferences.fontOptions.thicken)
                Button("Use Ghostty Font Settings") {
                    do { try preferences.importGhosttyFont() } catch { importError = error.localizedDescription }
                }
                Toggle("Improve low-contrast text", isOn: $preferences.contrastCorrection)
                Toggle("Copy text when selected", isOn: $preferences.copyOnSelection)
                Toggle("Synchronize scrolling with other viewers", isOn: $preferences.synchronizeViewports)
                    .help("Share scrolling with other clients that enable this option. Needs a current illogical service.")
            }
            Section("Remote hosts") {
                ForEach(hostStore.hosts.filter { !$0.isLocal }) { host in
                    HStack {
                        Label(host.name, systemImage: "network")
                        Spacer()
                        Button("Remove") { hostStore.remove(host.id) }.foregroundStyle(.secondary)
                    }
                }
                Button("Add Remote Host…") { showAddHost = true }
            }
        }
        .formStyle(.grouped)
        // A fixed height that fits small displays; the form scrolls.
        .frame(width: 520, height: 600)
        .sheet(isPresented: $showAddHost) { AddHostSheet() }
        .sheet(isPresented: Binding(get: { !importedThemes.isEmpty }, set: { if !$0 { importedThemes = [] } })) {
            MigrationSheet(themes: importedThemes, tint: preferences.theme.tint) { adopt in
                if adopt { preferences.adopt(importedThemes) }
                importedThemes = []
            }
        }
        .alert("Could not import from Ghostty", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func importThemes() {
        do { importedThemes = try GhosttyThemeImporter.importConfiguration() } catch { importError = error.localizedDescription }
    }
}

struct AddHostSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var executable = "~/.local/bin/illogical"
    @State private var error: String?
    @StateObject private var discovery = HostDiscovery()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Add Remote Host", systemImage: "network").font(.system(size: 21, weight: .semibold))
            Text("Connect to a Mac or Linux host using your existing SSH keys and configuration.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name, prompt: Text("Development server"))
                TextField("Host", text: $address, prompt: Text("user@host or SSH alias"))
                TextField("illogical executable", text: $executable)
            }
            Text("Install the matching illogical service on the host first. The host must already be trusted by SSH; password prompts are not supported here.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("Discover Tailscale Services") { discovery.discover() }
                if discovery.loading { ProgressView().controlSize(.small) }
            }
            if let message = error ?? discovery.message {
                Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if !discovery.hosts.isEmpty {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(discovery.hosts) { host in
                            Button { name = host.name;address = host.address } label: {
                                HStack {
                                    Image(systemName: "network")
                                    Text(host.name)
                                    Spacer()
                                    Text(host.service).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                .padding(8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    error = HostProfileStore.shared.add(name: name, address: address, executable: executable)
                    if error == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 480)
    }
}

struct RenameSheet: View {
    let request: RenameRequest
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @State private var name = ""
    @FocusState private var focused: Bool

    private var canRename: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(request.title).font(.headline)
            TextField("Name", text: $name)
                .focused($focused)
                .onSubmit { if canRename { onCommit(name) } }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Rename") { onCommit(name) }.keyboardShortcut(.defaultAction).disabled(!canRename)
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear { name = request.name;focused = true }
    }
}

/// Previews themes imported from Ghostty before applying them.
struct MigrationSheet: View {
    let themes: [TerminalTheme]
    let tint: Color
    let onFinish: (_ adopt: Bool) -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "paintpalette").font(.system(size: 42, weight: .light)).foregroundStyle(tint).frame(height: 70)
            Text("Your themes, right at home.").font(.system(size: 23, weight: .semibold))
            Text("We found your Ghostty colors. Bring them into illogical with one click.")
                .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 14) {
                ForEach(themes) { theme in ThemePreview(theme: theme) }
            }
            .padding(.vertical, 4)
            HStack {
                Button("Keep Current Theme") { onFinish(false) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use These Themes") { onFinish(true) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 540)
    }
}

private struct ThemePreview: View {
    let theme: TerminalTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("~ ❯ echo hello").font(.system(size: 11, design: .monospaced))
            Text("hello").font(.system(size: 11, design: .monospaced)).opacity(0.7)
            HStack(spacing: 4) {
                ForEach(Array(theme.ansi.prefix(8).enumerated()), id: \.offset) { _, value in
                    Circle().fill(Color(hex: value)).frame(width: 12, height: 12)
                }
            }
            Text(theme.name).font(.system(size: 10, weight: .medium)).lineLimit(1).padding(.top, 10)
        }
        .foregroundStyle(theme.text)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.color.opacity(theme.effectiveBackgroundOpacity), in: RoundedRectangle(cornerRadius: 12))
    }
}
