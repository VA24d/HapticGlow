// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
// Now playing: reads the current song from Apple Music and Spotify. Both apps announce every track and
// play-state change as a distributed notification, which needs no permission. At launch, when one of them
// is already running, the song is asked for once over Apple Events (macOS asks the user once; a refusal
// is silent). Nothing here controls playback, and the metadata never leaves the Mac.
import Foundation
import AppKit

struct NowPlayingTrack: Equatable, Sendable {
    enum Player: String, Sendable { case music, spotify }
    var player: Player
    var title: String
    var artist: String
    var album = ""
    var genre = ""
    /// Apple Music persistent ID (16 hex digits) or Spotify track id; nil when the app sent none.
    var id: String?

    /// Memory key: the player's own id when there is one, else the normalised "artist|title".
    var key: String { SongKey.make(player: player.rawValue, id: id, artist: artist, title: title) }
}

enum SongKey {
    static func make(player: String, id: String?, artist: String, title: String) -> String {
        if let id, !id.isEmpty { return "\(player):\(id)" }
        return "meta:\(normalize(artist))|\(normalize(title))"
    }

    /// Lower case, accents folded, punctuation dropped, spaces collapsed.
    static func normalize(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        var out = "", gap = false
        for ch in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(ch) {
                if gap && !out.isEmpty { out.append(" ") }
                gap = false
                out.unicodeScalars.append(ch)
            } else { gap = true }
        }
        return out
    }

    /// Apple Music sends PersistentID as a signed decimal number; AppleScript gives the same 64 bits as hex.
    static func musicID(_ any: Any?) -> String? {
        if let n = any as? NSNumber { return String(format: "%016llX", UInt64(bitPattern: n.int64Value)) }
        if let s = any as? String, !s.isEmpty { return s.uppercased() }
        return nil
    }

    /// "spotify:track:6rqhFg..." -> "6rqhFg...".
    static func spotifyID(_ any: Any?) -> String? {
        guard let s = any as? String, !s.isEmpty else { return nil }
        return s.split(separator: ":").last.map(String.init)
    }
}

enum NowPlayingParser {
    /// A playing track from a notification payload, or nil when stopped, paused or unreadable.
    static func parse(_ info: [AnyHashable: Any], player: NowPlayingTrack.Player) -> NowPlayingTrack? {
        guard (info["Player State"] as? String)?.lowercased() == "playing" else { return nil }
        let title = (info["Name"] as? String) ?? ""
        guard !title.isEmpty else { return nil }
        var t = NowPlayingTrack(player: player, title: title, artist: (info["Artist"] as? String) ?? "")
        t.album = (info["Album"] as? String) ?? ""
        switch player {
        case .music:
            t.genre = (info["Genre"] as? String) ?? ""
            t.id = SongKey.musicID(info["PersistentID"])
        case .spotify:
            t.id = SongKey.spotifyID(info["Track ID"])
        }
        if t.artist.isEmpty, let a = info["Album Artist"] as? String { t.artist = a }
        return t
    }
}

@MainActor
final class NowPlayingMonitor {
    static let musicBundle = "com.apple.Music"
    static let spotifyBundle = "com.spotify.client"

    var onChange: ((NowPlayingTrack?) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var current: NowPlayingTrack?
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let dnc = DistributedNotificationCenter.default()
        let feeds: [(String, NowPlayingTrack.Player)] = [
            ("com.apple.Music.playerInfo", .music),
            ("com.spotify.client.PlaybackStateChanged", .spotify),
        ]
        for (name, player) in feeds {
            observers.append(dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] n in
                let info = n.userInfo ?? [:]
                MainActor.assumeIsolated { self?.receive(NowPlayingParser.parse(info, player: player), from: player) }
            })
        }
        // A player that quits without saying "stopped" must not leave its song on screen.
        wsObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let bid = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                if bid == Self.musicBundle { self?.receive(nil, from: .music) }
                if bid == Self.spotifyBundle { self?.receive(nil, from: .spotify) }
            }
        }
        queryRunningPlayers()
    }

    private var wsObserver: NSObjectProtocol?

    func stop() {
        for o in observers { DistributedNotificationCenter.default().removeObserver(o) }
        if let wsObserver { NSWorkspace.shared.notificationCenter.removeObserver(wsObserver) }
        observers = []
        wsObserver = nil
        started = false
        if current != nil { current = nil; onChange?(nil) }
    }

    private func receive(_ track: NowPlayingTrack?, from player: NowPlayingTrack.Player) {
        if let track {
            if current != track { current = track; onChange?(track) }
        } else if current?.player == player {
            current = nil
            onChange?(nil)
        }
    }

    // MARK: One-time query at launch

    private func queryRunningPlayers() {
        for (bundle, player) in [(Self.musicBundle, NowPlayingTrack.Player.music), (Self.spotifyBundle, .spotify)] {
            // Never launch a player: only ask one that is already running.
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let t = Self.queryCurrent(bundle: bundle, player: player)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        // A notification that arrived meanwhile is newer than this answer.
                        guard let t, let self, self.current == nil else { return }
                        self.receive(t, from: player)
                    }
                }
            }
        }
    }

    private nonisolated static func permission(_ bundle: String, ask: Bool) -> OSStatus {
        var desc = AEAddressDesc()
        let bytes = Array(bundle.utf8)
        guard AECreateDesc(DescType(typeApplicationBundleID), bytes, bytes.count, &desc) == noErr else { return -1 }
        defer { AEDisposeDesc(&desc) }
        return AEDeterminePermissionToAutomateTarget(&desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask)
    }

    private nonisolated static func queryCurrent(bundle: String, player: NowPlayingTrack.Player) -> NowPlayingTrack? {
        var st = permission(bundle, ask: false)
        if st == -1744 {   // consent needed: ask once per player, ever
            let key = "nowPlaying.asked.\(bundle)"
            if UserDefaults.standard.bool(forKey: key) { return nil }
            st = permission(bundle, ask: true)
            if st != OSStatus(procNotFound) { UserDefaults.standard.set(true, forKey: key) }
        }
        guard st == noErr else { return nil }
        let body: String
        switch player {
        case .music:
            body = "if player state is playing then\nset t to current track\nreturn (persistent ID of t) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t) & linefeed & (genre of t)\nend if\nreturn \"\""
        case .spotify:
            body = "if player state is playing then\nset t to current track\nreturn (id of t) & linefeed & (name of t) & linefeed & (artist of t) & linefeed & (album of t)\nend if\nreturn \"\""
        }
        let src = "with timeout of 3 seconds\ntell application id \"\(bundle)\"\n\(body)\nend tell\nend timeout"
        guard let script = NSAppleScript(source: src) else { return nil }
        var err: NSDictionary?
        let r = script.executeAndReturnError(&err)
        guard err == nil, let text = r.stringValue, !text.isEmpty else { return nil }
        let p = text.components(separatedBy: "\n")
        guard p.count >= 3, !p[1].isEmpty else { return nil }
        var t = NowPlayingTrack(player: player, title: p[1], artist: p[2])
        t.album = p.count > 3 ? p[3] : ""
        t.genre = p.count > 4 ? p[4] : ""
        t.id = player == .music ? SongKey.musicID(p[0]) : SongKey.spotifyID(p[0])
        return t
    }
}
