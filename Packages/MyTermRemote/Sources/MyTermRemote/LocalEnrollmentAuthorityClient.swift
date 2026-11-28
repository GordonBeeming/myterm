#if os(macOS)
import CryptoKit
import Foundation

public actor LocalEnrollmentAuthorityClient {
    private enum Operation: String {
        case authorityIdentity = "authority-identity"
        case accountBinding = "account-binding"
        case configureAuthority = "configure-authority"
        case authorityRequest = "authority-request"
    }

    private struct AuthorityRequest: Encodable {
        let operation: String
        var request: SignedAccountEnrollment?
        var presentation: ServerEnrollmentPresentation?
        var after: Int64?
    }

    private let executable: URL
    private let stateDirectory: URL

    public init(executable: URL, stateDirectory: URL) {
        self.executable = executable
        self.stateDirectory = stateDirectory
    }

    public func bootstrap(firstClient: Curve25519.Signing.PrivateKey) throws -> EnrollmentAccountBinding {
        let client = EnrollmentSigningIdentity(firstClient.publicKey)
        let saved: EnrollmentAccountBinding? = try run(.accountBinding)
        let binding: EnrollmentAccountBinding
        if let saved {
            _ = try saved.verifiedAuthority(pinnedAnchor: saved.anchor)
            let genesis = try saved.genesis.read(EnrollmentAccountGenesis.self)
            guard genesis.firstClient == client else { throw AccountEnrollmentError.wrongAccount }
            binding = saved
        } else {
            let authority: EnrollmentSigningIdentity = try run(.authorityIdentity)
            let genesis = EnrollmentAccountGenesis(firstClient: client, authority: authority)
            binding = try EnrollmentAccountGenesis.binding(from: SignedAccountEnrollment(genesis, signer: firstClient))
        }
        let configured: String = try run(.configureAuthority, input: binding)
        guard configured == binding.anchor else { throw AccountEnrollmentError.wrongAccount }
        return binding
    }

    public func issue(_ request: SignedAccountEnrollment) throws -> SignedAccountEnrollment {
        try run(.authorityRequest, input: AuthorityRequest(operation: "issue", request: request))
    }

    public func redeem(_ presentation: ServerEnrollmentPresentation) throws -> SignedAccountEnrollment {
        try run(.authorityRequest, input: AuthorityRequest(operation: "redeem", presentation: presentation))
    }

    public func manage(_ request: SignedAccountEnrollment) throws -> SignedAccountEnrollment {
        try run(.authorityRequest, input: AuthorityRequest(operation: "manage", request: request))
    }

    public func events(after sequence: Int64) throws -> [SignedAccountEnrollment] {
        try run(.authorityRequest, input: AuthorityRequest(operation: "events", after: sequence))
    }

    private func run<T: Decodable>(_ operation: Operation, input: (any Encodable)? = nil) throws -> T {
        guard executable.isFileURL, stateDirectory.isFileURL else { throw AccountEnrollmentError.localAuthorityFailed }
        let bytes = try input.map { try JSONEncoder().encode($0) } ?? Data()
        guard bytes.count <= 96 * 1024 else { throw AccountEnrollmentError.invalidArtifact }
        let process = Process()
        let request = Pipe()
        let response = Pipe()
        process.executableURL = executable
        process.arguments = ["enrollment", operation.rawValue, stateDirectory.path]
        process.standardInput = request
        process.standardOutput = response
        try process.run()
        let writer = request.fileHandleForWriting
        do {
            try writer.write(contentsOf: bytes)
            try writer.close()
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        let result = response.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AccountEnrollmentError.localAuthorityFailed }
        return try JSONDecoder().decode(T.self, from: result)
    }
}
#endif
