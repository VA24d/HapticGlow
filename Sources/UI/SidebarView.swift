// Sidebar: app header with running dot, three sections, per-engine status dots.
import SwiftUI

struct SidebarView: View {
    @State private var model = AppModel.shared
    private static let sections = ["Live", "Engines", "App"]

    private var selection: Binding<SidebarItem?> {
        Binding(get: { model.selection }, set: { if let v = $0 { model.selection = v } })
    }

    var body: some View {
        List(selection: selection) {
            ForEach(Self.sections, id: \.self) { name in
                Section(name) {
                    ForEach(SidebarItem.allCases.filter { $0.section == name }) { item in
                        row(item).tag(item)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { SidebarHeader() }
    }

    private func row(_ item: SidebarItem) -> some View {
        HStack(spacing: 0) {
            Label(item.title, systemImage: item.symbol).font(.system(size: 13))
            Spacer(minLength: 6)
            if let s = status(item) { StatusDot(status: s, size: 6) }
        }
    }

    private func status(_ item: SidebarItem) -> EngineStatus? {
        switch item {
        case .glow: return model.glowStatus
        case .haptics: return model.hapticStatus
        case .sounds: return model.soundStatus
        case .audio: return model.audioState.engineStatus
        case .permissions:
            return (model.hasInputMonitoring && model.audioState != .needsPermission) ? nil : .needsPermission("Permission")
        default: return nil
        }
    }
}

/// App name and a steady running dot. The dot used to pulse with a repeatForever animation started
/// from onChange; that transaction leaked into the sidebar rows (their labels faded in and out) and
/// kept the window redrawing at display rate, which cost CPU and battery. A steady dot says the same.
private struct SidebarHeader: View {
    @State private var model = AppModel.shared

    var body: some View {
        HStack(spacing: 8) {
            Text("HapticGlow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Circle()
                .fill(model.isRunning ? Theme.ok : Theme.textTertiary)
                .frame(width: 7, height: 7)
                .animation(Theme.snappy, value: model.isRunning)
            Spacer()
            Text(model.isRunning ? "Running" : "Idle")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}
