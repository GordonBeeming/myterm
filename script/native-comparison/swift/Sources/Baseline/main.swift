import AppKit
import Foundation
import SwiftTerm

struct Event: Decodable {
    var data: [UInt8]?
    var resize: [Int]?
    var checkpoint: Bool?
}
struct Trace: Decodable { var name: String; var events: [Event] }

final class Recorder: TerminalViewDelegate {
    var replies: [UInt8] = []
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) { replies.append(contentsOf: data) }
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

@MainActor
func makeView(_ recorder: Recorder) -> TerminalView {
    let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 640, height: 480))
    view.terminalDelegate = recorder
    view.getTerminal().resize(cols: 20, rows: 6)
    return view
}

func colorCode(_ color: Attribute.Color) -> String {
    switch color {
    case .defaultColor, .defaultInvertedColor: return "default"
    case .ansi256(let code): return "idx:\(code)"
    case .trueColor(let r, let g, let b): return "rgb:\(r),\(g),\(b)"
    }
}

@MainActor
func snapshot(_ terminal: Terminal, _ recorder: Recorder) throws -> [String: Any] {
    let dims = terminal.getDims()
    var cells: [[String]] = []
    var styles: [[String]] = []
    for y in 0..<dims.rows {
        var row: [String] = []
        var rowStyles: [String] = []
        for x in 0..<dims.cols {
            if let a = terminal.getCharData(col: x, row: y)?.attribute {
                rowStyles.append("\(colorCode(a.fg))|\(colorCode(a.bg))|\(a.style.contains(.bold))\(a.style.contains(.italic))\(a.style.contains(.underline))\(a.style.contains(.inverse))")
            } else { rowStyles.append("default|default|falsefalsefalsefalse") }
            let character = terminal.getCharacter(col: x, row: y).map(String.init) ?? ""
            row.append(character == "\0" || character == " " ? "" : character)
        }
        cells.append(row)
        styles.append(rowStyles)
    }
    let checkpoint = try terminal.exportCheckpoint()
    guard let root = try PropertyListSerialization.propertyList(from: checkpoint, format: nil) as? [String: Any],
          let state = root["state"] as? [String: Any],
          let alternate = state["alternateActive"] as? Bool else {
        throw NSError(domain: "BaselinePrototype", code: 1)
    }
    let p = terminal.getCursorLocation()
    let activeBuffer = state[alternate ? "alternateBuffer" : "normalBuffer"] as? [String: Any] ?? [:]
    let lines = activeBuffer["lines"] as? [[String: Any]] ?? []
    let images = lines.reduce(0) { $0 + (($1["images"] as? [Any])?.count ?? 0) }
    return ["cells": cells, "styles": styles, "cursor": [p.x, p.y], "alt": alternate,
            "replies": recorder.replies, "history": terminal.getTopVisibleRow(), "imageStripes": images]
}

@MainActor
func run() throws {
    let input = try JSONDecoder().decode([Trace].self, from: FileHandle.standardInput.readDataToEndOfFile())
    var output: [String: Any] = [:]
    for trace in input {
        let recorder = Recorder()
        let view = makeView(recorder)
        let terminal = view.getTerminal()
        var restored: TerminalView?
        var snapshots: [[String: Any]] = []
        var checks: [Bool] = []
        for event in trace.events {
            if let resize = event.resize, resize.count == 2 {
                terminal.resize(cols: resize[0], rows: resize[1])
                restored?.getTerminal().resize(cols: resize[0], rows: resize[1])
            }
            if let bytes = event.data {
                terminal.feed(byteArray: bytes)
                restored?.getTerminal().feed(byteArray: bytes)
            }
            snapshots.append(try snapshot(terminal, recorder))
            if let copy = restored?.getTerminal() {
                checks.append(try copy.exportCheckpoint() == terminal.exportCheckpoint())
            }
            if event.checkpoint == true {
                let checkpoint = try terminal.exportCheckpoint()
                let copy = makeView(Recorder())
                try copy.getTerminal().importCheckpoint(checkpoint)
                checks.append(try copy.getTerminal().exportCheckpoint() == checkpoint)
                restored = copy
            }
        }
        output[trace.name] = ["snapshots": snapshots, "checkpointChecks": checks,
                             "finalReplies": recorder.replies,
                             "checkpoint": "SwiftTerm binary checkpoint, then identical suffix; full checkpoint byte comparison"]
    }
    let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
}
try run()
