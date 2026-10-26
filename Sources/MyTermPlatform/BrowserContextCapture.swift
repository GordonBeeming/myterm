import AppKit
import Foundation
@preconcurrency import WebKit

public struct BrowserContextCapture: Sendable {
    public let url: URL
    public let title: String
    public let selectedText: String
    public let screenshotPNG: Data

    public init(url: URL, title: String, selectedText: String, screenshotPNG: Data) {
        self.url = url
        self.title = title
        self.selectedText = selectedText
        self.screenshotPNG = screenshotPNG
    }

    public func draft(screenshotPath: String? = nil) -> String {
        var parts = ["Page: \(url.absoluteString)", "Title: \(title)"]
        if !selectedText.isEmpty { parts.append("Selected page text:\n\(selectedText)") }
        if let screenshotPath { parts.append("Screenshot file on this Mac (read this image): \(screenshotPath)") }
        return parts.joined(separator: "\n\n")
    }
}

public enum BrowserContextCaptureError: LocalizedError {
    case unavailable, changedPage, invalidSnapshot

    public var errorDescription: String? {
        switch self {
        case .unavailable: "Open a page before capturing browser context."
        case .changedPage: "The page changed during capture. Capture it again before sending context."
        case .invalidSnapshot: "This page could not produce a usable screenshot."
        }
    }
}

@MainActor
public extension BrowserSessionController {
    func captureContext() async throws -> BrowserContextCapture {
        guard let url = webView.url, ["http", "https", "file"].contains(url.scheme ?? ""),
              !webView.bounds.isEmpty else { throw BrowserContextCaptureError.unavailable }
        let title = String((webView.title ?? "Untitled page").prefix(512))
        // An isolated world avoids invoking a page's replacement getSelection function. Only the
        // selection is collected; input values, cookies and a whole-document dump are excluded.
        let selectionCompletion = BrowserCaptureCompletion<String>()
        let selection = try await withCheckedThrowingContinuation { continuation in
            selectionCompletion.start(continuation)
            webView.evaluateJavaScript(
                "String(window.getSelection()?.toString() ?? '').slice(0, 8192)",
                in: nil, in: .defaultClient
            ) { result in
                selectionCompletion.finish(result.map { $0 as? String ?? "" })
            }
        }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: min(webView.bounds.width, 1600))
        let imageCompletion = BrowserCaptureCompletion<Data>()
        let png = try await withCheckedThrowingContinuation { continuation in
            imageCompletion.start(continuation)
            webView.takeSnapshot(with: configuration) { image, error in
                if let error { imageCompletion.finish(.failure(error)) }
                else if let image, let tiff = image.tiffRepresentation,
                        let bitmap = NSBitmapImageRep(data: tiff),
                        let png = bitmap.representation(using: .png, properties: [:]),
                        !png.isEmpty, png.count <= 8 * 1_024 * 1_024 {
                    imageCompletion.finish(.success(png))
                }
                else { imageCompletion.finish(.failure(BrowserContextCaptureError.invalidSnapshot)) }
            }
        }
        guard webView.url == url else { throw BrowserContextCaptureError.changedPage }
        return BrowserContextCapture(url: url, title: title,
                                     selectedText: selection, screenshotPNG: png)
    }
}

@MainActor
private final class BrowserCaptureCompletion<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var deadline: Task<Void, Never>?

    func start(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) }
            catch { return }
            self?.finish(.failure(URLError(.timedOut)))
        }
    }

    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        deadline?.cancel()
        deadline = nil
        continuation.resume(with: result)
    }
}
