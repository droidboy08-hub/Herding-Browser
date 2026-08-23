import Foundation
import UIKit
import WebKit

/// A file the user downloaded. Live rows update in place while the transfer
/// runs; finished rows persist across launches.
struct DownloadItem: Identifiable, Codable, Equatable {
    enum State: String, Codable { case downloading, paused, completed, failed }

    let id: UUID
    var filename: String
    var sourceURL: URL
    var state: State
    var bytesReceived: Int64
    var bytesExpected: Int64          // -1 when the server sends no length
    var date: Date
    var errorMessage: String?

    /// Where the finished file lives. Downloads keep their name, so this is
    /// derived rather than stored — the folder can move between OS versions.
    var fileURL: URL { DownloadStore.directory.appendingPathComponent(filename) }

    var fractionCompleted: Double {
        guard bytesExpected > 0 else { return 0 }
        return min(1, Double(bytesReceived) / Double(bytesExpected))
    }

    /// "1.2 MB of 4.5 MB", or just the received size when the length is unknown.
    var sizeDescription: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        let got = f.string(fromByteCount: max(0, bytesReceived))
        guard bytesExpected > 0 else { return got }
        return "\(got) of \(f.string(fromByteCount: bytesExpected))"
    }
}

/// On-disk home for downloads: the files themselves plus the JSON index.
/// Files go in Documents/Downloads so the Files app can reach them
/// (`UIFileSharingEnabled` in Info.plist) — that is the Apple-sanctioned handoff.
enum DownloadStore {
    static let directory: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let indexURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("downloads.json")
    }()

    static func load() -> [DownloadItem] {
        guard let data = try? Data(contentsOf: indexURL),
              let items = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return [] }
        return items
    }

    static func save(_ items: [DownloadItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }

    /// A name that doesn't collide with an existing file: "report (2).pdf".
    static func uniqueURL(for suggested: String) -> URL {
        let safe = suggested.isEmpty ? "download" : suggested
            .replacingOccurrences(of: "/", with: "-")
        var candidate = directory.appendingPathComponent(safe)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }

        let ext = candidate.pathExtension
        let stem = candidate.deletingPathExtension().lastPathComponent
        var n = 2
        repeat {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            n += 1
        } while FileManager.default.fileExists(atPath: candidate.path)
        return candidate
    }
}

/// Runs downloads through `WKDownload` — WebKit's own download API, so cookies,
/// auth and redirects match the page the file came from. Nothing is fetched on a
/// side channel.
final class DownloadManager: NSObject {

    static let shared = DownloadManager()

    /// Posted whenever the list or any row's progress changes.
    static let didChangeNotification = Notification.Name("DownloadManager.didChange")

    /// Newest first.
    private(set) var items: [DownloadItem] = []

    /// The web view downloads are resumed/started from — a download must belong
    /// to a web view for WebKit to reuse its cookie store.
    weak var webView: WKWebView?

    private var itemID: [ObjectIdentifier: UUID] = [:]      // WKDownload -> item
    private var observations: [UUID: NSKeyValueObservation] = [:]
    private var live: [UUID: WKDownload] = [:]
    /// Resume data for paused transfers, kept in memory only.
    ///
    /// It can run to megabytes, and its value expires with the server's notion
    /// of the request, so writing it to disk would trade real space for a
    /// promise that often cannot be kept. A pause does not survive a relaunch;
    /// `resume` falls back to starting over, which is what the row already did.
    private var resumeData: [UUID: Data] = [:]
    private var retryCount: [UUID: Int] = [:]
    private let maxAutoRetries = 1

    var hasActiveDownloads: Bool { items.contains { $0.state == .downloading } }
    var failedItems: [DownloadItem] { items.filter { $0.state == .failed } }

