import Foundation
import MyTermRemote

/// A real origin outside the relay, with observable requests and no shared user state.
struct BrowserHTTPFixture {
    let process: Process
    let directory: URL
    let origin: URL

    static func start(in directory: URL) async throws -> Self {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("server.py")
        try Data(serverScript.utf8).write(to: script)
        try Data("""
        <!doctype html><html><head><title>Browser start</title></head>
        <body style="margin:0;background:white;color:black;font:20px sans-serif">
        <a id="next" href="/next.html" style="display:block;width:400px;height:60px">Next page</a>
        <input id="entry" style="width:380px;height:48px" oninput="document.title=this.value">
        <form method="POST" action="/submit"><input name="value" value="relay-form"><button>Submit</button></form>
        <a id="popup" target="_blank" href="/next.html">New window link</a>
        <div style="height:2000px">Scroll content</div>
        <script>fetch('/marker.txt').then(r=>r.text()).then(t=>document.title=t.trim())</script>
        </body></html>
        """.utf8).write(to: directory.appendingPathComponent("index.html"))
        try Data("<html><head><title>Browser next</title></head><body>RELAY NEXT PAGE</body></html>".utf8)
            .write(to: directory.appendingPathComponent("next.html"))
        try Data("RELAY FETCH OK".utf8).write(to: directory.appendingPathComponent("marker.txt"))
        try Data("""
        <html><title>Opening socket</title><script>
        const socket=new WebSocket(location.origin.replace('http:','ws:')+'/socket');
        socket.onmessage=e=>{document.title=e.data;socket.close()};
        </script></html>
        """.utf8).write(to: directory.appendingPathComponent("socket-test.html"))
        try Data("""
        <html><title>Sending form</title><script>
        fetch('/submit',{method:'POST',body:'through-relay'}).then(r=>r.text()).then(t=>document.title=t);
        </script></html>
        """.utf8).write(to: directory.appendingPathComponent("post-test.html"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            let ready = directory.appendingPathComponent("port")
            for _ in 0..<200 {
                guard process.isRunning else { throw RemoteError.offline }
                if let data = try? Data(contentsOf: ready),
                   let port = UInt16(String(decoding: data, as: UTF8.self)),
                   let origin = URL(string: "http://127.0.0.1:\(port)") {
                    return Self(process: process, directory: directory, origin: origin)
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            throw RemoteError.timedOut
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }

    private static let serverScript = #"""
    import base64, hashlib, http.server, pathlib, struct, sys
    root = pathlib.Path(sys.argv[1])
    class Handler(http.server.SimpleHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def __init__(self, *args, **kwargs):
            super().__init__(*args, directory=str(root), **kwargs)
        def log_message(self, *args):
            pass
        def do_GET(self):
            if self.path == '/redirect':
                self.send_response(302)
                self.send_header('Location', '/next.html')
                self.send_header('Content-Length', '0')
                self.end_headers()
            elif self.path == '/socket':
                key = self.headers.get('Sec-WebSocket-Key', '')
                accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                self.send_response(101)
                self.send_header('Upgrade', 'websocket')
                self.send_header('Connection', 'Upgrade')
                self.send_header('Sec-WebSocket-Accept', accept)
                self.end_headers()
                data = b'RELAY WEBSOCKET OK'
                self.wfile.write(bytes([0x81, len(data)]) + data)
                self.wfile.flush()
                self.close_connection = True
            else:
                super().do_GET()
        def do_POST(self):
            body = self.rfile.read(min(int(self.headers.get('Content-Length', '0')), 4096))
            result = b'RELAY POST ' + body
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.send_header('Content-Length', str(len(result)))
            self.end_headers()
            self.wfile.write(result)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    (root / 'port').write_text(str(server.server_port))
    server.serve_forever()
    """#
}
