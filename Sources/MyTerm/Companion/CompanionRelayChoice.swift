import Foundation
import MyTermCore
import MyTermRemote

enum CompanionRelayChoice: Hashable, CaseIterable {
    case development, beta, production, selfHosted, setupLink

    var title: String {
        switch self {
        case .development: MyTermHostedRelay.development.title
        case .beta: MyTermHostedRelay.beta.title
        case .production: MyTermHostedRelay.production.title
        case .selfHosted: "Self-hosted"
        case .setupLink: "Use a setup link"
        }
    }

    var origin: String? {
        switch self {
        case .development: MyTermHostedRelay.development.origin
        case .beta: MyTermHostedRelay.beta.origin
        case .production: MyTermHostedRelay.production.origin
        case .selfHosted, .setupLink: nil
        }
    }

    static func choices(channel: MyTermChannel, release: UpdateCheck.Channel) -> [Self] {
        switch (channel, release) {
        case (.development, _): [.development, .beta, .production, .selfHosted, .setupLink]
        case (.production, .beta): [.beta, .production, .selfHosted, .setupLink]
        case (.production, .stable): [.production, .beta, .selfHosted, .setupLink]
        }
    }

    static func initial(savedAddress: String, choices: [Self]) -> Self {
        let address = savedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return choices.first ?? .selfHosted }
        guard let url = URL(string: address), let endpoint = try? RelayEndpoint(url) else { return .selfHosted }
        return choices.first { $0.origin == endpoint.canonicalOrigin } ?? .selfHosted
    }
}
