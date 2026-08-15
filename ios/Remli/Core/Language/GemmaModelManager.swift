import Combine
import Foundation

/// Where the 2.58 GB of Gemma weights are, from the app's point of view.
enum ModelAvailability: Equatable {
    /// Not on disk and not being fetched.
    case absent
    /// Downloading. `progress` is 0...1, or -1 when the server did not send a content length.
    case downloading(progress: Double)
    case ready(URL)
    case failed(reason: String)

    var readyURL: URL? {
        if case .ready(let url) = self { return url }
        return nil
    }

    var isReady: Bool { readyURL != nil }

    /// One line for the status strip / settings row.
    var statusDescription: String {
        switch self {
        case .absent:
            return "Gemma weights are not on this phone yet"
        case .downloading(let progress):
            guard progress >= 0 else { return "Downloading Gemma weights…" }
            return "Downloading Gemma weights — \(Int(progress * 100))%"
        case .ready:
            return "Gemma weights ready on this phone"
        case .failed(let reason):
            return "Gemma weights unavailable: \(reason)"
        }
    }
}

/// Finds, stages, and (if it must) downloads the `.litertlm` weights.
///
/// Resolution order, cheapest first:
///
/// 1. **Already staged** in Application Support. The steady state after the first run.
/// 2. **Developer-dropped** into the app container's Documents directory. This is the demo path:
///    with `UIFileSharingEnabled`, a Mac can drop the 2.58 GB file straight into the container in
///    Finder or Xcode's device window, and the app promotes it into Application Support on next
///    launch. No 2.58 GB download over conference wifi thirty minutes before a demo.
/// 3. **Resumable background download** from Hugging Face, with progress.
///
/// Storage rules, both non-negotiable for a product that promises PHI never leaves the phone —
/// the weights are not PHI, but a 2.58 GB file syncing to iCloud is a support incident either way:
/// `.completeFileProtection` and `isExcludedFromBackup`.
final class GemmaModelManager: NSObject, ObservableObject {

    static let shared = GemmaModelManager()

    // MARK: - Where the weights live

    /// Hugging Face repository holding the LiteRT-LM build of Gemma 4 E2B.
    ///
    /// **To update this:** open https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm,
    /// click "Files and versions", and copy the exact `.litertlm` filename into `remoteFileName`
    /// below. Hugging Face `resolve/main/<file>` URLs are stable per filename, but the community
    /// repos do re-publish under new quantisation suffixes, so the filename — not the host — is
    /// the fragile part. If the repo is gated behind the Gemma licence, set
    /// `authorizationToken` to a read-scoped HF token after accepting the terms in a browser.
    static let repositoryID = "litert-community/gemma-4-E2B-it-litert-lm"
    static let remoteFileName = "gemma-4-E2B-it.litertlm"

    /// Approximate on-disk size published for this build (2.58 GB).
    ///
    /// Used as a sanity band, not a checksum: we accept anything inside `acceptedByteRange`, which
    /// catches the two failures that actually happen — a truncated download and an HTML error page
    /// saved with a `.litertlm` extension. After the first file passes the band, its exact size is
    /// pinned in `UserDefaults` and every later launch is checked against that exact number, so
    /// silent corruption after the fact is caught too. A real content hash would be better; we do
    /// not have one we can pin honestly without downloading the file first.
    static let approximateByteCount: Int64 = 2_580_000_000
    static let acceptedByteRange: ClosedRange<Int64> = 2_300_000_000...2_900_000_000
    private static let pinnedSizeDefaultsKey = "remli.gemma.pinnedByteCount"

    /// Optional Hugging Face read token, if the repo requires licence acceptance.
    var authorizationToken: String?

    var downloadURL: URL? {
        URL(string: "https://huggingface.co/\(Self.repositoryID)/resolve/main/\(Self.remoteFileName)?download=true")
    }

    // MARK: - Published state

    @Published private(set) var availability: ModelAvailability = .absent
    @Published private(set) var bytesReceived: Int64 = 0
    @Published private(set) var bytesExpected: Int64 = 0

