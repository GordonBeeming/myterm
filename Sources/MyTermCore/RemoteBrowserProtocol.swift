import Foundation

public enum RemoteBrowserAction: String, Codable, Sendable {
    case open, snapshot, navigate, back, forward, reload, tap, scroll, text, key, close
}
public enum RemoteBrowserKey: String, Codable, Sendable {
    case enter, backspace, tab, escape, arrowUp, arrowDown, arrowLeft, arrowRight
}
public enum RemoteBrowserValidationError: Error, Sendable { case invalidRequest, invalidFrame }

public struct RemoteBrowserRequest: Codable, Equatable, Sendable {
    public static let capability = "browser-render-v1"
    public let rendererID: UUID?
    public let action: RemoteBrowserAction
    public let width: Int
    public let height: Int
    public let url: String?
    public let x: Double?
    public let y: Double?
    public let deltaX: Double?
    public let deltaY: Double?
    public let text: String?
    public let key: RemoteBrowserKey?
    public init(
        action: RemoteBrowserAction, rendererID: UUID? = nil, width: Int = 1024, height: Int = 768,
        url: String? = nil, x: Double? = nil, y: Double? = nil,
        deltaX: Double? = nil, deltaY: Double? = nil,
        text: String? = nil, key: RemoteBrowserKey? = nil
    ) throws {
        self.rendererID = rendererID
        self.action = action
        self.width = width
        self.height = height
        self.url = url
        self.x = x
        self.y = y
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.text = text
        self.key = key
        try validate()
    }
    public func validate() throws {
        guard (320...1600).contains(width), (240...1200).contains(height),
            url.map({ $0.utf8.count <= 8192 }) ?? true,
            text.map({ $0.utf8.count <= 4096 }) ?? true,
            [x, y].allSatisfy({ $0.map { $0.isFinite && (0...1).contains($0) } ?? true }),
            [deltaX, deltaY].allSatisfy({
                $0.map { $0.isFinite && (-2000...2000).contains($0) } ?? true
            })
        else {
            throw RemoteBrowserValidationError.invalidRequest
        }
        switch action {
        case .navigate:
            guard let url, !url.isEmpty, x == nil, y == nil, deltaX == nil, deltaY == nil,
                text == nil,
                key == nil
            else { throw RemoteBrowserValidationError.invalidRequest }
        case .tap:
            guard x != nil, y != nil, url == nil, deltaX == nil, deltaY == nil, text == nil,
                key == nil
            else { throw RemoteBrowserValidationError.invalidRequest }
        case .scroll:
            guard deltaX != nil, deltaY != nil, x == nil, y == nil, url == nil, text == nil,
                key == nil
            else { throw RemoteBrowserValidationError.invalidRequest }
        case .text:
            guard let text, !text.isEmpty, url == nil, x == nil, y == nil, deltaX == nil,
                deltaY == nil,
                key == nil
            else { throw RemoteBrowserValidationError.invalidRequest }
        case .key:
            guard key != nil, url == nil, x == nil, y == nil, deltaX == nil, deltaY == nil,
                text == nil
            else { throw RemoteBrowserValidationError.invalidRequest }
        case .open:
            guard x == nil, y == nil, deltaX == nil, deltaY == nil, text == nil, key == nil else {
                throw RemoteBrowserValidationError.invalidRequest
            }
        case .snapshot, .back, .forward, .reload, .close:
            guard url == nil, x == nil, y == nil, deltaX == nil, deltaY == nil, text == nil,
                key == nil
            else { throw RemoteBrowserValidationError.invalidRequest }
        }
    }
    enum CodingKeys: String, CodingKey {
        case action, rendererID, width, height, url, x, y, deltaX, deltaY, text, key
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            action: c.decode(RemoteBrowserAction.self, forKey: .action),
            rendererID: c.decodeIfPresent(UUID.self, forKey: .rendererID),
            width: c.decode(Int.self, forKey: .width), height: c.decode(Int.self, forKey: .height),
            url: c.decodeIfPresent(String.self, forKey: .url),
            x: c.decodeIfPresent(Double.self, forKey: .x),
            y: c.decodeIfPresent(Double.self, forKey: .y),
            deltaX: c.decodeIfPresent(Double.self, forKey: .deltaX),
            deltaY: c.decodeIfPresent(Double.self, forKey: .deltaY),
            text: c.decodeIfPresent(String.self, forKey: .text),
            key: c.decodeIfPresent(RemoteBrowserKey.self, forKey: .key))
    }
}

public struct RemoteBrowserFrame: Codable, Equatable, Sendable {
    public static let maximumImageBytes = 192 * 1024
    public let image: Data
    public let width: Int
    public let height: Int
    public let url: String
    public let title: String
    public let canGoBack: Bool
    public let canGoForward: Bool
    public let isLoading: Bool
    public let error: String?
    public init(
        image: Data, width: Int, height: Int, url: String, title: String,
        canGoBack: Bool, canGoForward: Bool, isLoading: Bool, error: String? = nil
    ) throws {
        guard image.count <= Self.maximumImageBytes, (1...1600).contains(width),
            (1...1200).contains(height),
            url.utf8.count <= 8192, title.utf8.count <= 4096, (error?.utf8.count ?? 0) <= 2048
        else { throw RemoteBrowserValidationError.invalidFrame }
        self.image = image
        self.width = width
        self.height = height
        self.url = url
        self.title = title
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isLoading = isLoading
        self.error = error
    }
    enum CodingKeys: String, CodingKey {
        case image, width, height, url, title, canGoBack, canGoForward, isLoading, error
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            image: c.decode(Data.self, forKey: .image), width: c.decode(Int.self, forKey: .width),
            height: c.decode(Int.self, forKey: .height), url: c.decode(String.self, forKey: .url),
            title: c.decode(String.self, forKey: .title),
            canGoBack: c.decode(Bool.self, forKey: .canGoBack),
            canGoForward: c.decode(Bool.self, forKey: .canGoForward),
            isLoading: c.decode(Bool.self, forKey: .isLoading),
            error: c.decodeIfPresent(String.self, forKey: .error))
    }
}
