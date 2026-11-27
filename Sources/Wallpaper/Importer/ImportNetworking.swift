// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 Vijay A. HapticGlow: https://github.com/VA24d/HapticGlow
// Additional attribution terms under GPLv3 section 7(b): see NOTICE.md.
import Foundation

/// Result of one HTTP GET: text-like responses come back as memory, media as a temp file.
struct FetchedResource: @unchecked Sendable {
    enum Body { case data(Data), file(URL) }
    var body: Body
    var finalURL: URL
    var contentType: String?
}

enum ImportNet {
    static let userAgent = "HapticGlow/2.x (macOS wallpaper importer)"
    static let maxFileBytes: Int64 = 300 * 1024 * 1024
    static let maxPageBytes: Int64 = 8 * 1024 * 1024

    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("HapticGlowImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fetch(_ url: URL, accept: String = "*/*",
                      progress: (@Sendable (Double) -> Void)? = nil) async throws -> FetchedResource {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(accept, forHTTPHeaderField: "Accept")
        return try await ImportFetch(progress: progress).run(req)
    }

    /// Fetches a page or JSON document. Media responses are rejected.
    static func fetchText(_ url: URL, accept: String = "text/html,application/json;q=0.9,*/*;q=0.5") async throws -> (Data, URL) {
        let r = try await fetch(url, accept: accept)
        switch r.body {
        case .data(let d): return (d, r.finalURL)
        case .file(let f):
            try? FileManager.default.removeItem(at: f.deletingLastPathComponent())
            throw WallpaperImportError.invalidMedia
        }
    }

    static func fetchJSON(_ url: URL) async throws -> Any {
        let (data, _) = try await fetchText(url, accept: "application/json")
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { throw WallpaperImportError.invalidMedia }
        return obj
    }
}

/// One-shot URLSession data delegate: streams to a temp file with a size cap, reports progress.
/// No cookies are stored or sent, so only what a logged-out visitor gets can be fetched.
final class ImportFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let progress: (@Sendable (Double) -> Void)?
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cont: CheckedContinuation<FetchedResource, Error>?
    private var session: URLSession?
    private var status = 0
    private var contentType: String?
    private var finalURL: URL?
    private var expected: Int64 = -1
    private var received: Int64 = 0
    private var toFile = false
    private var memory = Data()
    private var handle: FileHandle?
    private var fileURL: URL?
    private var failure: Error?

    init(progress: (@Sendable (Double) -> Void)?) { self.progress = progress }

    func run(_ request: URLRequest) async throws -> FetchedResource {
        finalURL = request.url
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<FetchedResource, Error>) in
                let cfg = URLSessionConfiguration.ephemeral
                cfg.httpCookieStorage = nil
                cfg.httpShouldSetCookies = false
                cfg.urlCredentialStorage = nil
                cfg.timeoutIntervalForRequest = 30
                cfg.timeoutIntervalForResource = 900
                let q = OperationQueue()
                q.maxConcurrentOperationCount = 1
                let s = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
                let t = s.dataTask(with: request)
                lock.lock(); cont = c; session = s; task = t; lock.unlock()
                t.resume()
            }
        } onCancel: {
            lock.lock(); let t = task; lock.unlock()
            t?.cancel()
        }
    }

    private func finish(_ result: Result<FetchedResource, Error>) {
        lock.lock()
        let c = cont; cont = nil
        let s = session; session = nil
        lock.unlock()
        s?.finishTasksAndInvalidate()
        guard let c else { return }
        if case .failure = result, let f = fileURL {
            try? handle?.close()
            try? FileManager.default.removeItem(at: f.deletingLastPathComponent())
        }
        c.resume(with: result)
    }

    private func abort(_ error: Error, _ dataTask: URLSessionTask) {
        if failure == nil { failure = error }
        dataTask.cancel()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = WallpaperImportError.invalidMedia
            completionHandler(.cancel); return
        }
        status = http.statusCode
        finalURL = http.url ?? finalURL
        contentType = http.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        expected = http.expectedContentLength
        let ct = contentType ?? ""
        let textual = ct.isEmpty || ct.hasPrefix("text/") || ct.contains("json") || ct.contains("xml") || ct.contains("html")
        if status >= 400 || textual {
            toFile = false
        } else {
            if expected > ImportNet.maxFileBytes {
                failure = WallpaperImportError.network("The file is larger than the 300 MB import limit.")
                completionHandler(.cancel); return
            }
            do {
                let dir = try ImportNet.makeTempDir()
                let f = dir.appendingPathComponent("download.part")
                FileManager.default.createFile(atPath: f.path, contents: nil)
                handle = try FileHandle(forWritingTo: f)
                fileURL = f
                toFile = true
            } catch {
                failure = WallpaperImportError.network("Could not create a temporary file.")
                completionHandler(.cancel); return
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += Int64(data.count)
        if toFile {
            if received > ImportNet.maxFileBytes {
                abort(WallpaperImportError.network("The file is larger than the 300 MB import limit."), dataTask); return
            }
            do { try handle?.write(contentsOf: data) } catch {
                abort(WallpaperImportError.network("Could not write the download."), dataTask); return
            }
            if expected > 0 { progress?(min(1, Double(received) / Double(expected))) }
        } else {
            if received > ImportNet.maxPageBytes {
                abort(WallpaperImportError.network("The page is too large."), dataTask); return
            }
            memory.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure { finish(.failure(failure)); return }
        if let error {
            if (error as? URLError)?.code == .cancelled { finish(.failure(CancellationError())) }
            else { finish(.failure(WallpaperImportError.network(error.localizedDescription))) }
            return
        }
        if status >= 400 {
            let body = String(decoding: memory.prefix(4096), as: UTF8.self).lowercased()
            switch status {
            case 401: finish(.failure(WallpaperImportError.needsLogin))
            case 404, 410: finish(.failure(WallpaperImportError.notFound))
            case 403 where body.contains("\"private\"") || body.contains("log in") || body.contains("login required"):
                finish(.failure(WallpaperImportError.needsLogin))
            case 403:
                finish(.failure(WallpaperImportError.network("The site refused the request (HTTP 403). It may block automated access.")))
            default:
                finish(.failure(WallpaperImportError.network("The site answered with HTTP \(status).")))
            }
            return
        }
        guard let finalURL else { finish(.failure(WallpaperImportError.invalidMedia)); return }
        if toFile, let f = fileURL {
            try? handle?.close()
            progress?(1)
            finish(.success(FetchedResource(body: .file(f), finalURL: finalURL, contentType: contentType)))
        } else {
            finish(.success(FetchedResource(body: .data(memory), finalURL: finalURL, contentType: contentType)))
        }
    }
}
