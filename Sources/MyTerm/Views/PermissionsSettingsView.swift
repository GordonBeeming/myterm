import AppKit
import MyTermCore
import MyTermPlatform
import SwiftUI

struct PermissionsSettingsView: View {
    @State private var permissions = SystemPermissionController()

    var body: some View {
        Form {
            Section {
                Text("macOS treats programs you run in MyTerm as MyTerm, so a permission granted here applies to every pane. Nothing is requested until you click Grant or a program asks for it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(SystemPermission.Group.allCases) { group in
                Section(group.title) {
                    ForEach(group.permissions) { permission in
                        PermissionRow(permission: permission, permissions: permissions)
                    }
                }
            }
        }
        .formStyle(.grouped)
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
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open \(permission.title) in System Settings")
            .accessibilityLabel("Open \(permission.title) in System Settings")
        }
    }

    private var statusLabel: some View {
        Label(status.label, systemImage: statusSymbol)
            .font(.footnote)
            .foregroundStyle(statusColor)
            .labelStyle(.titleAndIcon)
            .fixedSize()
            .accessibilityLabel("\(permission.title): \(status.label)")
    }

    private var statusSymbol: String {
        switch status {
        case .granted: "checkmark.circle.fill"
        case .denied, .restricted: "xmark.circle.fill"
        case .notGranted: "minus.circle"
        case .notDetermined, .unknown: "circle.dashed"
        case .informational: "info.circle"
        }
    }

    private var statusColor: Color {
        switch status {
        case .granted: .green
        case .denied, .restricted: .red
        case .notGranted, .notDetermined, .unknown, .informational: .secondary
        }
    }
}