    private override init() {
        super.init()
        items = DownloadStore.load()
        // A transfer can't survive the process dying, so anything still marked
        // "downloading" at launch was interrupted — show it as failed and
        // retryable rather than as a row that never moves.
        for i in items.indices where items[i].state == .downloading {
            items[i].state = .failed
            items[i].errorMessage = "Interrupted"
        }
        // Drop completed rows whose file the user deleted from the Files app.
        items.removeAll { $0.state == .completed
            && !FileManager.default.fileExists(atPath: $0.fileURL.path) }
        DownloadStore.save(items)
    }

    // MARK: - Starting

    /// Adopt a download WebKit just handed us (a link or response that turned out
    /// to be a file rather than a page).
    func adopt(_ download: WKDownload, suggestedName: String? = nil) {
        download.delegate = self
        let url = download.originalRequest?.url
        let item = DownloadItem(
            id: UUID(),
            filename: suggestedName ?? url?.lastPathComponent ?? "download",
            sourceURL: url ?? URL(string: "about:blank")!,
            state: .downloading,
            bytesReceived: 0,
            bytesExpected: -1,
            date: Date(),
            errorMessage: nil)
        items.insert(item, at: 0)
        itemID[ObjectIdentifier(download)] = item.id
        live[item.id] = download
        observeProgress(of: download, id: item.id)
        persistAndNotify()
    }

    /// Re-run a failed download from its original URL, as a fresh transfer.
    ///
    /// A *paused* download resumes where it stopped instead — see `resume`.
    /// This is for the ones that failed, which have no resume data to offer.
    func retry(_ item: DownloadItem) {
        guard let webView, item.state != .downloading else { return }
        resumeData[item.id] = nil
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].state = .downloading
        items[idx].bytesReceived = 0
        items[idx].errorMessage = nil
        items[idx].date = Date()
        let id = items[idx].id
        persistAndNotify()

        webView.startDownload(using: URLRequest(url: item.sourceURL)) { [weak self] download in
            guard let self else { return }
            download.delegate = self
            self.itemID[ObjectIdentifier(download)] = id
            self.live[id] = download
            self.observeProgress(of: download, id: id)
        }
    }

    func retryAllFailed() {
        for item in failedItems { retry(item) }
    }

    // MARK: - Pausing

    /// Stop the transfer but keep what has arrived.
    ///
    /// `WKDownload` has no pause. What it has is a cancel that hands back
    /// resume data, and a `resumeDownload` on the web view that takes it —
    /// which together are a pause, and are what this does.
    func pause(_ item: DownloadItem) {
        guard let download = live[item.id] else { return }
        download.cancel { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                self.live[item.id] = nil
                self.observations[item.id] = nil
                self.resumeData[item.id] = data
                guard let idx = self.items.firstIndex(where: { $0.id == item.id }) else { return }
                self.items[idx].state = .paused
                // No resume data means the server would not offer a range, so
                // resuming will have to start over. Say so on the row rather
                // than discovering it on the tap.
                self.items[idx].errorMessage = data == nil ? "Paused — will restart" : nil
                self.persistAndNotify()
            }
        }
    }

    /// Pick a paused transfer back up, from where it stopped if the server
    /// allowed it and from the beginning if it did not.
    func resume(_ item: DownloadItem) {
        guard let webView, item.state == .paused else { return }
        guard let data = resumeData[item.id] else {
            retry(item)
            return
        }
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].state = .downloading
        items[idx].errorMessage = nil
        let id = items[idx].id
        resumeData[id] = nil
        persistAndNotify()

        webView.resumeDownload(fromResumeData: data) { [weak self] download in
            guard let self else { return }
            download.delegate = self
            itemID[ObjectIdentifier(download)] = id
            live[id] = download
            observeProgress(of: download, id: id)
        }
    }

    // MARK: - Editing the list

    func cancel(_ item: DownloadItem) {
        live[item.id]?.cancel()
        live[item.id] = nil
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].state = .failed
        items[idx].errorMessage = "Cancelled"
        persistAndNotify()
    }

    /// Remove the row and the file it points at.
    func remove(_ item: DownloadItem) {
        live[item.id]?.cancel()
        live[item.id] = nil
        observations[item.id] = nil
        resumeData[item.id] = nil
        try? FileManager.default.removeItem(at: item.fileURL)
        items.removeAll { $0.id == item.id }
        persistAndNotify()
    }

    /// Clear finished rows. The files stay on disk — they're the user's now, and
    /// live in the Files app where deleting them is their call.
    func clearCompleted() {
        items.removeAll { $0.state == .completed }
        persistAndNotify()
    }

    /// Drop every row, in flight or not. For Shred App Data.
    ///
    /// Anything still transferring is cancelled first: a download that kept
    /// writing after the list it belonged to was erased would put the record
    /// back the moment it finished.
    ///
    /// The files stay, for the same reason `clearCompleted` leaves them. What
    /// is being erased here is the browser's memory of the session, and a file
    /// already saved into Files is not that — it is a document the user has,
    /// and deleting somebody's documents is not something a Clear button in a
    /// browser should do quietly.
    func clearAll() {
        for download in live.values { download.cancel { _ in } }
        live.removeAll()
        observations.removeAll()
        resumeData.removeAll()
        items.removeAll()
        persistAndNotify()
    }

    // MARK: - Progress

    private func observeProgress(of download: WKDownload, id: UUID) {
        observations[id] = download.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let idx = self.items.firstIndex(where: { $0.id == id }) else { return }
                self.items[idx].bytesReceived = progress.completedUnitCount
                self.items[idx].bytesExpected = progress.totalUnitCount
                // Progress ticks constantly; notify without hitting the disk.
                NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
            }
        }
    }

    private func persistAndNotify() {
        DownloadStore.save(items)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    private func item(for download: WKDownload) -> Int? {
        guard let id = itemID[ObjectIdentifier(download)] else { return nil }
        return items.firstIndex { $0.id == id }
    }
}

