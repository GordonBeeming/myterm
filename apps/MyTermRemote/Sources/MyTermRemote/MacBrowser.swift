import Foundation
import MyTermRemoteProtocol
import Network
import Observation

/// Lists the Macs on this network that are running MyTerm with devices allowed.
///
/// This is how a device finds a Mac without a code in front of it, and how it keeps finding one
/// whose address has changed. It browses only while a screen is showing the result.
@MainActor
@Observable
final class MacBrowser {
    struct FoundMac: Identifiable, Equatable {
        let name: String
        var id: String { name }
    }

    private(set) var macs: [FoundMac] = []
    private(set) var isBrowsing = false

    @ObservationIgnored
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjour(type: RemoteProtocol.bonjourServiceType, domain: nil),
            using: parameters
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let names = results.compactMap { result -> String? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return name
            }
            Task { @MainActor [weak self] in
                self?.macs = Set(names).sorted().map(FoundMac.init(name:))
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                switch state {
                case .ready:
                    self?.isBrowsing = true
                case .failed, .cancelled:
                    self?.isBrowsing = false
                default:
                    break
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        isBrowsing = false
        macs = []
    }
}
