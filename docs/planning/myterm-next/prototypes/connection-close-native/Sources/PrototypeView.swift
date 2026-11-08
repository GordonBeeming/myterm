import SwiftUI

struct PrototypeView: View {
    @State private var model = PrototypeModel()
    @State private var reviewApproval = false
    @State private var navigationAway = false
    private let variants = ["A · In each pane", "B · Connection strip", "C · Server inspector"]

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 650
            VStack(spacing: 0) {
                controls
                Divider()
                if navigationAway {
                    ContentUnavailableView {
                        Label("Workspace still running", systemImage: "square.stack")
                    } description: {
                        Text("Navigating away or closing the app preserves sessions.")
                    } actions: {
                        Button("Return to workspace") { navigationAway = false }
                    }
                } else {
                    workspace(compact: compact)
                }
                if model.showFixtureControls {
                    Divider()
                    Text(model.event).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                HStack {
                    Button("‹") { model.variant = (model.variant + 2) % 3 }
                    Text(variants[model.variant]).font(.callout).frame(maxWidth: .infinity)
                    Button("›") { model.variant = (model.variant + 1) % 3 }
                }.padding(10).background(.regularMaterial)
            }
        }
        .sheet(isPresented: $model.showPending) { PendingCloseView(model: model) }
        .confirmationDialog(model.closingWorkspace ? "Close shared workspace?" : "Close shared session?",
                            isPresented: $model.confirmation, titleVisibility: .visible) {
            Button("Close and end sessions", role: .destructive) { model.closeConfirmed() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("A process is still running. Closing will terminate it.")
        }
        .alert("Review account approval", isPresented: $reviewApproval) {
            Button("Done", role: .cancel) { }
        } message: {
            Text("Open account settings to review this client's approval. Signing in alone does not approve a client. The approval ceremony is designed in its own ticket.")
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MyTerm · Connection & close prototype").font(.headline)
            HStack {
                Menu("Scenarios") {
                    ForEach(["Four servers", "Running process", "Partial close", "No route", "Removed server", "Queue expires", "Remote edit", "Focused deletion"], id: \.self) { name in
                        Button(name) { model.scenario(name) }
                    }
                }
                Button("Reset") { model.reset() }
                Toggle("Prototype controls", isOn: $model.showFixtureControls).font(.caption)
                Spacer()
                Button { model.showPending = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel("Close activity")
                    .help("Close activity")
            }
        }.padding(12)
    }

    private func workspace(compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Release workspace").font(.title3.bold())
                Spacer()
                Menu {
                    Button("Navigate away") { navigationAway = true }
                    Button("Close shared workspace…", role: .destructive) {
                        model.closingWorkspace = true
                        if model.visible.contains(where: \.hasRunningProcess) { model.confirmation = true }
                        else { model.closeConfirmed() }
                    }
                } label: { Image(systemName: "ellipsis.circle").padding(4) }
            }
            if model.variant == 1 { connectionStrip }
            if compact && !model.visible.isEmpty {
                Picker("Pane", selection: $model.selected) {
                    ForEach(model.visible) { pane in Text(pane.name).tag(pane.id) }
                }.pickerStyle(.menu)
            }
            HStack(alignment: .top) {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: compact ? 1 : 2), spacing: 12) {
                        ForEach(compact ? model.visible.filter { $0.id == model.selected } : model.visible) { pane in
                            PanePrototypeView(pane: pane, model: model, reviewApproval: $reviewApproval)
                        }
                    }
                    if model.visible.isEmpty {
                        ContentUnavailableView("No open terminals", systemImage: "terminal")
                    }
                }
                if model.variant == 2 && !compact {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Servers").font(.headline)
                        serverList
                    }.frame(width: 220).padding().background(.regularMaterial)
                }
            }
            if model.variant == 2 && compact {
                DisclosureGroup("Server inspector") { serverList }
            }
            if model.showFixtureControls {
                Toggle("Keep last terminal frame", isOn: $model.stalePreview).font(.caption)
            }
        }.padding(12)
    }

    private var connectionStrip: some View {
        ScrollView(.horizontal) {
            HStack {
                ForEach(model.visible) { pane in
                    Button { model.selected = pane.id } label: {
                        VStack(alignment: .leading) {
                            Text(pane.server).font(.caption.bold())
                            Text(pane.connection.rawValue).font(.caption)
                        }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var serverList: some View {
        ForEach(model.visible) { pane in
            VStack(alignment: .leading, spacing: 4) {
                Text(pane.server).font(.callout.bold())
                Text("\(pane.identity) · \(pane.route)").font(.caption).foregroundStyle(.secondary)
                Text(pane.connection.rawValue).font(.caption)
                Button(pane.connection.action) {
                    if pane.connection == .unauthorized { reviewApproval = true }
                    else { model.panes[pane.id].connection = .reconnecting }
                }.font(.caption).disabled(pane.connection == .connected)
            }
        }
    }
}
