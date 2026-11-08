import SwiftUI

struct PanePrototypeView: View {
    let pane: PrototypePane
    @Bindable var model: PrototypeModel
    @Binding var reviewApproval: Bool
    @State private var showServer = false

    private var statusIcon: String {
        switch pane.connection {
        case .connected: "server.rack"
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath"
        case .disconnected: "pause.circle"
        case .failed: "exclamationmark.circle"
        case .unauthorized: "lock.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(pane.name) { model.selected = pane.id }.buttonStyle(.plain).font(.callout)
                Spacer()
                Button { showServer = true } label: {
                    Image(systemName: statusIcon).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Server details for \(pane.name): \(pane.connection.rawValue)")
                .help("\(pane.server) · \(pane.connection.rawValue)")
                .popover(isPresented: $showServer) { serverDetails }
                Button { model.requestClose(pane.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Close \(pane.name)")
            }
            Group {
                if pane.connection == .connected || model.stalePreview {
                    Text("$ swift build\nBuild complete.\n$ ▌")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(pane.connection == .connected ? Color.primary : Color.secondary)
                        .accessibilityLabel(pane.connection == .connected ? "Terminal fixture output" : "Last terminal frame, paused, not live")
                }
            }
            .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            if pane.connection == .connected {
                TextField("", text: Binding(get: { "" }, set: { _ in
                    model.selected = pane.id
                    model.event = "Input fixture: \(pane.name) remains usable."
                })).accessibilityLabel("Terminal input for \(pane.name)")
            }
            if model.showFixtureControls {
                Divider()
                Picker("Fixture state", selection: $model.panes[pane.id].connection) {
                    ForEach(ConnectionState.allCases) { state in Text(state.rawValue).tag(state) }
                }.font(.caption)
                Toggle("Running process fixture", isOn: $model.panes[pane.id].hasRunningProcess).font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 290, alignment: .topLeading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(model.selected == pane.id ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: 1))
    }

    private var serverDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pane.server).font(.headline)
            Text("\(pane.identity) · \(pane.route)").font(.caption).foregroundStyle(.secondary)
            Text(pane.connection.rawValue).font(.callout)
            Text(pane.connection.message).font(.callout).fixedSize(horizontal: false, vertical: true)
            if pane.connection != .connected {
                Button(pane.connection.action) {
                    showServer = false
                    if pane.connection == .unauthorized { reviewApproval = true }
                    else { model.panes[pane.id].connection = .reconnecting }
                }
            }
        }.padding(16).frame(width: 280)
    }
}
