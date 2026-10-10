import AppKit
import MyTermCore
import MyTermPlatform
import MyTermUI
import SwiftUI

struct PermissionsSettingsView: View {
    @State private var permissions = SystemPermissionController()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Group {
                Text("macOS treats programs you run in MyTerm as MyTerm, so a permission granted here applies to every pane. Nothing is requested until you click Grant or a program asks for it.")
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.textSecondary)
            }

            ForEach(SystemPermission.Group.allCases) { group in
                SettingsCard(group.title, insetRows: false) {
                    ForEach(group.permissions) { permission in
                        PermissionRow(permission: permission, permissions: permissions)
                            .padding(.vertical, 14)
                            .padding(.horizontal, 16)
                        if permission != group.permissions.last {
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                    }
                }
            }
        }
        .task { await permissions.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Most grants are finished in System Settings, so re-read them on the way back.
            Task { await permissions.refresh() }
        }
    }
}

private struct PermissionRow: View {
    let permission: SystemPermission
    let permissions: SystemPermissionController

    private var status: SystemPermissionStatus { permissions.status(of: permission) }
    private var isPending: Bool { permissions.pending.contains(permission) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(permission.detail)
                    .font(Theme.Font.ui(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            statusLabel

            if isPending {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Waiting for macOS to answer the \(permission.title) request")
            } else if let title = permission.requestButtonTitle(for: status) {
                Button(title) {
                    Task { await permissions.request(permission) }
                }
                .accessibilityLabel("\(title): \(permission.title)")
            }

            Button {
                permissions.openSystemSettings(for: permission)
            } label: {
                if permission.requestButtonTitle(for: status) == nil {
                    Text("Open System Settings")
                } else {
                    Image(systemName: "arrow.up.forward.app")
                }
            }
            .buttonStyle(.borderless)
            .help("Open \(permission.title) in System Settings")
            .accessibilityLabel("Open \(permission.title) in System Settings")
        }
    }

    private var statusLabel: some View {
        Text(status.label)
            .font(Theme.Font.ui(12))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
            .fixedSize()
            .accessibilityLabel("\(permission.title): \(status.label)")
    }

    private var statusColor: Color {
        switch status {
        case .granted: Theme.success
        case .denied, .restricted: Theme.danger
        case .notGranted, .notDetermined, .unknown, .informational: Theme.textSecondary
        }
    }
}
