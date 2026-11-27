// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Live Wallpaper: library grid, import, per-display assignment, fit, pause rules, playlist.
import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct WallpaperPage: View {
    @Bindable var model = AppModel.shared
    @State private var library = WallpaperLibrary.shared
    @State private var engine = WallpaperEngine.shared
    @State private var selected: String?
    @State private var linkText = ""
    @State private var importing = false
    @State private var progress: Double = 0
    @State private var message: String?
    @State private var messageIsError = false
    @State private var dropTargeted = false
    @State private var confirmDynamic: Bool = false
    @State private var pendingID: String?

    private var cfg: Binding<WallpaperConfig> { $model.wallpaper }
    private var selectedItem: WallpaperInfo? { library.item(selected) ?? library.item(model.wallpaper.itemID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                PageHeader(title: "Live Wallpaper", subtitle: "Animated and video wallpapers on the desktop, paused whenever nobody can see them.")
                masterCard
                libraryCard
                if let item = selectedItem { detailCard(item) }
                playbackCard
                if NSScreen.screens.count > 1 { displaysCard }
                playlistCard
            }
            .pageLayout()
        }
        .background(Theme.window)
        .alert("Your current wallpaper cannot be restored from a file", isPresented: $confirmDynamic) {
            Button("Continue") { if let id = pendingID { commitApply(id) } }
            Button("Cancel", role: .cancel) { pendingID = nil }
        } message: {
            Text("macOS is using an Apple dynamic or aerial wallpaper. HapticGlow will replace the desktop picture with a still of your live wallpaper so the lock screen matches. When you turn the engine off, pick your Apple wallpaper again in System Settings, Wallpaper.")
        }
    }

    // MARK: Cards

    private var masterCard: some View {
        Card {
            ToggleRow(title: "Show live wallpaper",
                      subtitle: model.wallpaper.enabled ? (engine.pauseSummary ?? statusLine) : "Off. Your own desktop picture is in use.",
                      isOn: Binding(get: { model.wallpaper.enabled },
                                    set: { on in on ? enable() : (model.wallpaper.enabled = false) }))
            if !model.wallpaper.enabled, !SnapshotMode.active, engine.currentPictureKind() == .appleDynamic {
                note("symbol", "Your current wallpaper is an Apple dynamic or aerial one. It cannot be put back by file, so you will need to pick it again in System Settings after turning this off.")
            } else if model.wallpaper.syncLockScreen {
                note("info", "Your desktop picture is saved before the first change and put back when you turn this off or quit.")
            }
            if let e = engine.lastError { Text(e).font(Theme.Font.caption).foregroundStyle(Theme.err) }
        }
    }

    private func note(_ kind: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: kind == "info" ? "info.circle" : "exclamationmark.triangle").font(.system(size: 11))
                .foregroundStyle(kind == "info" ? Theme.textTertiary : Theme.warn)
            Text(text).font(Theme.Font.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var statusLine: String {
        engine.displayCount == 0 ? "Choose a wallpaper below." : "Playing on \(engine.displayCount) display\(engine.displayCount == 1 ? "" : "s")."
    }

    private var libraryCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                SectionHeader("Library")
                Spacer()
                Button { openPanel() } label: { Label("Import…", systemImage: "plus") }.controlSize(.small)
            }
            linkRow.padding(.bottom, Theme.Space.xs)
            if library.items.isEmpty {
                Card {
                    Text("No wallpapers yet. Drop an image, GIF, WebP or video here, or add one from a link.")
                        .font(Theme.Font.body).foregroundStyle(Theme.textSecondary)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: Theme.Space.m, alignment: .top)],
                          alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(library.items) { item in tile(item) }
                }
            }
        }
        .padding(dropTargeted ? 6 : 0)
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1, dash: [5]))
            .opacity(dropTargeted ? 1 : 0))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in handleDrop(providers) }
    }

    private var linkRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Space.s) {
                TextField("Add from link", text: $linkText, prompt: Text("Paste a wallpaper page or direct media link"))
                    .textFieldStyle(.roundedBorder).controlSize(.small)
                    .onSubmit { addFromLink() }
                    .disabled(importing)
                Button("Add") { addFromLink() }.controlSize(.small)
                    .disabled(importing || URL(string: linkText.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") != true)
            }
            if importing { ProgressView(value: progress).controlSize(.small) }
            if let message {
                Text(message).font(Theme.Font.caption).foregroundStyle(messageIsError ? Theme.err : Theme.textSecondary)
            }
        }
    }

    private func tile(_ item: WallpaperInfo) -> some View {
        let isApplied = model.wallpaper.itemID == item.id && model.wallpaper.enabled
        let isSel = selectedItem?.id == item.id
        return VStack(alignment: .leading, spacing: 6) {
            ThumbView(url: library.thumbURL(item.id))
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .overlay(alignment: .topTrailing) {
                    if item.kind != .image {
                        Image(systemName: item.kind == .video ? "play.rectangle.fill" : "livephoto")
                            .font(.system(size: 10)).padding(4).foregroundStyle(.white)
                            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4)).padding(4)
                    }
                }
            HStack(spacing: 4) {
                Text(item.title).font(Theme.Font.label).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
                if model.wallpaper.playlistIDs.contains(item.id) { Image(systemName: "repeat").font(.system(size: 9)).foregroundStyle(Theme.textTertiary) }
                if isApplied { Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.accent) }
            }
            Text(item.artist ?? item.site).font(Theme.Font.caption).foregroundStyle(Theme.textTertiary).lineLimit(1)
        }
        .padding(Theme.Space.s)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(isSel ? Theme.accent : Theme.hairline, lineWidth: isSel ? 1.5 : 0.5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { apply(item.id) }
        .onTapGesture { selected = item.id }
        .contextMenu {
            Button("Apply") { apply(item.id) }
            Button(model.wallpaper.playlistIDs.contains(item.id) ? "Remove from Playlist" : "Add to Playlist") { togglePlaylist(item.id) }
            Button(item.isPixelArt ? "Not Pixel Art" : "Mark as Pixel Art") { library.setPixelArt(item.id, !item.isPixelArt) }
            Divider()
            Button("Reveal in Finder") { reveal(item) }
            Button("Delete", role: .destructive) { delete(item) }
        }
    }

    private func detailCard(_ item: WallpaperInfo) -> some View {
        Card {
            HStack(alignment: .top, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text([item.artist.map { "by \($0)" }, item.site, item.sizeText, kindText(item.kind)].compactMap { $0 }.joined(separator: " · "))
                        .font(Theme.Font.caption).foregroundStyle(Theme.textSecondary)
                    if let src = item.sourceURL { Link("Source page", destination: src).font(Theme.Font.caption) }
                }
                Spacer()
                HStack(spacing: Theme.Space.s) {
                    Button("Apply") { apply(item.id) }.controlSize(.small).buttonStyle(.borderedProminent)
                    Button("Reveal in Finder") { reveal(item) }.controlSize(.small)
                    Button("Delete", role: .destructive) { delete(item) }.controlSize(.small)
                }
            }
            Divider().opacity(0.4)
            HStack {
                Text("Fit").font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                Spacer()
                Picker("Fit", selection: Binding(get: { model.wallpaper.fitOverrides[item.id] ?? item.defaultFit },
                                                 set: { model.wallpaper.fitOverrides[item.id] = $0 })) {
                    ForEach(WallpaperFit.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
            }
            if (model.wallpaper.fitOverrides[item.id] ?? item.defaultFit) == .pixelArt {
                Text("Pixel art scales by whole numbers with sharp edges and fills the borders with the image's edge colour.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
            if item.kind != .image && model.wallpaper.enabled && model.wallpaper.itemID == item.id {
                Button("Use Current Frame for the Lock Screen") { Task { await engine.useCurrentFrameAsStill() } }
                    .controlSize(.small).disabled(!model.wallpaper.syncLockScreen)
            }
        }
    }

    private var playbackCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Playback and battery")
            Card {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Animated image frame rate").font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                        Text("A lower cap saves power. Video plays at its own rate.").font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Picker("Frame rate", selection: cfg.frameRateCap) {
                        Text("15 fps").tag(15); Text("30 fps").tag(30); Text("60 fps").tag(60)
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 190).controlSize(.small)
                }
                ToggleRow(title: "Pause when covered", subtitle: "A full-screen app or windows covering the whole desktop stop playback, not just hide it.",
                          isOn: cfg.pauseWhenCovered)
                ToggleRow(title: "Pause in battery saver", subtitle: "On battery or in Low Power Mode, show a still frame.", isOn: cfg.pauseOnSaver)
                ToggleRow(title: "Match the lock screen and Spaces", subtitle: "Sets a still of the wallpaper as the system desktop picture.",
                          isOn: cfg.syncLockScreen)
                Text("Playback also pauses while the display sleeps, the screen is locked, or another user is signed in.")
                    .font(Theme.Font.caption).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private var displaysCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Displays")
            Card {
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                    if let key = DisplayKey.of(screen) {
                        HStack {
                            Text(screen.localizedName).font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Picker(screen.localizedName, selection: Binding(
                                get: { model.wallpaper.perDisplay[key] ?? "" },
                                set: { model.wallpaper.perDisplay[key] = $0.isEmpty ? nil : $0 })) {
                                Text("Same as default").tag("")
                                ForEach(library.items) { Text($0.title).tag($0.id) }
                            }.labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                        }
                    }
                }
            }
        }
    }

    private var playlistCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader("Playlist")
            Card {
                ToggleRow(title: "Rotate through selected wallpapers",
                          subtitle: "\(model.wallpaper.playlistIDs.count) in rotation. Right-click a wallpaper to add or remove it.",
                          isOn: cfg.playlistEnabled)
                HStack {
                    Text("Change every").font(Theme.Font.label).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Picker("Interval", selection: cfg.playlistMinutes) {
                        ForEach([1, 5, 10, 15, 30, 60, 180], id: \.self) { Text($0 < 60 ? "\($0) min" : "\($0 / 60) h").tag($0) }
                    }.labelsHidden().pickerStyle(.menu).controlSize(.small).fixedSize()
                    Button("Use All") { model.wallpaper.playlistIDs = library.items.map(\.id) }.controlSize(.small).disabled(library.items.count < 2)
                }
            }
        }
    }

    // MARK: Actions

    private func kindText(_ k: WallpaperMediaKind) -> String {
        switch k { case .image: return "Image"; case .animatedImage: return "Animated image"; case .video: return "Video" }
    }

    private func enable() {
        if model.wallpaper.itemID == nil || library.item(model.wallpaper.itemID) == nil { model.wallpaper.itemID = library.items.first?.id }
        guard let id = model.wallpaper.itemID else { show("Add a wallpaper first.", error: true); return }
        apply(id)
    }

    private func apply(_ id: String) {
        selected = id
        if model.wallpaper.syncLockScreen, engine.currentPictureKind() == .appleDynamic {
            pendingID = id; confirmDynamic = true
        } else { commitApply(id) }
    }

    private func commitApply(_ id: String) {
        pendingID = nil
        model.wallpaper.itemID = id
        model.wallpaper.enabled = true
        if model.wallpaper.playlistIDs.isEmpty { model.wallpaper.playlistIDs = [id] }
    }

    private func togglePlaylist(_ id: String) {
        if let i = model.wallpaper.playlistIDs.firstIndex(of: id) { model.wallpaper.playlistIDs.remove(at: i) }
        else { model.wallpaper.playlistIDs.append(id) }
    }

    private func delete(_ item: WallpaperInfo) {
        if model.wallpaper.itemID == item.id {
            model.wallpaper.itemID = nil
            model.wallpaper.enabled = false
        }
        model.wallpaper.playlistIDs.removeAll { $0 == item.id }
        model.wallpaper.perDisplay = model.wallpaper.perDisplay.filter { $0.value != item.id }
        model.wallpaper.fitOverrides[item.id] = nil
        library.delete(item.id)
        if selected == item.id { selected = nil }
    }

    private func reveal(_ item: WallpaperInfo) { NSWorkspace.shared.activateFileViewerSelecting([library.mediaURL(item)]) }

    private func show(_ text: String?, error: Bool = false) { message = text; messageIsError = error }

    private func openPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = [.image, .movie, .mpeg4Movie, .quickTimeMovie, .gif]
        p.message = "Choose images, animated images or videos to add to the library."
        guard p.runModal() == .OK else { return }
        importFiles(p.urls)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var found = false
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            found = true
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in importFiles([url]) } }
            }
        }
        return found
    }

    private func importFiles(_ urls: [URL]) {
        Task { @MainActor in
            for u in urls {
                do {
                    let info = try await library.importLocal(u)
                    selected = info.id
                    show("Added \(info.title).")
                } catch {
                    show("\(u.lastPathComponent): \(error.localizedDescription)", error: true)
                }
            }
        }
    }

    private func addFromLink() {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !importing, let url = URL(string: text), url.scheme?.hasPrefix("http") == true else { return }
        importing = true; progress = 0; show(nil)
        Task { @MainActor in
            defer { importing = false }
            do {
                let imported = try await WallpaperImporter.importMedia(from: url) { p in Task { @MainActor in progress = p } }
                let info = try await library.add(imported: imported)
                selected = info.id
                linkText = ""
                show("Added \(info.title).")
            } catch let e as WallpaperImportError {
                show(Self.text(e), error: true)
            } catch {
                show(error.localizedDescription, error: true)
            }
        }
    }

    static func text(_ e: WallpaperImportError) -> String {
        switch e {
        case .unsupportedSite: return "This site is not supported yet. Try a direct link to an image, GIF or video."
        case .notFound: return "Nothing was found at that link."
        case .needsLogin: return "That page needs you to sign in, so it cannot be imported."
        case .network(let m): return "Network problem: \(m)"
        case .invalidMedia: return "The file at that link is not a usable image or video."
        }
    }
}

/// Thumbnail (a small JPEG, so a synchronous load is cheap), cached by path.
private struct ThumbView: View {
    let url: URL
    private static let cache = NSCache<NSURL, NSImage>()
    private var image: NSImage? {
        if let c = Self.cache.object(forKey: url as NSURL) { return c }
        guard let i = NSImage(contentsOf: url) else { return nil }
        Self.cache.setObject(i, forKey: url as NSURL)
        return i
    }
    var body: some View {
        ZStack {
            Theme.track
            if let image { Image(nsImage: image).resizable().scaledToFill() }
        }
        .clipped()
    }
}
