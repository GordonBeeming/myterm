import MyTermCore
import MyTermRemoteProtocol
import SwiftUI

/// What agents did while the person was away, newest first, as an inbox.
///
/// This is the Mac's bell, kept. The Mac drops an entry once the user reaches its tab; the device
/// keeps every entry it has seen and marks what has been looked at, so the person can work down the
/// list and still scroll back through the day. Opening a row reads it here and only here: whether
/// that should also clear the dot on the Mac is not yet decided.
struct LatestView: View {
    let store: RemoteSessionStore
    /// Owned by the caller, so opening a row from here pushes onto this tab's own stack.
    @Binding var path: NavigationPath

    private var log: RemoteNotificationLog { store.notifications.log }

    var body: some View {
        Group {
            if log.isEmpty {
                ContentUnavailableView(
                    "Nothing Yet",
                    systemImage: "tray",
                    description: Text("When an agent finishes, or asks you something, while you are away from its tab, it shows up here.")
                )
                .accessibilityIdentifier("latest.empty")
            } else {
                List {
                    ForEach(log.entries) { entry in
                        Button {
                            store.notifications.markRead(entry.id)
                            path.append(entry.tabID)
                        } label: {
                            LatestRow(entry: entry)
                        }
                        .accessibilityIdentifier("latest.row")
                        .swipeActions(edge: .leading) {
                            Button(entry.isRead ? "Mark Unread" : "Mark Read",
                                   systemImage: entry.isRead ? "envelope.badge" : "envelope.open") {
                                store.notifications.markRead(entry.id, isRead: !entry.isRead)
                            }
                            .tint(.blue)
                        }
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("latest.list")
            }
        }
        .navigationDestination(for: String.self) { tabID in
            RemoteTabDestination(tabID: tabID, store: store)
        }
        .navigationTitle("Latest")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Mark All as Read") { store.notifications.markAllRead() }
                    .disabled(log.unreadCount == 0)
                    .accessibilityIdentifier("latest.markAllRead")
            }
        }
    }
}

/// One entry. Unread is bold with a dot; read stays in the list, dimmed, as history.
private struct LatestRow: View {
    let entry: RemoteNotificationLogEntry

    /// At an accessibility text size the elapsed time is wider than the row has room for beside
    /// the title: the title is squeezed to nothing and the time runs off the screen. Under the
    /// title, both fit.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var isQuestion: Bool { entry.activity == .awaitingInput }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // The dot keeps its room when read, so the text does not shift as rows are read.
            Circle()
                .fill(entry.isRead ? Color.clear : Color.accentColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityHidden(true)
            // The glyph differs as well as the color, so the two states never read alike.
            Image(systemName: isQuestion ? "questionmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isQuestion ? Color.orange : Color.accentColor)
                .opacity(entry.isRead ? 0.5 : 1)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                if dynamicTypeSize.isAccessibilitySize {
                    title
                    elapsed
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title
                        Spacer(minLength: 0)
                        elapsed
                            // The elapsed time is short and grows as it counts, so it keeps its
                            // width and the tab name gives way instead.
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                Text(entry.activity.attentionDescription)
                    .font(.subheadline)
                Text(entry.workspaceTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(entry.isRead ? .secondary : .primary)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(entry.isRead ? "Read" : "Unread")
    }

    private var title: some View {
        Text(entry.tabTitle)
            .font(entry.isRead ? .body : .body.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private var elapsed: some View {
        (Text(entry.date, style: .relative) + Text(" ago"))
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

#Preview {
    @Previewable @State var path = NavigationPath()

    let store = RemoteSessionStore(deviceName: "Preview")
    store.remoteClient(store.client, didReceive: .sample)
    store.remoteClient(store.client, didReceive: RemoteNotifications(entries: [
        RemoteNotification(
            tabID: "tab-3",
            workspaceID: "workspace-api",
            workspaceTitle: "api",
            tabTitle: "server",
            activity: .awaitingInput,
            date: Date().addingTimeInterval(-90)
        ),
        RemoteNotification(
            tabID: "tab-1",
            workspaceID: "workspace-site",
            workspaceTitle: "ssw.com.au",
            tabTitle: "build",
            activity: .finished,
            date: Date().addingTimeInterval(-1_500)
        ),
    ]))

    return NavigationStack(path: $path) {
        LatestView(store: store, path: $path)
    }
}
