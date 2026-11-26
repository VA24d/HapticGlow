// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// HapticGlow - Auto haptic source: decides Music or Movie from what is actually playing.
//
// Pipeline (all event driven, nothing runs while haptics or Auto are off):
//   1. Core Audio process objects tell which processes are producing output (property listeners, no polling).
//   2. Rules map a bundle id to Music / Movie / unknown. Browsers are resolved by the audible tab's URL, read
//      through Apple Events (asked once, silently skipped when denied).
//   3. Sources the rules cannot place fall back to a cheap speech-vs-music heuristic over the analyser's
//      features, sampled in one 1 s window every 3 s (5 s on battery) and only while such a source plays.
//   4. A hysteresis stage switches only after consistent evidence, so the mode does not flap.
// The pure parts (SourceRules, AutoSourceResolver, ModeHysteresis, SpeechMusicAccumulator) have no system
// dependencies beyond AudioFeatures, so they can be probed with synthetic input.
import Foundation
import AppKit
import CoreAudio
import ApplicationServices
import Darwin

// MARK: - Pure rules

enum SourceKind: String, Sendable { case music, movie, unknown, ignore }

enum BrowserFamily: Sendable { case safari, chromium, firefox }

struct BrowserInfo: Sendable, Equatable {
    let id: String          // canonical bundle id, used as the Apple Events target
    let name: String
    let family: BrowserFamily
}

struct BundleClass: Sendable, Equatable {
    var kind: SourceKind
    var name: String?
    var browser: BrowserInfo?
}

enum SourceRules {
    // Helper processes use ids like "com.google.Chrome.helper.Renderer", so match on a dotted prefix.
    // Longest ids first so "com.google.Chrome.canary" wins over "com.google.Chrome".
    static let browsers: [BrowserInfo] = [
        .init(id: "com.apple.SafariTechnologyPreview", name: "Safari Technology Preview", family: .safari),
        .init(id: "com.apple.Safari", name: "Safari", family: .safari),
        .init(id: "com.apple.WebKit", name: "Safari", family: .safari),
        .init(id: "com.kagi.kagimacOS", name: "Orion", family: .safari),
        .init(id: "com.google.Chrome.canary", name: "Chrome Canary", family: .chromium),
        .init(id: "com.google.Chrome.beta", name: "Chrome Beta", family: .chromium),
        .init(id: "com.google.Chrome", name: "Chrome", family: .chromium),
        .init(id: "company.thebrowser.Browser", name: "Arc", family: .chromium),
        .init(id: "com.brave.Browser.beta", name: "Brave Beta", family: .chromium),
        .init(id: "com.brave.Browser.nightly", name: "Brave Nightly", family: .chromium),
        .init(id: "com.brave.Browser", name: "Brave", family: .chromium),
        .init(id: "com.microsoft.edgemac", name: "Edge", family: .chromium),
        .init(id: "com.vivaldi.Vivaldi", name: "Vivaldi", family: .chromium),
        .init(id: "com.operasoftware.Opera", name: "Opera", family: .chromium),
        .init(id: "org.chromium.Chromium", name: "Chromium", family: .chromium),
        .init(id: "org.mozilla.firefox", name: "Firefox", family: .firefox),
        .init(id: "org.mozilla", name: "Firefox", family: .firefox),
        .init(id: "app.zen-browser.zen", name: "Zen", family: .firefox),
    ]

    static func browser(forBundle id: String) -> BrowserInfo? {
        let low = id.lowercased()
        var best: BrowserInfo?
        for b in browsers {
            let p = b.id.lowercased()
            if low == p || low.hasPrefix(p + ".") { if best == nil || b.id.count > best!.id.count { best = b } }
        }
        return best
    }

    /// Never a haptic source: system sounds, voice assistants, accessibility speech.
    static let ignorePrefixes = [
        "com.apple.audio", "com.apple.coreaudio", "com.apple.siri", "com.apple.assistant", "com.apple.voiceover",
        "com.apple.speech", "com.apple.systemsound", "com.apple.usernotificationcenter", "com.apple.notificationcenter",
        "com.apple.accessibility", "com.apple.universalaccess", "com.apple.controlcenter", "com.apple.coreservices",
        "com.apple.hearing", "com.apple.avconference", "com.apple.mediaremoted", "com.apple.dock", "com.apple.finder",
    ]

    static let musicApps: [String: String] = [
        "com.apple.music": "Music", "com.apple.itunes": "iTunes", "com.spotify.client": "Spotify",
        "com.tidal.desktop": "Tidal", "com.deezer.deezer-desktop": "Deezer", "com.coppertino.vox": "Vox",
        "com.brushedtype.doppler": "Doppler", "com.audirvana.audirvana": "Audirvana", "com.audirvana.audirvana-plus": "Audirvana",
        "com.swinsian.swinsian": "Swinsian", "com.amazon.music": "Amazon Music", "com.plexapp.plexamp": "Plexamp",
        "com.roon.roon": "Roon", "org.strawberrymusicplayer.strawberry": "Strawberry", "com.github.th-ch.youtube-music": "YouTube Music",
        "app.ytmdesktop.ytmdesktop": "YouTube Music", "com.apple.logic10": "Logic Pro", "com.apple.garageband10": "GarageBand",
        "com.ableton.live": "Live", "com.qobuz.qobuz": "Qobuz", "com.pandora.pandora": "Pandora", "com.soundcloud.desktop": "SoundCloud",
        "com.vox.vox": "Vox", "com.sonos.maccontroller2": "Sonos", "com.cidercollective.cider": "Cider", "sh.cider.genten": "Cider",
    ]

