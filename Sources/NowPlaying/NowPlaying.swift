// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Now playing controller. While a song plays it layers that song's tuning (saved by the user, else the
// genre preset) over the live haptic and glow settings, and puts the user's normal values back when the
// song ends or changes. A saved song wins over a genre preset, knob by knob.
//
// How the layering stays safe:
//  - `session` holds the user's normal values (`base`) for as long as a song plays. Saving settings to
//    disk goes through `persisted`, so an applied layer is never written as the user's normal setting.
//  - A change the user makes while the song plays is theirs: it stays after the song, it is not undone,
//    and the knob counts as "touched" so "Remember for this song" can save it.
import Foundation
import Observation

@MainActor
@Observable
final class NowPlaying {
    static let shared = NowPlaying()

    /// The song that is playing now. Nil while paused, stopped or when no player is running.
    private(set) var track: NowPlayingTrack?
    /// What is currently layered over the user's settings, for the UI.
    private(set) var appliedNote: String?
    /// The playing song has saved tuning.
    private(set) var isRemembered = false
    /// Knobs the user changed since this song began. Non-empty means "Remember for this song" has something to save.
    private(set) var touched: Set<TuneKnob> = []

    var canRemember: Bool { track != nil && !touched.isEmpty }

    /// Apply genre presets. Saved songs apply regardless.
    var genrePresets: Bool {
        didSet { if genrePresets != oldValue { UserDefaults.standard.set(genrePresets, forKey: Self.genreKey); refresh() } }
    }

    private static let genreKey = "nowPlaying.genrePresets"
    private static let memoryKey = "songTunings.v1"

    private struct Session {
        var key: String
        var baseH: HapticConfig        // the user's normal settings (edits made during the song included)
        var baseG: GlowConfig
        var genre: SongTuning          // genre layer as applied
        var song: SongTuning           // saved layer as applied
        var original: [TuneKnob: TuneValue] = [:]   // normal value of a knob before the user first touched it
        var layer: SongTuning { genre.merged(with: song) }
    }

    private var session: Session?
    private var memory: SongMemory
    private var applying = false
    private let monitor = NowPlayingMonitor()

    private init() {
        genrePresets = UserDefaults.standard.object(forKey: Self.genreKey) as? Bool ?? true
        memory = SongMemory.decode(UserDefaults.standard.data(forKey: Self.memoryKey))
    }

    func start() {
        monitor.onChange = { [weak self] t in self?.setTrack(t) }
        monitor.start()
    }

    func stop() {
        monitor.stop()
        monitor.onChange = nil
        setTrack(nil)
    }

    // MARK: Track changes

    private func setTrack(_ t: NowPlayingTrack?) {
        // The same song again (a metadata refresh) keeps its session as it is.
        let keep = t != nil && t?.key == track?.key && session != nil
        if t != track { track = t }
        if !keep { refresh() }
    }

    /// Ends the current session and, when a song plays, starts a fresh one.
    private func refresh() {
        endSession()
        guard let t = track else { return }
        beginSession(t)
    }

    private func beginSession(_ t: NowPlayingTrack) {
        let app = AppModel.shared
        let key = t.key
        let song = memory.tuning(for: key) ?? SongTuning()
        if !song.isEmpty { memory.touch(key, now: Date().timeIntervalSince1970); saveMemory() }
        let preset = genrePresets ? GenrePresets.match(t.genre) : nil
        var genre = preset?.tuning ?? SongTuning()
        // A genre preset never turns a typing or ambient glow mode into a music one.
        if !GlowConfig.isMusicMode(app.glow.mode) { genre[.glowMode] = nil }
        let s = Session(key: key, baseH: app.haptic, baseG: app.glow, genre: genre, song: song)
        session = s
        isRemembered = !song.isEmpty
        touched = []
        applyLayer(s.layer, skipping: [])
        AudioSourceMonitor.shared.setSpokenWordHint(preset?.speech == true)
        if !song.isEmpty { appliedNote = "Your saved tuning is on" }
        else if let p = preset, !genre.isEmpty { appliedNote = "\(p.name) tuning for \(t.genre)" }
        else { appliedNote = nil }
    }

