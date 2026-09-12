import Foundation
import XCTest
@testable import MyTermRemoteProtocol

/// Findings from the phone-input round that are left open on purpose. Each of these fails today
/// and says what a fix would have to make true.
final class PhoneInputOpenFindingsTests: XCTestCase {
    /// Two Macs on two networks can both be called "Mac Studio". Scanning the second one's code
    /// today finds the first by that name and overwrites its address and token, so the first Mac
    /// is gone from the list without anybody removing it. A name should only stand in for an
    /// address when the address is not known, or matches.
    func testTwoDifferentMacsWithTheSameNameStayTwoEntries() {
        let (afterFirst, home) = SavedConnectionList.upserting(
            host: "10.0.0.5", port: 8765, displayName: nil, serviceName: "Mac Studio", into: []
        )
        XCTAssertEqual(home.displayName, "Mac Studio")

        let (afterSecond, office) = SavedConnectionList.upserting(
            host: "192.168.4.20", port: 8765, displayName: nil, serviceName: "Mac Studio", into: afterFirst
        )

        XCTAssertEqual(afterSecond.count, 2, "a Mac at a different address with the same name is another Mac")
        XCTAssertNotEqual(office.id, home.id)
        XCTAssertEqual(afterSecond.first?.host, "10.0.0.5", "the first Mac keeps its address")
    }
}