    static let movieApps: [String: String] = [
        "com.colliderli.iina": "IINA", "org.videolan.vlc": "VLC", "com.apple.quicktimeplayerx": "QuickTime Player",
        "com.apple.tv": "TV", "com.firecore.infuse": "Infuse", "io.mpv": "mpv", "org.mpv": "mpv",
        "com.plexapp.plexmediaplayer": "Plex", "com.plexapp.plex": "Plex", "org.xbmc.kodi": "Kodi", "com.movist.movist": "Movist",
        "com.movist.movistpro": "Movist", "com.eltima.elmediaplayer": "Elmedia Player",
        "com.netflix.netflix": "Netflix", "com.amazon.aiv.primevideo": "Prime Video", "com.amazon.aiv.aivapp": "Prime Video",
        "com.amazon.primevideo": "Prime Video", "com.disney.disneyplus": "Disney+", "tv.twitch.desktop": "Twitch",
        "tv.twitch.studio": "Twitch", "com.apple.podcasts": "Podcasts", "com.overcast.overcast": "Overcast",
        "us.zoom.xos": "Zoom", "com.microsoft.teams2": "Teams", "com.microsoft.teams": "Teams", "com.apple.facetime": "FaceTime",
        "com.hnc.discord": "Discord", "com.tinyspeck.slackmacgap": "Slack", "com.stremio.stremio": "Stremio",
        "com.apple.photobooth": "Photo Booth", "com.apple.quicktimeplayer": "QuickTime Player",
    ]

    static let musicKeywords = ["spotify", "tidal", "deezer", "doppler", "audirvana", "swinsian", "plexamp", "qobuz", "pandora", "soundcloud", "bandcamp", "amazon.music", "youtube-music", "ytmdesktop"]
    static let movieKeywords = ["netflix", "primevideo", "disneyplus", "hulu", "iina", "videolan", "infuse", "twitch"]

    private static func lookupApp(_ low: String, in map: [String: String]) -> String? {
        if let n = map[low] { return n }
        for (k, v) in map where low.hasPrefix(k + ".") { return v }
        return nil
    }

    static func classifyBundle(_ id: String) -> BundleClass {
        let low = id.lowercased()
        if low.isEmpty { return .init(kind: .unknown, name: nil, browser: nil) }
        if ignorePrefixes.contains(where: { low.hasPrefix($0) }) { return .init(kind: .ignore, name: nil, browser: nil) }
        if let b = browser(forBundle: id) { return .init(kind: .unknown, name: b.name, browser: b) }
        if let n = lookupApp(low, in: musicApps) { return .init(kind: .music, name: n, browser: nil) }
        if let n = lookupApp(low, in: movieApps) { return .init(kind: .movie, name: n, browser: nil) }
        if musicKeywords.contains(where: { low.contains($0) }) { return .init(kind: .music, name: nil, browser: nil) }
        if movieKeywords.contains(where: { low.contains($0) }) { return .init(kind: .movie, name: nil, browser: nil) }
        return .init(kind: .unknown, name: nil, browser: nil)
    }

    // MARK: URLs

    private static let musicHosts: [(String, String)] = [
        ("music.youtube.com", "YouTube Music"), ("open.spotify.com", "Spotify"), ("soundcloud.com", "SoundCloud"),
        ("music.apple.com", "Apple Music"), ("bandcamp.com", "Bandcamp"), ("tidal.com", "Tidal"), ("deezer.com", "Deezer"),
        ("pandora.com", "Pandora"), ("mixcloud.com", "Mixcloud"), ("audiomack.com", "Audiomack"), ("qobuz.com", "Qobuz"),
        ("music.amazon.com", "Amazon Music"), ("last.fm", "Last.fm"), ("radio.garden", "Radio Garden"),
    ]
    private static let movieHosts: [(String, String)] = [
        ("youtube.com", "YouTube"), ("youtu.be", "YouTube"), ("netflix.com", "Netflix"), ("primevideo.com", "Prime Video"),
        ("twitch.tv", "Twitch"), ("vimeo.com", "Vimeo"), ("disneyplus.com", "Disney+"), ("hulu.com", "Hulu"),
        ("max.com", "Max"), ("hbomax.com", "Max"), ("tv.apple.com", "Apple TV"), ("peacocktv.com", "Peacock"),
        ("paramountplus.com", "Paramount+"), ("crunchyroll.com", "Crunchyroll"), ("dailymotion.com", "Dailymotion"),
        ("tiktok.com", "TikTok"), ("plex.tv", "Plex"), ("kick.com", "Kick"),
    ]

