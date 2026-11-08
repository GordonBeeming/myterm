import SwiftUI

struct PendingCloseView: View {
    @Bindable var model: PrototypeModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Shared closure and server termination are separate. A queued command is not proof that a process ended.")
                }
                ForEach(model.panes.filter { $0.closure != .open }) { pane in
                    Section(pane.name + " · " + pane.server) {
                        Text(pane.closure.rawValue).font(.headline)
                        Text(pane.identity).font(.caption).foregroundStyle(.secondary)
                        detail(pane)
                    }
                }
                if model.panes.allSatisfy({ $0.closure == .open }) { Text("No pending closes.") }
            }
            .navigationTitle("Close activity")
            .toolbar { Button("Done") { dismiss() } }
        }
        .frame(minWidth: 300, minHeight: 480)
    }

    @ViewBuilder private func detail(_ pane: PrototypePane) -> some View {
        switch pane.closure {
        case .queued:
            Text("Relay accepted the encrypted command for up to seven days. Waiting for this server to confirm termination.")
            Button("Fixture: server confirms termination") { model.reconcile(pane.id) }
        case .unsent:
            Text("Closed in your layout. Cleanup will sync automatically when a connection returns.")
            Button("Fixture: relay becomes reachable") { model.panes[pane.id].closure = .queued }
        case .expired:
            Text("The relay command expired. The session remains deleted. This server will reconcile against the current authorized layout when it returns; no old command needs selecting.")
            Button("Fixture: fresh layout, termination confirmed") { model.reconcile(pane.id) }
            Button("Fixture: stale layout rejected") { model.event = "Stale or partial layout cannot authorize termination; status remains unconfirmed." }
        case .removed:
            Text("Historical record. This server was removed, so its final process state is unknown. Removal preserved its local processes and data.")
        case .terminated:
            Text("The assigned server confirmed its runtime resources ended.")
        case .open: EmptyView()
        }
    }
}