    // MARK: - Internals

    private let fileManager = FileManager.default
    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    /// Kept so an interrupted download resumes from where it stopped rather than from zero.
    private var resumeData: Data?

    private let sessionIdentifier = "app.remli.Remli.gemma-download"

    /// Set by the app delegate for background-session completion, if wired up.
    var backgroundCompletionHandler: (() -> Void)?

    override init() {
        super.init()
        _ = refresh()
    }

    // MARK: - Paths

    var stagedURL: URL? {
        guard let support = try? fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let directory = support.appendingPathComponent("Models", isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent(Self.remoteFileName)
    }

    /// Where a developer drops the file by hand for a demo.
    var developerDropURL: URL? {
        guard let documents = try? fileManager.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) else { return nil }
        return documents.appendingPathComponent(Self.remoteFileName)
    }

    private var resumeDataURL: URL? {
        stagedURL?.deletingLastPathComponent().appendingPathComponent("gemma-download.resume")
    }

    // MARK: - Resolution

    /// Steps 1 and 2 only. Never touches the network, so it is safe to call on launch.
    @discardableResult
    func refresh() -> ModelAvailability {
        if case .downloading = availability { return availability }

        if let staged = stagedURL, fileManager.fileExists(atPath: staged.path) {
            if let problem = validate(staged) {
                setAvailability(.failed(reason: problem))
                return availability
            }
            applyProtection(to: staged)
            setAvailability(.ready(staged))
            return availability
        }

        if let dropped = developerDropURL, fileManager.fileExists(atPath: dropped.path) {
            if let problem = validate(dropped) {
                setAvailability(.failed(reason: problem))
                return availability
            }
            // Promote it out of Documents: Documents is user-visible, backed up by default, and
            // the wrong home for 2.58 GB of read-only weights.
            if let staged = stagedURL, (try? fileManager.moveItem(at: dropped, to: staged)) != nil {
                applyProtection(to: staged)
                setAvailability(.ready(staged))
            } else {
                applyProtection(to: dropped)
                setAvailability(.ready(dropped))
            }
            return availability
        }

        setAvailability(.absent)
        return availability
    }

    /// Convenience for callers that only want a usable file, without triggering a download.
    var readyModelURL: URL? { refresh().readyURL }

    // MARK: - Download

    /// Step 3. Idempotent: calling it while a download is in flight does nothing.
    func startDownload() {
        if case .downloading = availability { return }
        if refresh().isReady { return }

        guard let url = downloadURL else {
            setAvailability(.failed(reason: "The download URL is malformed. Check repositoryID and remoteFileName."))
            return
        }

        let configuration = URLSessionConfiguration.background(withIdentifier: sessionIdentifier)
        // A 2.58 GB download the user is actively waiting on. Discretionary scheduling would let
        // the system defer it until the phone is charging, which is exactly wrong here.
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = true
        let session = self.session ?? URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session

        // The only network egress in the app, and until now the only thing stopping it going
        // somewhere else was a comment. ARCHITECTURE.md claims EgressPolicy "gates all URLSession
        // use"; this is the line that makes that true rather than aspirational.
        EgressPolicy.assertNoPHI(url)
        do {
            try EgressPolicy.requireAllowed(url)
        } catch {
            setAvailability(.failed(reason: "Refused to contact \(url.host ?? "an unlisted host")."))
            return
        }

        let task: URLSessionDownloadTask
        if let resumeData = loadResumeData() {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: url)
            if let token = authorizationToken, !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            task = session.downloadTask(with: request)
        }