    private static func hostMatches(_ host: String, _ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

    /// Classify a tab URL. nil = no rule (let the classifier decide).
    static func classifyURL(_ raw: String) -> (kind: SourceKind, site: String)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URLComponents(string: s), var host = u.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let path = u.path.lowercased()
        // Podcasts on Spotify are speech.
        if host == "open.spotify.com", path.hasPrefix("/episode") || path.hasPrefix("/show") { return (.movie, "Spotify podcast") }
        if hostMatches(host, "amazon.com") || hostMatches(host, "amazon.co.uk") || hostMatches(host, "amazon.de") || hostMatches(host, "amazon.ca") || hostMatches(host, "amazon.co.jp") || hostMatches(host, "amazon.in") {
            if path.hasPrefix("/music") { return (.music, "Amazon Music") }
            if path.hasPrefix("/gp/video") || path.hasPrefix("/video") { return (.movie, "Prime Video") }
            return nil
        }
        for (d, n) in musicHosts where hostMatches(host, d) { return (.music, n) }
        for (d, n) in movieHosts where hostMatches(host, d) { return (.movie, n) }
        return nil
    }
}

// MARK: - Resolver

struct SourceInfo: Sendable, Equatable {
    var pid: Int32
    var appID: String          // canonical app (browser id for helpers), compared with the frontmost app
    var label: String          // "YouTube in Safari", "Spotify"
    var kind: SourceKind
    var firstSeen: Double
}

enum AutoBasis: String, Sendable { case idle, rule, classifier }

struct Resolution: Sendable, Equatable {
    var label: String
    var mode: HapticMode?      // nil = no rule applies (classifier decides) or nothing playing
    var basis: AutoBasis
}

enum AutoSourceResolver {
    /// Picks the verdict among the playing sources. Known sources (music/movie) beat unknown ones; among
    /// known ones the frontmost app wins, then the one that started first.
    static func resolve(_ sources: [SourceInfo], frontmost: String?) -> Resolution {
        let live = sources.filter { $0.kind != .ignore }
        if live.isEmpty { return .init(label: "", mode: nil, basis: .idle) }
        let known = live.filter { $0.kind == .music || $0.kind == .movie }
        if !known.isEmpty {
            let pick = known.first(where: { $0.appID == frontmost })
                ?? known.min(by: { ($0.firstSeen, $0.pid) < ($1.firstSeen, $1.pid) })!
            return .init(label: pick.label, mode: pick.kind == .movie ? .movie : .music, basis: .rule)
        }
        let first = live.min(by: { ($0.firstSeen, $0.pid) < ($1.firstSeen, $1.pid) })!
        return .init(label: first.label, mode: nil, basis: .classifier)
    }
}

// MARK: - Hysteresis

/// Switches the effective mode only after the same candidate has been seen for `hold` seconds.
struct ModeHysteresis: Sendable {
    private(set) var current: HapticMode = .music
    private var pending: HapticMode?
    private var pendingSince = 0.0

    /// Feed a candidate (nil = no evidence, leaves a pending switch alone). `evidenceStart` is when the evidence
    /// began (a classifier window start). Returns true when `current` changed.
    mutating func update(candidate: HapticMode?, evidenceStart: Double, now: Double, hold: Double) -> Bool {
        guard let cand = candidate else { return false }
        if cand == current { pending = nil; return false }
        if pending != cand { pending = cand; pendingSince = evidenceStart }
        if now - pendingSince >= hold { current = cand; pending = nil; return true }
        return false
    }
    /// Seconds until the pending candidate matures (nil when nothing is pending).
    func remaining(now: Double, hold: Double) -> Double? {
        pending == nil ? nil : max(0, hold - (now - pendingSince))
    }
    mutating func clearPending() { pending = nil }
    mutating func force(_ m: HapticMode) { current = m; pending = nil }
}

// MARK: - Speech / music heuristic

enum SpeechVerdict: String, Sendable { case speech, music, unsure }

/// Cheap speech-vs-music estimate over one window of analyser features. Speech: energy in 160 Hz-2 kHz,
/// almost no bass, rare low onsets, strong syllable-rate level modulation, no tempo lock. Music: bass
/// weight, regular onsets, a tempo, steadier level.
struct SpeechMusicAccumulator: Sendable {
    private(set) var frames = 0
    private var silent = 0
    private var low: Float = 0, voice: Float = 0, high: Float = 0
    private var bpmFrames = 0
    private var firstOnset: UInt64 = 0, lastOnset: UInt64 = 0, haveOnset = false
    private var bucketStart = -1.0, bucketSum: Float = 0, bucketN = 0
    /// Fixed storage (64 buckets) so add() never allocates on the audio thread.
    private var levelBuf = [Float](repeating: 0, count: 64)
    private var levelN = 0

    @inline(__always) private static func lin(_ x: Float) -> Float { powf(10, 2.4 * (max(0, min(1, x)) - 1)) }

    mutating func add(_ f: AudioFeatures) {
        frames += 1
        // Always record level buckets once audio has started so word/sentence pauses show up in modulation.
        let activeFrame = !f.silent && f.level >= 0.02
        if bucketStart < 0 && activeFrame { bucketStart = f.time }
        if bucketStart >= 0 {
            bucketSum += f.silent ? 0 : f.level
            bucketN += 1
            if f.time - bucketStart >= 0.05 {
                if levelN < 64 { levelBuf[levelN] = bucketSum / Float(max(1, bucketN)); levelN += 1 }
                bucketStart = f.time; bucketSum = 0; bucketN = 0
            }
        }
        guard activeFrame else { silent += 1; return }
        low += Self.lin(f.sub) + Self.lin(f.bass)
        voice += Self.lin(f.lowMid) + Self.lin(f.mid)
        high += Self.lin(f.high)
        if f.bpm > 0 { bpmFrames += 1 }
        if !haveOnset { firstOnset = f.onset ? (f.onsetCount &- 1) : f.onsetCount; haveOnset = true }
        lastOnset = f.onsetCount
    }

