import Foundation
import Network
import WebKit

#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor private final class RouteNavigation: NSObject, WKNavigationDelegate {
    var finished = false
    var status = 0
    var error: NSError?

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        status = (response.response as? HTTPURLResponse)?.statusCode ?? 0
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error as NSError
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error as NSError
    }
}

@MainActor private func measure() async throws -> Data {
    let environment = ProcessInfo.processInfo.environment
    guard let endpointText = environment["MYTERM_PRIVATE_PROXY"], let endpoint = URL(string: endpointText),
          let privateName = environment["MYTERM_PRIVATE_NAME"], let privateIP = environment["MYTERM_PRIVATE_IP"],
          let originPort = environment["MYTERM_PRIVATE_ORIGIN_PORT"].flatMap(UInt16.init) else {
        throw NSError(domain: "Missing route fixture configuration", code: 1)
    }

    var results: [[String: Any]] = []
    for (kind, host) in [("private-name", privateName), ("private-ip", privateIP),
                         ("unapproved-name", "not-approved.myterm.test")] {
        guard let target = URL(string: "http://\(host):\(originPort)/private-route") else {
            throw NSError(domain: "Invalid fixture address", code: 2)
        }
        var relay = ProxyConfiguration(relayHops: [.init(http2RelayEndpoint: .url(endpoint))])
        relay.allowFailover = false
        let store = WKWebsiteDataStore.nonPersistent()
        store.proxyConfigurations = [relay]
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        let browser = WKWebView(frame: .zero, configuration: configuration)
        let navigation = RouteNavigation()
        browser.navigationDelegate = navigation
        browser.load(URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5))
        let deadline = ContinuousClock.now + .seconds(7)
        while !navigation.finished && navigation.error == nil && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(35))
        }
        results.append([
            "target": kind, "title": browser.title ?? "", "finished": navigation.finished, "httpStatus": navigation.status,
            "error": navigation.error?.code ?? 0,
            "underlyingError": (navigation.error?.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? 0
        ])
        browser.stopLoading()
        browser.navigationDelegate = nil
    }
    return try JSONSerialization.data(withJSONObject: [
        "clientOS": ProcessInfo.processInfo.operatingSystemVersionString, "routes": results
    ], options: [.sortedKeys, .prettyPrinted])
}

#if os(iOS)
@main final class PrivateRouteApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = PrivateRouteScene.self
        return configuration
    }
}

final class PrivateRouteScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        self.window = window
        window.makeKeyAndVisible()
        Task {
            let output = URL.documentsDirectory.appendingPathComponent("private-routes.json")
            do {
                let data = try await measure()
                try data.write(to: output, options: .atomic)
            } catch {
                fputs("Private route fixture failed: \(error)\n", stderr)
            }
        }
    }
}
#else
@main struct DesktopPrivateRouteProbe {
    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        do {
            let data = try await measure()
            print(String(decoding: data, as: UTF8.self))
        } catch {
            fputs("Private route fixture failed: \(error)\n", stderr)
            exit(1)
        }
    }
}
#endif