    private func endSession() {
        guard let s = session else { return }
        // Restore every layered knob the user did not touch. Touched knobs stay as the user left them.
        restore(Set(s.layer.knobs).subtracting(touched), from: s)
        session = nil
        touched = []
        isRemembered = false
        appliedNote = nil
        AudioSourceMonitor.shared.setSpokenWordHint(false)
    }

    private func applyLayer(_ layer: SongTuning, skipping: Set<TuneKnob>) {
        let app = AppModel.shared
        var h = app.haptic, g = app.glow
        for k in layer.knobs where !skipping.contains(k) { if let v = layer[k] { k.write(v, &h, &g) } }
        push(h, g)
    }

    private func restore(_ knobs: Set<TuneKnob>, from s: Session) {
        guard !knobs.isEmpty else { return }
        let app = AppModel.shared
        var h = app.haptic, g = app.glow
        for k in knobs { k.write(k.read(s.baseH, s.baseG), &h, &g) }
        push(h, g)
    }

    private func push(_ h: HapticConfig, _ g: GlowConfig) {
        let app = AppModel.shared
        applying = true
        if app.haptic != h { app.haptic = h }
        if app.glow != g { app.glow = g }
        applying = false
    }

    // MARK: Edits and persistence (called from AppModel)

    func hapticEdited(from old: HapticConfig) { edited { k in !k.isGlow ? k.read(old, AppModel.shared.glow) : nil } }
    func glowEdited(from old: GlowConfig) { edited { k in k.isGlow ? k.read(AppModel.shared.haptic, old) : nil } }

    private func edited(previous: (TuneKnob) -> TuneValue?) {
        guard !applying, var s = session else { return }
        let app = AppModel.shared
        for k in TuneKnob.allCases {
            guard let was = previous(k), was != k.read(app.haptic, app.glow) else { continue }
            if !touched.contains(k) { s.original[k] = k.read(s.baseH, s.baseG) }
            // The user's new value is their new normal, so it is not undone at the end of the song.
            k.write(k.read(app.haptic, app.glow), &s.baseH, &s.baseG)
            touched.insert(k)
        }
        session = s
    }

    /// The settings to write to disk: the user's normal values, never an applied layer.
    func persisted(haptic h: HapticConfig, glow g: GlowConfig) -> (HapticConfig, GlowConfig) {
        guard let s = session else { return (h, g) }
        var h = h, g = g
        for k in Set(s.layer.knobs).subtracting(touched) { k.write(k.read(s.baseH, s.baseG), &h, &g) }
        return (h, g)
    }

    // MARK: User actions

    /// Saves the knobs changed during this song and keeps them for the next time it plays.
    func remember() {
        guard let t = track, var s = session, !touched.isEmpty else { return }
        let app = AppModel.shared
        var song = s.song
        for k in touched { song[k] = k.read(app.haptic, app.glow) }
        memory.set(key: t.key, title: t.title, artist: t.artist, tuning: song, now: Date().timeIntervalSince1970)
        saveMemory()
        // The saved values become the layer; the user's normal settings go back to what they were before the edits.
        for k in touched { if let o = s.original[k] { k.write(o, &s.baseH, &s.baseG) } }
        s.song = song
        s.original = [:]
        session = s
        touched = []
        isRemembered = true
        appliedNote = "Your saved tuning is on"
    }

    /// Forgets the playing song's saved tuning and goes back to the genre preset, if any.
    func forget() {
        guard let t = track else { return }
        memory.remove(t.key)
        saveMemory()
        refresh()
    }

    var savedSongCount: Int { memory.entries.count }

    func forgetAll() {
        memory = SongMemory()
        saveMemory()
        refresh()
    }

    private func saveMemory() {
        if let d = memory.encoded() { UserDefaults.standard.set(d, forKey: Self.memoryKey) }
    }

    // MARK: Snapshot mode

    /// Screenshot mode only: shows a made-up song so the Dashboard and menu bar rows can be captured.
    func showSampleForSnapshot() {
        guard SnapshotMode.active else { return }
        var t = NowPlayingTrack(player: .music, title: "Sample Song", artist: "Sample Artist")
        t.album = "Sample Album"
        t.genre = "Hip-Hop/Rap"
        t.id = "0000000000000001"
        setTrack(t)
    }
}
