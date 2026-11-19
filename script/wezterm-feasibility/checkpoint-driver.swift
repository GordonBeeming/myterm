struct Delivery: Decodable { let sequence: Int; let event: Event }
struct Request: Decodable { let checkpoint: [UInt8]?; let events: [Delivery]; let dirty: [UInt8]? }

final class BoundedInput {
    private var pending = Data()
    private func chunk() throws -> Data? {
        while true {
            var bytes = [UInt8](repeating: 0,count: 4096)
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(FileHandle.standardInput.fileDescriptor,buffer.baseAddress,buffer.count)
            }
            if count < 0 {
                if errno == EINTR {continue}
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return count == 0 ? nil : Data(bytes.prefix(count))
        }
    }
    func line(limit: Int) throws -> Data? {
        var searched = 0
        while true {
            if let end = pending.dropFirst(searched).firstIndex(of: 10) {
                let result = Data(pending[..<end])
                guard result.count <= limit else { throw TerminalCheckpointError.corrupt("stream line limit") }
                pending.removeSubrange(...end)
                return result
            }
            guard pending.count <= limit else { throw TerminalCheckpointError.corrupt("stream line limit") }
            searched = pending.count
            guard let chunk = try chunk() else {
                guard pending.isEmpty else { throw TerminalCheckpointError.corrupt("truncated stream line") }
                return nil
            }
            pending.append(chunk)
        }
    }
    func all(limit: Int) throws -> Data {
        while let chunk = try chunk() {
            pending.append(chunk)
            guard pending.count <= limit else { throw TerminalCheckpointError.corrupt("request byte limit") }
        }
        return pending
    }
}

@MainActor
func bridgeRun() throws {
    let streaming = CommandLine.arguments.contains("--stream")
    let input = BoundedInput()
    let request: Request
    if streaming {
        guard let line = try input.line(limit: 5_000_000) else {
            throw NSError(domain: "CheckpointPrototype", code: 3)
        }
        struct Header: Decodable { let checkpoint: [UInt8] }
        let header = try JSONDecoder().decode(Header.self, from: line)
        request = Request(checkpoint: header.checkpoint, events: [], dirty: nil)
    } else {
        request = try JSONDecoder().decode(Request.self, from: input.all(limit: 6_000_000))
    }
    let recorder = Recorder()
    let view = makeView(recorder)
    let terminal = view.getTerminal()
    if let dirty = request.dirty { terminal.feed(byteArray: dirty) }
    var sequence = -1
    let start = DispatchTime.now().uptimeNanoseconds
    if let checkpoint = request.checkpoint {
        sequence = try terminal.importRustPrototypeCheckpoint(Data(checkpoint),geometry: view.imageRenderingGeometry)
    }
    let importNs = DispatchTime.now().uptimeNanoseconds - start
    if CommandLine.arguments.contains("--import-ack") {
        var ack = try JSONSerialization.data(withJSONObject: ["imported":sequence,"importNs":importNs])
        ack.append(10);FileHandle.standardOutput.write(ack)
    }
    recorder.suppressed = false
    var snapshots: [[String: Any]] = []
    func capture() throws -> [String: Any] {
        var result = try snapshot(terminal, recorder)
        result["nativeCheckpoint"] = try terminal.exportCheckpoint().base64EncodedString()
        return result
    }
    if request.checkpoint != nil { snapshots.append(try capture()) }
    func apply(_ delivery: Delivery) throws {
        guard sequence < Int.max, delivery.sequence == sequence + 1 else {
            throw NSError(domain: "CheckpointPrototype", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "delivery sequence gap, duplicate or reordering"])
        }
        if let size = delivery.event.resize {
            guard size.count == 2, (2...1000).contains(size[0]), (1...1000).contains(size[1]) else {
                throw NSError(domain: "CheckpointPrototype", code: 2)
            }
            terminal.resize(cols: size[0], rows: size[1])
        }
        if let bytes = delivery.event.data { terminal.feed(byteArray: bytes) }
        sequence = delivery.sequence
        snapshots.append(try capture())
    }
    for delivery in request.events { try apply(delivery) }
    if streaming {
        while let line = try input.line(limit: 100000) {
            try apply(JSONDecoder().decode(Delivery.self, from: line))
        }
    }
    let result: [String: Any] = ["snapshots": snapshots, "sequence":sequence,"importNs":importNs]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
}
do { try bridgeRun() } catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8))
    exit(1)
}
import Darwin