        downloadTask = task
        setAvailability(.downloading(progress: -1))
        task.resume()
    }

    /// Stops the download, keeping resume data so `startDownload()` picks up where it left off.
    func pauseDownload() {
        guard let task = downloadTask else { return }
        task.cancel(byProducingResumeData: { [weak self] data in
            self?.storeResumeData(data)
            self?.publish { self?.availability = .absent }
        })
        downloadTask = nil
    }

    /// Abandons the download and throws away resume data.
    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        clearResumeData()
        publish { self.availability = .absent }
    }

    /// Deletes every known copy of the weights. Frees the storage and degrades to `ScriptedModel`.
    func deleteModel() throws {
        let candidates = [availability.readyURL, stagedURL, developerDropURL]
        let modelURLs = Set(candidates.compactMap { $0?.standardizedFileURL })
        var firstError: Error?

        for url in modelURLs where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                if firstError == nil { firstError = error }
            }
        }

        if let firstError {
            _ = refresh()
            throw firstError
        }

        UserDefaults.standard.removeObject(forKey: Self.pinnedSizeDefaultsKey)
        clearResumeData()
        setAvailability(.absent)
    }

    // MARK: - Validation and storage attributes

    /// Returns a human-readable problem, or nil when the file looks right.
    private func validate(_ url: URL) -> String? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return "Could not read the model file's size."
        }
        let byteCount = size.int64Value

        if let pinned = pinnedByteCount, byteCount != pinned {
            return "The model file is \(byteCount) bytes; it was \(pinned) bytes when it was verified."
        }
        guard Self.acceptedByteRange.contains(byteCount) else {
            return "The model file is \(byteCount) bytes, which is outside the expected range for \(Self.remoteFileName)."
        }
        if pinnedByteCount == nil { pinnedByteCount = byteCount }
        return nil
    }

    private var pinnedByteCount: Int64? {
        get {
            let value = UserDefaults.standard.object(forKey: Self.pinnedSizeDefaultsKey) as? NSNumber
            return value?.int64Value
        }
        set {
            if let newValue {
                UserDefaults.standard.set(NSNumber(value: newValue), forKey: Self.pinnedSizeDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.pinnedSizeDefaultsKey)
            }
        }
    }

    /// File protection plus backup exclusion. Both are best-effort by design: a failure here must
    /// not stop the demo, but it must be visible, so it is reflected in `availability` only when
    /// it is a hard failure.
    private func applyProtection(to url: URL) {
        #if canImport(UIKit)
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #endif
        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(resourceValues)
    }

    // MARK: - Resume data

    private func storeResumeData(_ data: Data?) {
        resumeData = data
        guard let data, let url = resumeDataURL else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadResumeData() -> Data? {
        if let resumeData { return resumeData }
        guard let url = resumeDataURL, let data = try? Data(contentsOf: url) else { return nil }
        resumeData = data
        return data
    }

    private func clearResumeData() {
        resumeData = nil
        if let url = resumeDataURL { try? fileManager.removeItem(at: url) }
    }

    // MARK: - Publishing

    private func setAvailability(_ value: ModelAvailability) {
        publish { self.availability = value }
    }

    private func publish(_ work: @escaping () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.async(execute: work)
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension GemmaModelManager: URLSessionDownloadDelegate {

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Self.approximateByteCount
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : -1.0
        publish {
            self.bytesReceived = totalBytesWritten
            self.bytesExpected = expected
            self.availability = .downloading(progress: progress)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let staged = stagedURL else {
            setAvailability(.failed(reason: "No writable Application Support directory."))
            return
        }
        // The temp file disappears when this method returns, so the move must happen here, inline.
        do {
            if fileManager.fileExists(atPath: staged.path) {
                try fileManager.removeItem(at: staged)
            }
            try fileManager.moveItem(at: location, to: staged)
        } catch {
            setAvailability(.failed(reason: "Could not save the model file: \(error.localizedDescription)"))
            return
        }

        if let problem = validate(staged) {
            // A truncated file or an HTML error page. Delete it rather than leaving something that
            // will fail confusingly inside LiteRT-LM later.
            try? fileManager.removeItem(at: staged)
            setAvailability(.failed(reason: problem))
            return
        }

        applyProtection(to: staged)
        clearResumeData()
        setAvailability(.ready(staged))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            storeResumeData(data)
        }
        downloadTask = nil
        if (error as? URLError)?.code == .cancelled { return }
        setAvailability(.failed(reason: error.localizedDescription))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        publish {
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
