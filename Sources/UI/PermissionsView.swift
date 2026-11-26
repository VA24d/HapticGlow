// Permissions screen: System Audio Recording + Input Monitoring.
import SwiftUI
import AppKit
import CoreGraphics

/// Launch a fresh instance of this app, then quit the current one (needed after Input Monitoring is granted).
@MainActor func relaunchApp() {
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.createsNewApplicationInstance = true
    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}

struct PermissionsView: View {
    @State private var model = AppModel.shared
    @State private var screenGranted = CGPreflightScreenCaptureAccess()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(title: "Permissions",
                           subtitle: "HapticGlow needs system audio access and Input Monitoring. Everything stays on this Mac.")

                PermissionRow(
                    title: "System Audio Recording",
                    detail: "Used by the System Audio Tap source. Lets HapticGlow hear what your Mac plays so the glow and haptics follow the music. Audio is analysed in memory for levels only. It is never recorded, stored or sent anywhere."
                        + (model.audioState == .needsPermission
                           ? " Already switched on? That entry belongs to an older build: select HapticGlow under System Audio Recording Only, remove it with −, then reopen HapticGlow."
                           : ""),
                    symbol: "waveform",
                    status: model.audioState.engineStatus,
                    chip: model.audioState.label
                ) {
                    Button("Open Settings") { model.openPrivacySettings(.audioCapture) }
                }

                PermissionRow(
                    title: "Screen & System Audio Recording",
                    detail: "Only needed when the audio source is Screen Capture Audio. HapticGlow uses the screen recording API for its audio stream and never reads or stores your screen.",
                    symbol: "rectangle.dashed.badge.record",
                    status: screenGranted ? .running : .needsPermission("Screen Recording"),
                    chip: screenGranted ? "Granted" : "Not granted"
                ) {
                    if !screenGranted {
                        Button("Request Access") { _ = CGRequestScreenCaptureAccess(); screenGranted = CGPreflightScreenCaptureAccess() }
                    }
                    Button("Open Settings") { model.openPrivacySettings(.screenRecording) }
                }

                PermissionRow(
                    title: "Input Monitoring",
                    detail: "Lets HapticGlow see key presses for typing glow and key sounds. Only the key position and timing are used; what you type is never read or stored.",
                    symbol: "keyboard",
                    status: model.hasInputMonitoring ? .running : .needsPermission("Input Monitoring"),
                    chip: model.hasInputMonitoring ? "Granted" : "Not granted"
                ) {
                    if !model.hasInputMonitoring {
                        Button("Request Access") { model.requestInputMonitoring() }
                    }
                    Button("Open Settings") { model.openPrivacySettings(.inputMonitoring) }
                }

                Card {
                    HStack(alignment: .top, spacing: Theme.Space.m) {
                        Image(systemName: "arrow.clockwise").foregroundStyle(Theme.textSecondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Changed a permission?").font(Theme.Font.label)
                            Text("macOS applies Input Monitoring only after an app restarts. If a key press does not register after you allow it, relaunch HapticGlow.")
                                .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 12)
                        Button("Relaunch HapticGlow") { relaunchApp() }.controlSize(.small)
                    }
                }
            }
            .pageLayout()
        }
        .onAppear { model.refreshPermissions(); screenGranted = CGPreflightScreenCaptureAccess() }
    }
}

struct PermissionRow<Actions: View>: View {
    let title: String
    let detail: String
    let symbol: String
    let status: EngineStatus
    let chip: String
    @ViewBuilder var actions: Actions

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        StatusChip(text: chip, status: status)
                    }
                    Text(detail).font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) { actions }.controlSize(.small).padding(.top, 4)
                }
            }
        }
    }
}