// MARK: - WKDownloadDelegate

extension DownloadManager: WKDownloadDelegate {

    /// WebKit asks where to put the file. The URL must not already exist, and the
    /// directory must — both are our job.
    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let destination = DownloadStore.uniqueURL(for: suggestedFilename)
        if let idx = item(for: download) {
            items[idx].filename = destination.lastPathComponent
            if response.expectedContentLength > 0 {
                items[idx].bytesExpected = response.expectedContentLength
            }
            persistAndNotify()
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let idx = item(for: download) else { return }
        let id = items[idx].id
        items[idx].state = .completed
        items[idx].errorMessage = nil
        // A finished file reports its real size even when the server never sent
        // a Content-Length.
        if let size = try? FileManager.default.attributesOfItem(
            atPath: items[idx].fileURL.path)[.size] as? Int64 {
            items[idx].bytesReceived = size
            items[idx].bytesExpected = size
        }
        cleanUp(download, id: id)
        persistAndNotify()
    }

    func download(_ download: WKDownload,
                  didFailWithError error: Error,
                  resumeData: Data?) {
        guard let idx = item(for: download) else { return }
        let id = items[idx].id
        items[idx].state = .failed
        items[idx].errorMessage = (error as NSError).localizedDescription
        cleanUp(download, id: id)
        persistAndNotify()

        guard Settings.autoRetryDownloads else { return }
        let attempts = retryCount[id, default: 0]
        guard attempts < maxAutoRetries else { return }
        retryCount[id] = attempts + 1
        // Give the network a moment before trying again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, let item = self.items.first(where: { $0.id == id }) else { return }
            self.retry(item)
        }
    }

    /// A redirect that lands on a different host still belongs to the same row.
    func download(_ download: WKDownload,
                  willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest,
                  decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        decisionHandler(.allow)
    }

    private func cleanUp(_ download: WKDownload, id: UUID) {
        itemID[ObjectIdentifier(download)] = nil
        observations[id] = nil
        live[id] = nil
    }
}