    func verdict(windowSeconds: Double) -> SpeechVerdict {
        let active = frames - silent
        guard frames > 8, active >= 8, Double(active) >= 0.4 * Double(frames), levelN >= 8 else { return .unsure }
        let total = low + voice + high + 1e-9
        let voiceShare = voice / total, lowShare = low / total
        let onsetRate = Double(lastOnset &- firstOnset) / max(0.25, windowSeconds)
        let hasTempo = Double(bpmFrames) > 0.5 * Double(active)
        var mod: Float = 0
        var sum = levelBuf[0]
        for i in 1..<levelN { mod += abs(levelBuf[i] - levelBuf[i - 1]); sum += levelBuf[i] }
        mod /= Float(levelN - 1)
        let meanLevel = sum / Float(levelN)
        let modulation = mod / (meanLevel + 0.05)

        var sp: Float = 0, mu: Float = 0
        if voiceShare > 0.55 { sp += 1 } else if voiceShare < 0.35 { mu += 0.5 }
        if lowShare < 0.22 { sp += 1 } else if lowShare > 0.40 { mu += 1.5 }
        if onsetRate < 1.0 { sp += 1 } else if onsetRate >= 2.0 { mu += 1.5 }
        if modulation > 0.22 { sp += 1 } else if modulation < 0.10 { mu += 1 }
        if hasTempo { mu += 1 } else { sp += 0.5 }
        if sp >= 3 && sp > mu + 1 { return .speech }
        if mu >= 2.5 && mu > sp { return .music }
        return .unsure
    }
}

// MARK: - Status for the UI

struct AutoSourceStatus: Equatable, Sendable {
    var active = false
    var playing = false
    var mode: HapticMode = .music
    var source = ""
    var basis: AutoBasis = .idle
    var note: String?

    var modeTitle: String { mode == .movie ? "Movie" : "Music" }
    var line: String {
        if !active { return "Auto is waiting for audio" }
        if !playing { return "Nothing playing" }
        switch basis {
        case .rule: return "\(source), \(modeTitle)"
        case .classifier: return "\(source) (by sound), \(modeTitle)"
        case .idle: return "Nothing playing"
        }
    }
}

// MARK: - Monitor

final class AudioSourceMonitor: @unchecked Sendable {
    static let shared = AudioSourceMonitor()

    /// Called on the monitor's queue whenever the status changes.
    var onStatus: (@Sendable (AutoSourceStatus) -> Void)? {
        get { cbLock.withLock { _onStatus } }
        set { cbLock.withLock { _onStatus = newValue } }
    }
    private let cbLock = UnfairLock()
    private var _onStatus: (@Sendable (AutoSourceStatus) -> Void)?
    // Frontmost app, cached from the main queue (NSWorkspace is main-thread API).
    private let fmLock = UnfairLock()
    private var cachedFrontmost: String?
    // Browser bundle id -> deadline of the tab query in flight (one hung browser must not block others).
    private var tabInFlight: [String: Double] = [:]

    // Optional hooks for offline unit probes (nil in production).
    var processProvider: (() -> [(pid: Int32, bundle: String)])?
    var tabQuerier: ((String, BrowserFamily) -> TabResult)?
    var frontmostProvider: (() -> String?)?
    var runningAppCheck: ((String) -> Bool)?
    var engineSink: ((HapticMode) -> Void)?
    var windowDuration: Double = 1.0
    var holdRule: Double = 1.0
    var holdClassifier: Double = 4.0

    // Probe counters (read anywhere, written on q).
    private let statLock = UnfairLock()
    private var _classifierWindows = 0
    private var _tabQueries = 0
    var classifierWindowCount: Int { statLock.withLock { _classifierWindows } }
    var tabQueryCount: Int { statLock.withLock { _tabQueries } }

    private let q = DispatchQueue(label: "HapticGlow.autosource", qos: .utility)
    private let scriptQ = DispatchQueue(label: "HapticGlow.autosource.script", qos: .utility)

    // State below is touched on q only.
    private struct Proc { var obj: AudioObjectID; var pid: Int32; var bundle: String }
    private var listening = false
    private var sysListener: AudioObjectPropertyListenerBlock?
    private var procListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var procs: [Proc] = []
    private var firstSeen: [Int32: Double] = [:]
    private var refreshWork: DispatchWorkItem?
    private var tabInfo: [String: (url: String, title: String, at: Double)] = [:]
    private var queriedBrowserSigs: [String: Set<Int32>] = [:]
    private var lastTabQueryAt: [String: Double] = [:]
    private var deniedBrowsers = Set<String>()
    private var recheckWork: DispatchWorkItem?
    private var hyst = ModeHysteresis()
    private var lastBasis: AutoBasis = .idle
    private var status = AutoSourceStatus()
    private var appObserver: NSObjectProtocol?
    private var powerObserver: NSObjectProtocol?

