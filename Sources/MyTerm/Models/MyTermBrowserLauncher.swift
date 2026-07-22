import Foundation
import MyTermCore

enum MyTermBrowserLauncher {
    static let workspaceIDEnvironmentKey = "MYTERM_WORKSPACE_ID"
    static let tabIDEnvironmentKey = "MYTERM_TAB_ID"
    static let paneIDEnvironmentKey = "MYTERM_PANE_ID"
    static let workspaceRouteScheme = "myterm"
    static let workspaceRouteHost = "browser"

    struct BrowserDestination: Equatable {
        let workspaceID: WorkspaceID
        let tabID: TabID?
        let paneID: PaneID?
        let url: URL

        init(workspaceID: WorkspaceID, tabID: TabID? = nil, paneID: PaneID? = nil, url: URL) {
            self.workspaceID = workspaceID
            self.tabID = tabID
            self.paneID = paneID
            self.url = url
        }
    }

    static func executableURL(
        resourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let candidate = resourceURL?.appending(path: "myterm-browser", directoryHint: .notDirectory),
              fileManager.isExecutableFile(atPath: candidate.path)
        else {
            return nil
        }
        return candidate
    }

    static func environment(
        executableURL: URL?,
        workspaceID: WorkspaceID? = nil,
        tabID: TabID? = nil,
        paneID: PaneID? = nil
    ) -> [String: String] {
        guard let executableURL else { return [:] }
        var environment = ["BROWSER": executableURL.path]
        if let workspaceID {
            environment[workspaceIDEnvironmentKey] = workspaceID.description
        }
        if let tabID {
            environment[tabIDEnvironmentKey] = tabID.description
        }
        if let paneID {
            environment[paneIDEnvironmentKey] = paneID.description
        }
        return environment
    }

    static func browserRoute(
        for workspaceID: WorkspaceID,
        tabID: TabID? = nil,
        paneID: PaneID? = nil,
        url: URL
    ) -> URL? {
        guard isWebURL(url) else { return nil }
        let payload = Data(url.absoluteString.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
        var components = URLComponents()
        components.scheme = workspaceRouteScheme
        components.host = workspaceRouteHost
        if let tabID, let paneID {
            components.path = "/\(workspaceID.description)/\(tabID.description)/\(paneID.description)"
        } else {
            components.path = "/\(workspaceID.description)"
        }
        components.queryItems = [URLQueryItem(name: "url", value: payload)]
        return components.url
    }

    static func browserDestination(from route: URL) -> BrowserDestination? {
        guard let components = URLComponents(url: route, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == workspaceRouteScheme,
              components.host?.lowercased() == workspaceRouteHost,
              components.port == nil,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              case let pathComponents = components.path.split(separator: "/", omittingEmptySubsequences: true),
              pathComponents.count == 1 || pathComponents.count == 3,
              components.path == "/" + pathComponents.joined(separator: "/"),
              let workspaceID = try? WorkspaceID(uuidString: String(pathComponents[0])),
              let queryItems = components.queryItems,
              queryItems.count == 1,
              queryItems[0].name == "url",
              let payload = queryItems[0].value,
              let data = Data(base64Encoded: paddedBase64(payload)),
              let urlString = String(data: data, encoding: .utf8),
              let url = URL(string: urlString),
              isWebURL(url) else {
            return nil
        }
        let tabID = pathComponents.count == 3 ? try? TabID(uuidString: String(pathComponents[1])) : nil
        let paneID = pathComponents.count == 3 ? try? PaneID(uuidString: String(pathComponents[2])) : nil
        guard pathComponents.count == 1 || (tabID != nil && paneID != nil) else { return nil }
        return BrowserDestination(workspaceID: workspaceID, tabID: tabID, paneID: paneID, url: url)
    }

    private static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else {
            return false
        }
        return true
    }

    private static func paddedBase64(_ payload: String) -> String {
        let base64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        guard remainder != 0 else { return base64 }
        return base64 + String(repeating: "=", count: 4 - remainder)
    }
}
