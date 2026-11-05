import Foundation

/// URLSession delivers chunks on its delegate queue. The lock also covers task cancellation,
/// which may arrive before startup or concurrently with a delegate callback.
final class ReleaseDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let destination: URL
    private let maximumBytes: Int
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var output: FileHandle?
    private var received = 0
    private var cancelled = false
    private var finished = false

    /// Create a cookie-free download with explicit byte and network deadlines.
    init(url: URL, destination: URL, maximumBytes: Int = 512 * 1_024 * 1_024,
         configuration: URLSessionConfiguration = .ephemeral) {
        self.url = url
        self.destination = destination
        self.maximumBytes = maximumBytes
        self.configuration = configuration
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
    }

    /// Bridge chunked delegate delivery to one cancellation-aware asynchronous operation.
    func download() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { start($0) }
        } onCancel: { cancel() }
    }

    /// Create the private output file and resume the download exactly once under the state lock.
    private func start(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        guard self.continuation == nil, !finished else {
            lock.unlock()
            continuation.resume(throwing: ApplicationUpdateError.invalid("A release download cannot be started twice."))
            return
        }
        self.continuation = continuation
        guard !cancelled else { lock.unlock(); finish(CancellationError()); return }
        do {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw ApplicationUpdateError.invalid("Could not create the private update download.")
            }
            output = try FileHandle(forWritingTo: destination)
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            let task = session.dataTask(with: url)
            lock.unlock()
            task.resume()
        } catch { lock.unlock(); finish(error) }
    }

    /// Remember cancellation even when it arrives before the asynchronous continuation is installed.
    private func cancel() {
        lock.lock()
        cancelled = true
        let started = continuation != nil
        lock.unlock()
        if started { finish(CancellationError()) }
    }

    /// Close the file, invalidate the session and resume the continuation once across completion and cancellation races.
    private func finish(_ error: Error?) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        let output = self.output, session = self.session
        self.output = nil
        self.session = nil
        lock.unlock()
        var failure = error
        do { try output?.close() }
        catch {
            failure = ApplicationUpdateError.invalid("\(failure?.localizedDescription ?? "Download completed"). Could not close the update file: \(error.localizedDescription)")
        }
        session?.invalidateAndCancel()
        if let failure { continuation.resume(throwing: failure) }
        else { continuation.resume() }
    }

    /// Reject failed responses and advertised sizes above the archive limit before accepting bytes.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(ApplicationUpdateError.invalid("The release download failed or exceeded its size limit."))
            return
        }
        completionHandler(.allow)
    }

    /// Write each chunk under the state lock and enforce the cap even when content length is unknown.
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        do {
            guard data.count <= maximumBytes - received, let output else {
                throw ApplicationUpdateError.invalid("The release download exceeded its size limit.")
            }
            try output.write(contentsOf: data)
            received += data.count
            lock.unlock()
        } catch { lock.unlock(); finish(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { finish(error) }

    /// Allow only HTTPS redirects to GitHub and its artifact download hosts.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let url = request.url, url.scheme == "https", let host = url.host,
              host == "github.com" || host.hasSuffix(".githubusercontent.com") else {
            completionHandler(nil)
            finish(ApplicationUpdateError.invalid("The update redirected outside GitHub's secure download hosts."))
            return
        }
        completionHandler(request)
    }
}
