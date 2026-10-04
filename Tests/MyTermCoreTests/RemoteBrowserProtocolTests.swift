import Foundation
import Testing

@testable import MyTermCore

@Test func remoteBrowserRequestRejectsInjectedOrUnboundedInputs() throws {
    let tap = try RemoteBrowserRequest(action: .tap, rendererID: UUID(), x: 0.25, y: 0.75)
    #expect(
        try JSONDecoder().decode(RemoteBrowserRequest.self, from: JSONEncoder().encode(tap)) == tap)
    #expect(throws: RemoteBrowserValidationError.self) {
        try RemoteBrowserRequest(action: .tap, x: -.infinity, y: 0.5)
    }
    #expect(throws: RemoteBrowserValidationError.self) {
        try RemoteBrowserRequest(action: .tap, x: 1.01, y: 0.5)
    }
    #expect(throws: RemoteBrowserValidationError.self) {
        try RemoteBrowserRequest(action: .snapshot, text: "arbitrary code")
    }
    #expect(throws: RemoteBrowserValidationError.self) {
        try RemoteBrowserRequest(action: .text, text: String(repeating: "x", count: 4097))
    }
    #expect(throws: RemoteBrowserValidationError.self) {
        try RemoteBrowserRequest(action: .snapshot, width: 100_000)
    }
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(
            RemoteBrowserRequest.self,
            from: Data(#"{"action":"tap","width":1024,"height":768,"x":20,"y":0}"#.utf8))
    }
}

@Test func remoteBrowserFrameBoundsSurviveDecoding() throws {
    let frame = try RemoteBrowserFrame(
        image: Data([0xff, 0xd8, 0xff, 0xd9]), width: 800, height: 600,
        url: "http://localhost:8080/", title: "Local app",
        canGoBack: false, canGoForward: false, isLoading: false)
    #expect(
        try JSONDecoder().decode(RemoteBrowserFrame.self, from: JSONEncoder().encode(frame))
            == frame)
    #expect(throws: RemoteBrowserValidationError.self) {
        try RemoteBrowserFrame(
            image: Data(repeating: 0, count: RemoteBrowserFrame.maximumImageBytes + 1), width: 800,
            height: 600, url: "", title: "", canGoBack: false, canGoForward: false, isLoading: false
        )
    }
    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as? [String: Any])
    object["width"] = 50_000
    let invalid = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) {
        try JSONDecoder().decode(RemoteBrowserFrame.self, from: invalid)
    }
}
