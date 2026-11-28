// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
import Foundation

/// What a site resolver found: media URLs to try in order (best first) plus attribution.
struct ImportPlan: @unchecked Sendable {
    var candidates: [URL]
    var title: String?
    var artist: String?
    var site: String
    var tags: [String] = []
    /// Set when the original link already was the media file.
    var preFetched: FetchedResource?
}

enum ImportResolvers {
    // MARK: DeviantArt

    /// oEmbed returns the full public file for the deviation (the animated GIF itself for GIF art),
    /// not the resized preview. Falls back to the page's og:image. No login or download button is used.
    static func deviantArt(_ url: URL) async throws -> ImportPlan {
        var comps = URLComponents(string: "https://backend.deviantart.com/oembed")!
        comps.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        var plan = ImportPlan(candidates: [], title: nil, artist: nil, site: "DeviantArt")
        do {
            guard let d = try await ImportNet.fetchJSON(comps.url!) as? [String: Any] else { throw WallpaperImportError.invalidMedia }
            plan.title = d["title"] as? String
            plan.artist = d["author_name"] as? String
            if let t = d["tags"] as? String { plan.tags = t.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
            if (d["type"] as? String) == "photo", let s = d["url"] as? String, let u = ImportHTML.resolve(s, base: url) {
                plan.candidates.append(u)
            }
        } catch WallpaperImportError.notFound {
            throw WallpaperImportError.notFound
        } catch is CancellationError {
            throw CancellationError()
        } catch {}
        if plan.candidates.isEmpty {
            let page = try await generic(url)
            guard page.preFetched == nil else { return page }
            plan.candidates = page.candidates
            plan.title = plan.title ?? page.title
            plan.artist = plan.artist ?? page.artist
        }
        return plan
    }

    // MARK: ArtStation

    /// Uses the public project JSON; picks the largest asset image (or a direct video/GIF asset).
    static func artStation(_ url: URL) async throws -> ImportPlan {
        let parts = url.path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(where: { $0 == "artwork" || $0 == "projects" }), i + 1 < parts.count else {
            throw WallpaperImportError.unsupportedSite
        }
        let hash = parts[i + 1].replacingOccurrences(of: ".json", with: "")
        guard let api = URL(string: "https://www.artstation.com/projects/\(hash).json"),
              let d = try await ImportNet.fetchJSON(api) as? [String: Any] else { throw WallpaperImportError.invalidMedia }
        var plan = ImportPlan(candidates: [], title: d["title"] as? String, artist: nil, site: "ArtStation")
        if let u = d["user"] as? [String: Any] {
            plan.artist = (u["full_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? u["username"] as? String
        }
        if let tags = d["tags"] as? [String] { plan.tags = tags }
        if let cats = d["categories"] as? [[String: Any]] { plan.tags += cats.compactMap { $0["name"] as? String } }

        var scored: [(URL, Int)] = []
        for a in (d["assets"] as? [[String: Any]]) ?? [] {
            let w = (a["width"] as? Int) ?? 0, h = (a["height"] as? Int) ?? 0
            let area = w * h
            // Embedded players: only a player whose source is itself a video file can be imported.
            if let html = a["player_embedded"] as? String,
               let r = html.range(of: "src=\"[^\"]+\"", options: .regularExpression) {
                let s = String(html[r].dropFirst(5).dropLast())
                if let u = ImportHTML.resolve(s, base: url), u.isLikelyVideoFile { scored.append((u, area + 1)) }
            }
            if let s = a["image_url"] as? String, let u = ImportHTML.resolve(s, base: url) {
                scored.append((u, area))
            }
        }
        plan.candidates = scored.sorted { $0.1 > $1.1 }.map { $0.0 }
        if plan.candidates.isEmpty { throw WallpaperImportError.notFound }
        return plan
    }

    // MARK: Reddit

    static func reddit(_ url: URL) async throws -> ImportPlan {
        let host = (url.host ?? "").lowercased()
        let parts = url.path.split(separator: "/").map(String.init)
        var id: String?
        if host.hasSuffix("redd.it") { id = parts.first }
        else if let i = parts.firstIndex(where: { $0 == "comments" || $0 == "gallery" }), i + 1 < parts.count { id = parts[i + 1] }
        guard let id, !id.isEmpty else { throw WallpaperImportError.unsupportedSite }
        // The full path form is only needed for readability; the id alone resolves to the same post.
        var comps = URLComponents(string: "https://www.reddit.com/comments/\(id).json")!
        comps.queryItems = [URLQueryItem(name: "raw_json", value: "1")]
        guard let root = try await ImportNet.fetchJSON(comps.url!) as? [[String: Any]],
              let post = ((root.first?["data"] as? [String: Any])?["children"] as? [[String: Any]])?.first?["data"] as? [String: Any]
        else { throw WallpaperImportError.notFound }

        let src = ((post["crosspost_parent_list"] as? [[String: Any]])?.first) ?? post
        var plan = ImportPlan(candidates: [], title: post["title"] as? String, artist: nil, site: "Reddit")
        if let a = post["author"] as? String, a != "[deleted]" { plan.artist = "u/\(a)" }
        plan.tags = [post["subreddit"] as? String, post["link_flair_text"] as? String].compactMap { $0 }

        var out: [URL] = []
        func add(_ s: String?) {
            guard let s, let u = ImportHTML.resolve(s, base: url), !out.contains(u) else { return }
            out.append(u)
        }

        // Galleries: first item, original i.redd.it file first.
        if (src["is_gallery"] as? Bool) == true,
           let first = ((src["gallery_data"] as? [String: Any])?["items"] as? [[String: Any]])?.first,
           let mid = first["media_id"] as? String,
           let meta = (src["media_metadata"] as? [String: Any])?[mid] as? [String: Any] {
            if let m = meta["m"] as? String {
                let ext = m.hasSuffix("gif") ? "gif" : (m.hasSuffix("png") ? "png" : (m.hasSuffix("webp") ? "webp" : "jpg"))
                add("https://i.redd.it/\(mid).\(ext)")
            }
            let s = meta["s"] as? [String: Any]
            add(s?["gif"] as? String); add(s?["u"] as? String); add(s?["mp4"] as? String)
        }
        // Hosted video: highest progressive DASH rendition (video-only; wallpapers are muted).
        for key in ["media", "secure_media"] {
            add(((src[key] as? [String: Any])?["reddit_video"] as? [String: Any])?["fallback_url"] as? String)
        }
        // Linked media.
        if let dest = (src["url_overridden_by_dest"] as? String) ?? (src["url"] as? String),
           let u = ImportHTML.resolve(dest, base: url), u.isLikelyMediaFile || (u.host ?? "") == "i.redd.it" {
            for v in imgurVariants(u) { add(v.absoluteString) }
        }
        // Reddit-hosted previews.
        if let img = ((src["preview"] as? [String: Any])?["images"] as? [[String: Any]])?.first {
            let variants = img["variants"] as? [String: Any]
            add(((variants?["gif"] as? [String: Any])?["source"] as? [String: Any])?["url"] as? String)
            add(((variants?["mp4"] as? [String: Any])?["source"] as? [String: Any])?["url"] as? String)
            add((img["source"] as? [String: Any])?["url"] as? String)
        }
        add(((src["preview"] as? [String: Any])?["reddit_video_preview"] as? [String: Any])?["fallback_url"] as? String)
        plan.candidates = out
        if out.isEmpty { throw WallpaperImportError.notFound }
        return plan
    }

    // MARK: Imgur + generic

    /// For an imgur `.gifv` page link, try the GIF then the MP4; other URLs pass through.
    static func imgurVariants(_ u: URL) -> [URL] {
        guard u.importExtension == "gifv" else { return [u] }
        let base = u.deletingPathExtension()
        return [base.appendingPathExtension("gif"), base.appendingPathExtension("mp4")]
    }

    /// Direct media link, or any page: scrape og:video / og:image / twitter:image.
    static func generic(_ url: URL, siteOverride: String? = nil) async throws -> ImportPlan {
        let r = try await ImportNet.fetch(url, accept: "text/html,image/*,video/*;q=0.9,*/*;q=0.5")
        let host = (url.host ?? "").replacingOccurrences(of: "www.", with: "")
        switch r.body {
        case .file:
            return ImportPlan(candidates: [r.finalURL], title: nil, artist: nil, site: siteOverride ?? host, preFetched: r)
        case .data(let data):
            let html = String(decoding: data, as: UTF8.self)
            let meta = ImportHTML.metaTags(html)
            func values(_ keys: [String]) -> [URL] {
                keys.flatMap { k in meta.filter { $0.key == k }.compactMap { ImportHTML.resolve($0.content, base: r.finalURL) } }
            }
            let videoType = meta.first { $0.key == "og:video:type" }?.content.lowercased() ?? ""
            let videos = values(["og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream"])
                .filter { $0.isLikelyVideoFile || $0.importExtension == "gif" || videoType.hasPrefix("video/") && !$0.importExtension.hasPrefix("htm") }
            var images = values(["og:image:secure_url", "og:image:url", "og:image", "twitter:image", "twitter:image:src"])
            if host.hasSuffix("imgur.com") {
                images = images.map { u in
                    var c = URLComponents(url: u, resolvingAgainstBaseURL: false); c?.query = nil
                    return c?.url ?? u
                }
            }
            var cands: [URL] = []
            for u in videos + images { for v in imgurVariants(u) where !cands.contains(v) { cands.append(v) } }
            guard !cands.isEmpty else { throw WallpaperImportError.notFound }
            let siteName = meta.first { $0.key == "og:site_name" }?.content
            let title = meta.first { $0.key == "og:title" || $0.key == "twitter:title" }?.content ?? ImportHTML.titleTag(html)
            let artist = meta.first { ["author", "article:author", "twitter:creator"].contains($0.key) }?.content
            let site = siteOverride ?? (siteName.flatMap { $0.isEmpty ? nil : $0 } ?? host)
            let tags = meta.filter { $0.key == "keywords" || $0.key == "article:tag" }
                .flatMap { $0.content.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            return ImportPlan(candidates: cands, title: title, artist: artist, site: site, tags: tags)
        }
    }
}
