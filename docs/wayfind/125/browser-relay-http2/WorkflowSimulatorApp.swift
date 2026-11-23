import Foundation
import Security
import UIKit

@main final class WorkflowApplication: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        configuration.delegateClass = WorkflowScene.self
        return configuration
    }
}

final class WorkflowScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        self.window = window
        window.makeKeyAndVisible()

        Task {
            let environment = ProcessInfo.processInfo.environment
            let mode = environment["MYTERM_WORKFLOW_MODE"] ?? ""
            let output = URL.documentsDirectory.appendingPathComponent("workflow-\(mode).json")
            do {
                let result = try await run(mode: mode, environment: environment)
                let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
                try data.write(to: output, options: .atomic)
            } catch {
                let result = ["probeError": String(describing: error)]
                do {
                    let data = try JSONSerialization.data(withJSONObject: result)
                    try data.write(to: output, options: .atomic)
                } catch {
                    fputs("Unable to write workflow fixture error: \(error)\n", stderr)
                }
            }
        }
    }

    private func run(mode: String, environment: [String: String]) async throws -> [String: Any] {
        guard let relay = environment["MYTERM_WORKFLOW_RELAY_PORT"].flatMap(UInt16.init),
              let origin = environment["MYTERM_WORKFLOW_ORIGIN_PORT"].flatMap(UInt16.init),
              let certificatePath = Bundle.main.url(forResource: "origin", withExtension: "der"),
              let certificate = SecCertificateCreateWithData(nil, try Data(contentsOf: certificatePath) as CFData) else {
            throw NSError(domain: "Workflow fixture configuration", code: 1)
        }
        let exception = ApprovedOrigin(server: "A", host: "myterm-route-probe.invalid", port: Int(origin),
                                       certificate: certificate)
        switch mode {
        case "navigation":
            return try await NavigationWorkflowProbe.run(relayHost: "127.0.0.1", relayPort: relay,
                                                         port: origin, exception: exception)
        case "transfers":
            return try await TransferProbe.run(relayHost: "127.0.0.1", relayPort: relay,
                                               port: origin, exception: exception,
                                               directDownload: environment["MYTERM_WORKFLOW_DIRECT_DOWNLOAD"] == "1")
        default:
            throw NSError(domain: "Unknown workflow fixture mode", code: 1)
        }
    }
}
