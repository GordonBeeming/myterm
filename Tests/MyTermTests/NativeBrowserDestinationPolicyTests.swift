import XCTest
@testable import MyTerm

final class NativeBrowserDestinationPolicyTests: XCTestCase {
    func testPublicAndProhibitedAddressClasses() {
        for address in ["8.8.8.8", "1.1.1.1", "93.184.216.34", "2606:4700:4700::1111", "2001:4860:4860::8888"] {
            XCTAssertTrue(NativeBrowserDestinationPolicy.isPublic(address), address)
        }
        for address in ["0.0.0.0", "0.1.2.3", "10.0.0.1", "100.64.0.1", "127.0.0.1", "169.254.169.254", "172.16.0.1", "172.31.255.255", "192.168.0.1", "192.0.0.1", "192.0.2.1", "198.18.0.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255", "::", "::1", "::ffff:127.0.0.1", "::ffff:8.8.8.8", "fc00::1", "fe80::1", "ff02::1", "2001:db8::1", "2001::1", "2002:0808:0808::1", "3ffe::1", "3fff::1", "localhost", "8.8.8.8%en0"] {
            XCTAssertFalse(NativeBrowserDestinationPolicy.isPublic(address), address)
        }
    }

    func testMixedAnswersAndLocalInterfaceAddressesAreRejected() async throws {
        for answers in [["8.8.8.8", "127.0.0.1"], ["8.8.8.8", "192.168.0.1"], ["2606:4700::1", "::ffff:169.254.169.254"]] {
            let policy = NativeBrowserDestinationPolicy(lookup: { _ in answers }, interfaces: { [] })
            do { _ = try await policy.resolve(host: "attacker.example", port: 443); XCTFail("Mixed DNS answers accepted") }
            catch NativeBrowserDestinationPolicy.Rejection.prohibitedAddress { }
        }
        let local = NativeBrowserDestinationPolicy(lookup: { _ in ["8.8.8.8"] }, interfaces: { ["8.8.8.8"] })
        do { _ = try await local.resolve(host: "public.example", port: 443); XCTFail("Local interface accepted") }
        catch NativeBrowserDestinationPolicy.Rejection.prohibitedAddress { }
    }

    func testNumericPinAndRevalidationPreventRebinding() async throws {
        actor Answers {
            var calls = 0
            func lookup() -> [String] {
                calls += 1
                return calls == 1 ? ["8.8.8.8"] : ["127.0.0.1"]
            }
        }
        let answers = Answers()
        let policy = NativeBrowserDestinationPolicy(lookup: { _ in await answers.lookup() }, interfaces: { [] })
        let vetted = try await policy.resolve(host: "rebind.example", port: 443)
        XCTAssertEqual(vetted.0, "8.8.8.8", "The socket must use this numeric pin, never the hostname")
        XCTAssertEqual(vetted.1, 443)
        let firstCount = await answers.calls
        XCTAssertEqual(firstCount, 1)
        do { _ = try await policy.resolve(host: "rebind.example", port: 443); XCTFail("Rebound private address accepted") }
        catch NativeBrowserDestinationPolicy.Rejection.prohibitedAddress { }
        let secondCount = await answers.calls
        XCTAssertEqual(secondCount, 2)
    }
}
