import SwiftUI

struct AppearanceSettings: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Appearance").font(.system(size: 21, weight: .semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            Form {
                Section("Workspace") {
                    Picker("Interface", selection: $model.interfaceStyle) { ForEach(InterfaceStyle.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    Picker("Panes", selection: $model.density) { ForEach(Density.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                    Toggle("Vertical tabs", isOn: $model.verticalTabs)
                    Toggle("Show pane titles", isOn: $model.showPaneTitles)
                }
                Section("Terminal") {
                    Toggle("Follow macOS appearance", isOn: $model.followSystemAppearance)
                    if model.followSystemAppearance {
                        Picker("Light theme", selection: $model.lightThemeName) { ForEach(model.themes.filter(\.isLight)) { Text($0.name).tag($0.name) } }
                        Picker("Dark theme", selection: $model.darkThemeName) { ForEach(model.themes.filter { !$0.isLight }) { Text($0.name).tag($0.name) } }
                    } else {
                        Picker("Theme", selection: Binding(get: { model.themeName }, set: { model.selectTheme($0) })) { ForEach(model.themes) { Text($0.name).tag($0.name) } }
                    }
                    TextField("Font", text: $model.fontName)
                    HStack { Text("Text size"); Slider(value: $model.fontSize, in: 9...24, step: 1); Text("\(Int(model.fontSize)) pt").monospacedDigit().frame(width: 42) }
                    Toggle("Thicken text", isOn: $model.fontOptions.thicken)
                    Button("Use Ghostty Font Settings") { model.importGhosttyFont() }
                    Toggle("Improve low-contrast text", isOn: $model.contrastCorrection)
                    Toggle("Copy text when selected", isOn: $model.copyOnSelection)
                    Toggle("Synchronize scrolling with other viewers", isOn: $model.synchronizeViewports)
                        .disabled(!model.supportsViewportSync())
                        .help(model.supportsViewportSync() ? "Share scrolling with viewers who enable this option." : "This host needs a newer illogical service to share scrolling.")
                    Button("Import Ghostty Themes…") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.importGhostty() } }
                }
                Section("Remote hosts") {
                    ForEach(model.hosts.filter { !$0.isLocal }) { host in
                        HStack { Label(host.name, systemImage: "network"); Spacer(); Button("Remove") { model.removeHost(host) }.foregroundStyle(.secondary) }
                    }
                    Button("Add Remote Host…") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.showAddHost = true } }
                }
            }.formStyle(.grouped)
        }.padding(24).frame(width: 540, height: 630)
    }
}

struct AddHostSheet: View {
    @ObservedObject var model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var executable = "~/.local/bin/illogical"
    @StateObject private var discovery = HostDiscovery()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Add Remote Host", systemImage: "network").font(.system(size: 21, weight: .semibold))
            Text("Connect to a Mac or Linux host using your existing SSH keys and configuration.").font(.system(size: 12)).foregroundStyle(.secondary)
            Form {
                TextField("Name", text: $name, prompt: Text("Development server"))
                TextField("Host", text: $address, prompt: Text("user@host or SSH alias"))
                TextField("illogical executable", text: $executable)
            }
            Text("Install the matching illogical service on the host first. The host must already be trusted by SSH; password prompts are not supported here.").font(.system(size: 11)).foregroundStyle(.secondary)
            HStack {
                Button("Discover Tailscale Services") { discovery.discover() }
                if discovery.loading { ProgressView().controlSize(.small) }
            }
            if let message = discovery.message { Text(message).font(.system(size: 11)).foregroundStyle(.secondary) }
            if !discovery.hosts.isEmpty {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(discovery.hosts) { host in
                            Button { name = host.name; address = host.address } label: {
                                HStack { Image(systemName: "network"); Text(host.name); Spacer(); Text(host.service).font(.system(size: 10)).foregroundStyle(.secondary) }.padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 160)
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction); Button("Connect") { model.addHost(name: name, address: address, executable: executable) }.keyboardShortcut(.defaultAction).disabled(address.trimmingCharacters(in: .whitespaces).isEmpty) }
        }.padding(28).frame(width: 480)
    }
}

struct RenameSheet: View {
    @ObservedObject var model: WorkspaceModel
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.renameTarget == "session" ? "Rename Session" : "Rename Tab").font(.headline)
            TextField("Name", text: $model.renameValue).focused($focused).onSubmit { model.finishRename() }
            HStack { Spacer(); Button("Cancel") { model.cancelRename() }.keyboardShortcut(.cancelAction); Button("Rename") { model.finishRename() }.keyboardShortcut(.defaultAction).disabled(!model.canRename) }
        }.padding(24).frame(width: 360).onAppear { focused = true }
    }
}

struct MigrationSheet: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                ForEach(0..<20) { index in
                    Capsule().fill(index.isMultiple(of: 2) ? Color.blue.opacity(0.5) : Color.orange.opacity(0.5)).frame(width: 3, height: 7)
                        .rotationEffect(.degrees(Double(index * 37))).offset(x: CGFloat((index * 83) % 410) - 205, y: CGFloat((index * 29) % 85) - 35)
                }
                Image(systemName: "paintpalette").font(.system(size: 42, weight: .light)).foregroundStyle(model.theme.tint)
            }.frame(height: 90)
            Text("Your themes, right at home.").font(.system(size: 23, weight: .semibold))
            Text("We found your Ghostty colors. Bring them into illogical with one click.").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack(spacing: 14) {
                ForEach(model.migration) { theme in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("~ ❯ echo hello").font(.system(size: 11, design: .monospaced))
                        Text("hello").font(.system(size: 11, design: .monospaced)).opacity(0.7)
                        HStack(spacing: 4) { ForEach(Array(theme.ansi.prefix(8).enumerated()), id: \.offset) { _, value in Circle().fill(Color(hex: value)).frame(width: 12, height: 12) } }
                        Text(theme.name).font(.system(size: 10, weight: .medium)).lineLimit(1).padding(.top, 10)
                    }.foregroundStyle(theme.text).padding(18).frame(maxWidth: .infinity, alignment: .leading).background(theme.color, in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(.vertical, 4)
            HStack { Button("Keep Current Theme") { model.migration = [] }; Spacer(); Button("Use These Themes") { model.useMigratedThemes() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(30).frame(width: 540)
    }
}