    // Classifier
    private var clsTimer: DispatchSourceTimer?
    private var clsSaver = false
    private var clsToken = 0
    private var clsGen: UInt64 = 0
    private let accLock = UnfairLock()
    private var acc = SpeechMusicAccumulator()
    private var clsVerdict: SpeechVerdict = .unsure
    private var clsWindowStart = 0.0
    private var clsMode: HapticMode?
    private var unsureStreak = 0
    private var silentSkips = 0

    private let selfPID = getpid()

    init() {}

    func setActive(_ on: Bool) { q.async { on ? self.begin() : self.end() } }

    var current: AutoSourceStatus { q.sync { status } }

    /// Synchronously refreshes source state on `q` (for offline probes using injected providers).
    func refreshNow() { q.sync { self.refreshProcesses() } }
    /// Synchronously simulates app activation on `q` (for offline probes).
    func handleAppActivation(bundleID: String?) { q.sync { self.onAppActivated(bundleID) } }
    /// Synchronously runs one classifier window evaluation over synthetic frames (for offline probes).
    func feedClassifierWindow(_ frames: [AudioFeatures], start: Double, end: Double) {
        q.sync {
            guard listening else { return }
            if frames.allSatisfy({ $0.silent }) {
                silentSkips += 1
                if silentSkips >= 2 { hyst.clearPending() }
                return
            }
            silentSkips = 0
            statLock.withLock { _classifierWindows += 1 }
            var a = SpeechMusicAccumulator()
            for f in frames { a.add(f) }
            clsWindowStart = start
            let v = a.verdict(windowSeconds: max(0.25, end - start))
            applyClassifierVerdict(v, at: end)
        }
    }

    // MARK: lifecycle

