import AppKit
import Foundation
import MyTermCore
import MyTermPlatform
import MyTermRemote
import XCTest
@testable import MyTerm

final class CompanionBrowserArtifactTests: XCTestCase {
    func testArtifactSiblingResourcesAndTraversalAreScoped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.html")
        try Data("<h1>Remote artifact</h1>".utf8).write(to: file)
        try Data("body{color:red}".utf8).write(to: root.appendingPathComponent("app.css"))
        let artifact = try CompanionBrowserArtifact(selectedFile: file)
        XCTAssertEqual(try artifact.read(path: "/app.css").0, Data("body{color:red}".utf8))
        XCTAssertThrowsError(try artifact.read(path: "/../secret"))
        XCTAssertThrowsError(try artifact.read(path: "/%2e%2e/secret"))
        XCTAssertThrowsError(try artifact.read(path: "/app%00.css"))
        XCTAssertThrowsError(try artifact.read(path: "/.ssh/id_rsa"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertThrowsError(try artifact.read(path: "/escape/index.html"))
        let response = artifact.response(to: Data("GET /app.css HTTP/1.1\r\nHost: myterm-artifact.invalid\r\n\r\n".utf8))
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("200 OK"))
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("script-src 'none'"))
        let rejected = artifact.response(to: Data("POST /index.html HTTP/1.1\r\n\r\n".utf8))
        XCTAssertTrue(String(decoding: rejected, as: UTF8.self).contains("405 Method Not Allowed"))
    }

    func testArtifactEndpointRequiresCapabilityAndCannotRestartAfterClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.html")
        try Data("Secure artifact".utf8).write(to: file)
        let server = CompanionBrowserArtifactServer(artifact: try CompanionBrowserArtifact(selectedFile: file),
                                                     allowsVirtualOrigin: false)
        let authorized = try await server.authorizedURL(path: "index.html")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            var bare = URLComponents(url: authorized, resolvingAgainstBaseURL: false)
            bare?.path = "/index.html"
            let bareURL = try XCTUnwrap(bare?.url)
            let (_, denied) = try await session.data(from: bareURL)
            XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 403)
            let (bytes, accepted) = try await session.data(from: authorized)
            XCTAssertEqual((accepted as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(bytes, Data("Secure artifact".utf8))
            XCTAssertEqual((accepted as? HTTPURLResponse)?.value(forHTTPHeaderField: "Referrer-Policy"), "no-referrer")
            let (_, rootResource) = try await session.data(from: bareURL)
            XCTAssertEqual((rootResource as? HTTPURLResponse)?.statusCode, 200,
                           "The HttpOnly capability cookie must authorize absolute resource paths")
            var foreign = URLRequest(url: authorized)
            foreign.setValue("http://untrusted.example", forHTTPHeaderField: "Origin")
            let (_, rejected) = try await session.data(for: foreign)
            XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 403)
            await server.close()
            do { _ = try await server.endpoint(); XCTFail("Closed artifact listeners must never restart") }
            catch is CancellationError { }
        } catch { await server.close(); throw error }
    }

    func testNativeArtifactHostCapabilityMustBeRegistered() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.html")
        try Data("Native secure artifact".utf8).write(to: file)
        let server = CompanionBrowserArtifactServer(artifact: try CompanionBrowserArtifact(selectedFile: file))
        let (_, port) = try await server.endpoint()
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/index.html"))
        let host = UUID().uuidString.lowercased() + "." + CompanionBrowserArtifact.hostname
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            var request = URLRequest(url: url)
            request.setValue(CompanionBrowserArtifact.hostname, forHTTPHeaderField: "Host")
            let (_, base) = try await session.data(for: request)
            XCTAssertEqual((base as? HTTPURLResponse)?.statusCode, 403)
            request.setValue(host, forHTTPHeaderField: "Host")
            let (_, unknown) = try await session.data(for: request)
            XCTAssertEqual((unknown as? HTTPURLResponse)?.statusCode, 403)
            try await server.registerVirtualOrigin(host)
            let (bytes, registered) = try await session.data(for: request)
            XCTAssertEqual((registered as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(bytes, Data("Native secure artifact".utf8))
            XCTAssertEqual((registered as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cross-Origin-Resource-Policy"), "same-origin")
            for _ in 0..<8 {
                try await server.registerVirtualOrigin(UUID().uuidString.lowercased() + "." + CompanionBrowserArtifact.hostname)
            }
            let (_, retired) = try await session.data(for: request)
            XCTAssertEqual((retired as? HTTPURLResponse)?.statusCode, 403,
                           "Repeated mode switches retire old capabilities without exhausting the session")
            await server.close()
        } catch { await server.close(); throw error }
    }

    func testBrowserRouteRejectsTerminalOrMissingTargets() throws {
        XCTAssertThrowsError(try CompanionBrowserRoute(MessageMetadata(hostID: UUID(), runtimeID: UUID())))
        XCTAssertThrowsError(try CompanionBrowserRoute(MessageMetadata(hostID: UUID(), runtimeID: UUID(),
            sessionID: UUID(), workspaceID: UUID(), groupID: UUID(), tabID: UUID())))
    }
}

@MainActor
final class CompanionBrowserRendererTests: XCTestCase {
    func testNativeInputReachesCrossOriginIframeWithoutActivatingWindow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("child.html")
        try Data("""
        <html><body style="margin:0;background:white"><button style="width:200px;height:100px;background:black;color:white" onclick="parent.postMessage(event.isTrusted?'Trusted iframe click':'Untrusted click','*')">Click</button><input style="position:absolute;left:0;top:120px;width:200px;height:60px" oninput="parent.postMessage((event.isTrusted?'Trusted input:':'Untrusted input:')+this.value,'*')"></body></html>
        """.utf8).write(to: child)
        let childServer = CompanionBrowserArtifactServer(artifact: try CompanionBrowserArtifact(selectedFile: child, allowsJavaScript: true), allowsVirtualOrigin: false)
        let childURL = try await childServer.authorizedURL(path: "child.html")
        let parent = root.appendingPathComponent("parent.html")
        try Data("""
        <html><head><title>Iframe fixture</title></head><body style="margin:0"><iframe style="border:0;width:300px;height:240px" src="\(childURL.absoluteString)"></iframe><script>addEventListener('message',e=>document.title=e.data)</script></body></html>
        """.utf8).write(to: parent)
        let parentServer = CompanionBrowserArtifactServer(artifact: try CompanionBrowserArtifact(selectedFile: parent, allowsJavaScript: true), allowsVirtualOrigin: false)
        let parentURL = try await parentServer.authorizedURL(path: "parent.html")
        let renderer = RemoteBrowserRenderer(url: parentURL)
        do {
            var frame = try await renderer.interact(RemoteBrowserRequest(action: .open, width: 640, height: 480))
            for _ in 0..<20 where frame.isLoading || frame.title != "Iframe fixture" {
                frame = try await renderer.interact(RemoteBrowserRequest(action: .snapshot, width: 640, height: 480))
            }
            let clicked = try await renderer.interact(RemoteBrowserRequest(action: .tap, width: 640, height: 480, x: 0.1, y: 0.1))
            XCTAssertEqual(clicked.title, "Trusted iframe click")
            _ = try await renderer.interact(RemoteBrowserRequest(action: .tap, width: 640, height: 480, x: 0.1, y: 0.3))
            let typed = try await renderer.interact(RemoteBrowserRequest(action: .text, width: 640, height: 480, text: "native"))
            XCTAssertEqual(typed.title, "Trusted input:native")
            let erased = try await renderer.interact(RemoteBrowserRequest(action: .key, width: 640, height: 480, key: .backspace))
            XCTAssertEqual(erased.title, "Trusted input:nativ")
            renderer.close()
            await parentServer.close(); await childServer.close()
        } catch {
            renderer.close()
            await parentServer.close(); await childServer.close()
            throw error
        }
    }

    func testHostRendererLoadsArtifactAndInteractsWithoutClientPageExecution() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("index.html")
        try Data("""
        <html><head><title>Host fixture</title></head><body style="margin:0;background:white"><button style="width:200px;height:100px;background:black;color:white" onclick="document.title='Host clicked'">Click</button><input id="entry" oninput="document.title=this.value" style="position:absolute;left:0;top:120px;width:200px;height:60px"></body></html>
        """.utf8).write(to: file)
        let server = CompanionBrowserArtifactServer(artifact: try CompanionBrowserArtifact(selectedFile: file, allowsJavaScript: true))
        let url = try await server.authorizedURL(path: "index.html")
        let renderer = RemoteBrowserRenderer(url: url)
        do {
            var frame = try await renderer.interact(RemoteBrowserRequest(action: .open, width: 640, height: 480))
            func hasPaintedContent(_ frame: RemoteBrowserFrame) -> Bool {
                guard let bitmap = NSBitmapImageRep(data: frame.image),
                      let button = bitmap.colorAt(x: bitmap.pixelsWide / 20, y: bitmap.pixelsHigh / 20)?.usingColorSpace(.deviceRGB),
                      let background = bitmap.colorAt(x: bitmap.pixelsWide * 4 / 5, y: bitmap.pixelsHigh * 4 / 5)?.usingColorSpace(.deviceRGB) else { return false }
                return abs(button.redComponent - background.redComponent) > 0.02
            }
            for _ in 0..<20 where frame.title != "Host fixture" || frame.isLoading || !hasPaintedContent(frame) {
                frame = try await renderer.interact(RemoteBrowserRequest(action: .snapshot, width: 640, height: 480))
            }
            XCTAssertEqual(frame.title, "Host fixture")
            XCTAssertFalse(frame.image.isEmpty)
            XCTAssertLessThanOrEqual(frame.image.count, RemoteBrowserFrame.maximumImageBytes)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: frame.image))
            let buttonPixel = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide / 20,
                                                           y: bitmap.pixelsHigh / 20)?.usingColorSpace(.deviceRGB))
            let backgroundPixel = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide * 4 / 5,
                                                               y: bitmap.pixelsHigh * 4 / 5)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(abs(buttonPixel.redComponent - backgroundPixel.redComponent), 0.02,
                                 "The frame must contain rendered page content, not an empty snapshot")
            let clicked = try await renderer.interact(RemoteBrowserRequest(action: .tap, width: 640, height: 480,
                                                                           x: 0.1, y: 0.1))
            XCTAssertEqual(clicked.title, "Host clicked")
            _ = try await renderer.interact(RemoteBrowserRequest(action: .tap, width: 640, height: 480,
                                                                 x: 0.1, y: 0.3))
            let typed = try await renderer.interact(RemoteBrowserRequest(action: .text, width: 640, height: 480,
                                                                         text: "Host typed"))
            XCTAssertEqual(typed.title, "Host typed")
            renderer.close()
            await server.close()
        } catch {
            renderer.close()
            await server.close()
            throw error
        }
    }
}