    private func begin() {
        guard !listening else { return }
        listening = true
        if processProvider == nil {
            var a = Self.addr(kAudioHardwarePropertyProcessObjectList)
            let blk: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRefresh() }
            sysListener = blk
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, q, blk)
            appObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                let bid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
                self?.fmLock.withLock { self?.cachedFrontmost = bid }
                self?.q.async { self?.onAppActivated(bid) }
            }
            DispatchQueue.main.async { [weak self] in
                let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                self?.fmLock.withLock { self?.cachedFrontmost = bid }
                self?.q.async { self?.reevaluate() }
            }
            powerObserver = NotificationCenter.default.addObserver(forName: PowerState.didChange, object: nil, queue: nil) { [weak self] _ in
                self?.q.async { self?.onPowerChanged() }
            }
        }
        status.active = true
        lastBasis = .idle
        refreshProcesses()
        publish()
    }

    private func end() {
        guard listening else { return }
        listening = false
        if let blk = sysListener {
            var a = Self.addr(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, q, blk)
        }
        sysListener = nil
        for (obj, blk) in procListeners {
            var a = Self.addr(kAudioProcessPropertyIsRunningOutput)
            AudioObjectRemovePropertyListenerBlock(obj, &a, q, blk)
        }
        procListeners.removeAll()
        if let o = appObserver { NSWorkspace.shared.notificationCenter.removeObserver(o); appObserver = nil }
        if let o = powerObserver { NotificationCenter.default.removeObserver(o); powerObserver = nil }
        refreshWork?.cancel(); recheckWork?.cancel()
        stopClassifier()
        deniedBrowsers.removeAll()
        tabInFlight = [:]
        procs = []; tabInfo = [:]; queriedBrowserSigs = [:]; lastTabQueryAt = [:]; firstSeen = [:]
        lastBasis = .idle; clsMode = nil; clsVerdict = .unsure; unsureStreak = 0; silentSkips = 0
        hyst.clearPending()
        status.active = false; status.playing = false; status.basis = .idle
        publish()
    }

    private func onPowerChanged() {
        guard listening, clsTimer != nil else { return }
        let saver = PowerState.shared.saver
        if saver != clsSaver {
            stopClassifier()
            startClassifier()
        }
    }

    private func onAppActivated(_ bundleID: String?) {
        guard listening else { return }
        if let bid = bundleID,
           let b = SourceRules.browser(forBundle: bid), b.family != .firefox {
            let sig = Set(procs.compactMap { p -> Int32? in
                guard let pb = SourceRules.classifyBundle(p.bundle).browser,
                      scriptTarget(for: pb, frontmost: bid) == b.id else { return nil }
                return p.pid
            })
            if !sig.isEmpty {
                let targetFamily = SourceRules.browser(forBundle: b.id)?.family ?? b.family
                deniedBrowsers.remove(b.id)   // permission may have changed; the query checks without prompting
                queryBrowserTargets([(b.id, targetFamily, sig)], force: true)
            }
        }
        if procs.count > 1 { reevaluate() }
    }

    // MARK: Core Audio

    private static func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func scheduleRefresh() {
        refreshWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.refreshProcesses() }
        refreshWork = w
        q.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    private func refreshProcesses() {
        guard listening else { return }
        var out: [Proc] = []
        if let provider = processProvider {
            let selfBid = Bundle.main.bundleIdentifier
            for p in provider() where p.pid != selfPID && p.bundle != selfBid {
                out.append(Proc(obj: 0, pid: p.pid, bundle: p.bundle))
            }
        } else {
            var a = Self.addr(kAudioHardwarePropertyProcessObjectList)
            var size: UInt32 = 0
            var objs: [AudioObjectID] = []
            if AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr, size > 0 {
                objs = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
                if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &objs) != noErr { objs = [] }
            }
            // Keep one IsRunningOutput listener per live process object.
            let live = Set(objs)
            for (obj, blk) in procListeners where !live.contains(obj) {
                var la = Self.addr(kAudioProcessPropertyIsRunningOutput)
                AudioObjectRemovePropertyListenerBlock(obj, &la, q, blk)
                procListeners[obj] = nil
            }
            for obj in objs where procListeners[obj] == nil {
                var la = Self.addr(kAudioProcessPropertyIsRunningOutput)
                let blk: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRefresh() }
                if AudioObjectAddPropertyListenerBlock(obj, &la, q, blk) == noErr { procListeners[obj] = blk }
            }
            for obj in objs {
                var ra = Self.addr(kAudioProcessPropertyIsRunningOutput)
                var running: UInt32 = 0
                var sz = UInt32(MemoryLayout<UInt32>.size)
                guard AudioObjectGetPropertyData(obj, &ra, 0, nil, &sz, &running) == noErr, running != 0 else { continue }
                var pa = Self.addr(kAudioProcessPropertyPID)
                var pid: Int32 = 0
                sz = UInt32(MemoryLayout<Int32>.size)
                guard AudioObjectGetPropertyData(obj, &pa, 0, nil, &sz, &pid) == noErr, pid != selfPID else { continue }
                var ba = Self.addr(kAudioProcessPropertyBundleID)
                var rawCF: Unmanaged<CFString>?
                sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                let rc = withUnsafeMutablePointer(to: &rawCF) { AudioObjectGetPropertyData(obj, &ba, 0, nil, &sz, $0) }
                var bundle = (rc == noErr ? rawCF?.takeRetainedValue() as String? : nil) ?? ""
                if bundle.isEmpty { bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" }
                if bundle == Bundle.main.bundleIdentifier { continue }
                out.append(Proc(obj: obj, pid: pid, bundle: bundle))
            }
        }
        procs = out
        let now = hostNow()
        let pids = Set(out.map(\.pid))
        firstSeen = firstSeen.filter { pids.contains($0.key) }
        for p in out where firstSeen[p.pid] == nil { firstSeen[p.pid] = now }
        syncBrowserTabs()
        manageTimers()
        reevaluate()
    }

    // MARK: sources

    private func appName(pid: Int32, bundle: String) -> String {
        if let n = NSRunningApplication(processIdentifier: pid)?.localizedName { return n }
        if let id = bundle.split(separator: ".").last, !id.isEmpty { return String(id) }
        var buf = [CChar](repeating: 0, count: 64)
        proc_name(pid, &buf, 64)
        let s = String(cString: buf)
        return s.isEmpty ? "Audio" : s
    }

    private func isAppRunning(_ bundleID: String) -> Bool {
        if let check = runningAppCheck { return check(bundleID) }
        return !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    private func currentFrontmost() -> String? {
        if let p = frontmostProvider { return p() }
        return fmLock.withLock { cachedFrontmost }
    }

    /// Browser that actually owns the tab to ask (WebKit helpers belong to whichever Safari-like app runs).
    private func scriptTarget(for b: BrowserInfo, frontmost: String?) -> String? {
        if b.id == "com.apple.WebKit" {
            let candidates = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.kagi.kagimacOS"]
            if let fm = frontmost, candidates.contains(fm), isAppRunning(fm) { return fm }
            for id in candidates where isAppRunning(id) { return id }
            return nil
        }
        return isAppRunning(b.id) ? b.id : nil
    }

    private func sourceInfos(frontmost: String?) -> [SourceInfo] {
        var seen = Set<String>()
        var out: [SourceInfo] = []
        for p in procs {
            let c = SourceRules.classifyBundle(p.bundle)
            if c.kind == .ignore { continue }
            let first = firstSeen[p.pid] ?? hostNow()
            if let b = c.browser {
                let target = scriptTarget(for: b, frontmost: frontmost)
                let appID = target ?? b.id
                let name = target.flatMap { SourceRules.browser(forBundle: $0)?.name } ?? b.name
                if !seen.insert("b:" + appID).inserted { continue }
                var kind = SourceKind.unknown, label = name
                if let t = target, let info = tabInfo[t], let v = SourceRules.classifyURL(info.url) {
                    kind = v.kind; label = "\(v.site) in \(name)"
                }
                out.append(SourceInfo(pid: p.pid, appID: appID, label: label, kind: kind, firstSeen: first))
            } else {
                if !seen.insert("p:\(p.pid)").inserted { continue }
                out.append(SourceInfo(pid: p.pid, appID: p.bundle, label: c.name ?? appName(pid: p.pid, bundle: p.bundle), kind: c.kind, firstSeen: first))
            }
        }
        return out
    }

    private func reevaluate(fromClassifier: Bool = false, at timestamp: Double? = nil) {
        guard listening else { return }
        let now = timestamp ?? hostNow()
        let fm = currentFrontmost()
        let infos = sourceInfos(frontmost: fm)
        let res = AutoSourceResolver.resolve(infos, frontmost: fm)
        var changed = false
        switch res.basis {
        case .idle:
            clsMode = nil; clsVerdict = .unsure; unsureStreak = 0; silentSkips = 0
            hyst.clearPending()
        case .rule:
            clsMode = nil; clsVerdict = .unsure; unsureStreak = 0; silentSkips = 0
            if lastBasis == .idle, let m = res.mode {
                changed = hyst.current != m
                hyst.force(m)
            } else {
                changed = hyst.update(candidate: res.mode, evidenceStart: now, now: now, hold: holdRule)
            }
        case .classifier:
            if lastBasis == .rule {
                clsMode = nil; clsVerdict = .unsure; unsureStreak = 0; silentSkips = 0
                hyst.clearPending()
            }
            if fromClassifier {
                changed = hyst.update(candidate: clsMode, evidenceStart: clsWindowStart, now: now, hold: holdClassifier)
            }
        }
        lastBasis = res.basis
        if changed { Log.write("[auto] mode -> \(hyst.current.rawValue) (\(res.label), \(res.basis.rawValue))") }
        if let sink = engineSink { sink(hyst.current) } else { HapticEngine.shared.setAutoMode(hyst.current) }
        var s = status
        s.active = true
        s.playing = res.basis != .idle
        s.mode = hyst.current
        s.source = res.label
        s.basis = res.basis
        s.note = noteForBrowsers(infos)
        if s != status { status = s; publish() }
        // Wake exactly when a pending rule switch matures instead of polling.
        recheckWork?.cancel()
        if res.basis == .rule, let rem = hyst.remaining(now: now, hold: holdRule) {
            let w = DispatchWorkItem { [weak self] in self?.reevaluate() }
            recheckWork = w
            q.asyncAfter(deadline: .now() + rem + 0.02, execute: w)
        }
    }

    private func noteForBrowsers(_ infos: [SourceInfo]) -> String? {
        guard !deniedBrowsers.isEmpty, infos.contains(where: { $0.kind == .unknown }) else { return nil }
        return "Allow Automation for your browser in Privacy settings to tell tabs apart. Using sound analysis instead."
    }

    private func publish() {
        let s = status, cb = onStatus
        cb?(s)
    }

    // MARK: event-driven browser queries + duty-cycled classifier

    private func manageTimers() {
        let infos = sourceInfos(frontmost: currentFrontmost())
        let res = AutoSourceResolver.resolve(infos, frontmost: nil)
        if res.basis == .classifier {
            // A tab query for the only unknown browser sources is still running: its answer may be a known site.
            let now = hostNow()
            let unknown = infos.filter { $0.kind == .unknown }
            if !unknown.isEmpty, unknown.allSatisfy({ (tabInFlight[$0.appID] ?? 0) > now }) { return }
            startClassifier()
        } else { stopClassifier() }
    }

    /// Queries each playing non-Firefox browser at most once per source change (never on a repeating timer).
    private func syncBrowserTabs() {
        let fm = currentFrontmost()
        var current: [String: (family: BrowserFamily, sig: Set<Int32>)] = [:]
        for p in procs {
            guard let b = SourceRules.classifyBundle(p.bundle).browser, b.family != .firefox,
                  let t = scriptTarget(for: b, frontmost: fm) else { continue }
            let fam = SourceRules.browser(forBundle: t)?.family ?? b.family
            var entry = current[t] ?? (fam, Set<Int32>())
            entry.sig.insert(p.pid)
            current[t] = entry
        }
        // Clear cached tab info when a browser stops playing so next playback queries fresh.
        for key in Array(queriedBrowserSigs.keys) where current[key] == nil {
            queriedBrowserSigs[key] = nil
            tabInfo[key] = nil
            lastTabQueryAt[key] = nil
        }
        let toQuery = current.map { (id: $0.key, family: $0.value.family, sig: $0.value.sig) }
        queryBrowserTargets(toQuery, force: false)
    }

    private func queryBrowserTargets(_ targets: [(id: String, family: BrowserFamily, sig: Set<Int32>)], force: Bool) {
        let now = hostNow()
        for t in targets {
            guard !deniedBrowsers.contains(t.id) else { continue }
            if (tabInFlight[t.id] ?? 0) > now { continue }
            if force {
                if now - (lastTabQueryAt[t.id] ?? 0) < 1.0 { continue }
            } else {
                if queriedBrowserSigs[t.id] == t.sig { continue }
            }
            queriedBrowserSigs[t.id] = t.sig
            lastTabQueryAt[t.id] = now
            statLock.withLock { _tabQueries += 1 }
            tabInFlight[t.id] = now + 8
            let querier = self.tabQuerier
            let applyResult: (TabResult) -> Void = { [weak self] r in
                guard let self, self.listening else { return }
                self.tabInFlight[t.id] = nil
                var changed = false
                switch r {
                case .tab(let url, let title):
                    self.deniedBrowsers.remove(t.id)
                    changed = self.tabInfo[t.id]?.url != url
                    self.tabInfo[t.id] = (url, title, hostNow())
                case .denied:
                    if self.deniedBrowsers.insert(t.id).inserted {
                        self.tabInfo[t.id] = nil
                        changed = true
                    }
                case .unavailable:
                    if self.tabInfo[t.id] != nil {
                        self.tabInfo[t.id] = nil
                        changed = true
                    }
                }
                self.manageTimers()   // also releases a classifier start deferred by this query
                if changed { self.reevaluate() }
            }
            if let querier {
                applyResult(querier(t.id, t.family))
            } else {
                scriptQ.async { [weak self] in
                    let r = Self.queryTab(bundle: t.id, family: t.family)
                    self?.q.async { applyResult(r) }
                }
            }
        }
    }

    // MARK: Apple Events (browser tab)

    enum TabResult { case tab(String, String), denied, unavailable }

    private static func permission(_ bundle: String, ask: Bool) -> OSStatus {
        var desc = AEAddressDesc()
        let bytes = Array(bundle.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), bytes, bytes.count, &desc) == noErr else { return -1 }
        defer { AEDisposeDesc(&desc) }
        return AEDeterminePermissionToAutomateTarget(&desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    private static func queryTab(bundle: String, family: BrowserFamily) -> TabResult {
        var st = permission(bundle, ask: false)
        if st == OSStatus(procNotFound) { return .unavailable }
        if st == -1744 {   // errAEEventWouldRequireUserConsent: ask exactly once per browser, ever
            let key = "autoSource.asked.\(bundle)"
            if UserDefaults.standard.bool(forKey: key) { return .denied }
            st = permission(bundle, ask: true)
            if st != OSStatus(procNotFound) { UserDefaults.standard.set(true, forKey: key) }
        }
        if st != noErr { return st == OSStatus(procNotFound) ? .unavailable : .denied }
        let body: String
        switch family {
        case .safari:
            body = "return (URL of current tab of front window) & linefeed & (name of current tab of front window)"
        default:
            body = "return (URL of active tab of front window) & linefeed & (title of active tab of front window)"
        }
        // Short Apple Event timeout (default is 2 minutes) so one hung browser cannot stall the serial script queue.
        let src = "with timeout of 3 seconds\ntell application id \"\(bundle)\"\n\(body)\nend tell\nend timeout"
        guard let script = NSAppleScript(source: src) else { return .unavailable }
        var err: NSDictionary?
        let r = script.executeAndReturnError(&err)
        if let e = err {
            let n = (e[NSAppleScript.errorNumber] as? Int) ?? 0
            return (n == -1743 || n == -1744) ? .denied : .unavailable
        }
        let parts = (r.stringValue ?? "").components(separatedBy: "\n")
        guard let url = parts.first, !url.isEmpty, url != "missing value" else { return .unavailable }
        return .tab(url, parts.dropFirst().joined(separator: "\n"))
    }

    // MARK: classifier (duty-cycled)

    private func startClassifier() {
        if clsTimer != nil { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        let saver = PowerState.shared.saver
        clsSaver = saver
        let period: Double = saver ? 5.0 : 3.0
        t.schedule(deadline: .now() + 0.3, repeating: period, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.openWindow() }
        t.resume()
        clsTimer = t
    }

    private func stopClassifier() {
        clsGen &+= 1
        clsTimer?.cancel(); clsTimer = nil
        if clsToken != 0 { FeatureBus.shared.unsubscribe(clsToken); clsToken = 0 }
    }

    private func openWindow() {
        guard listening, clsToken == 0 else { return }
        let last = FeatureBus.shared.latest()
        if last.silent || hostNow() - last.time > 1.0 {
            silentSkips += 1
            if silentSkips >= 2 { hyst.clearPending() }
            return
        }
        silentSkips = 0
        accLock.withLock { acc = SpeechMusicAccumulator() }
        clsWindowStart = hostNow()
        clsToken = FeatureBus.shared.subscribe { [weak self] f in
            guard let self else { return }
            self.accLock.withLock { self.acc.add(f) }
        }
        statLock.withLock { _classifierWindows += 1 }
        let g = clsGen
        q.asyncAfter(deadline: .now() + windowDuration) { [weak self] in
            guard let self, self.clsGen == g else { return }
            self.closeWindow()
        }
    }

    private func closeWindow() {
        guard listening else {
            if clsToken != 0 { FeatureBus.shared.unsubscribe(clsToken); clsToken = 0 }
            return
        }
        if clsToken != 0 { FeatureBus.shared.unsubscribe(clsToken); clsToken = 0 }
        let v = accLock.withLock { acc.verdict(windowSeconds: windowDuration) }
        applyClassifierVerdict(v, at: hostNow())
    }

    private func applyClassifierVerdict(_ v: SpeechVerdict, at now: Double) {
        clsVerdict = v
        switch v {
        case .speech:
            clsMode = .movie
            unsureStreak = 0
            reevaluate(fromClassifier: true, at: now)
        case .music:
            clsMode = .music
            unsureStreak = 0
            reevaluate(fromClassifier: true, at: now)
        case .unsure:
            clsMode = nil
            unsureStreak += 1
            if unsureStreak >= 2 { hyst.clearPending() }
        }
    }
}
