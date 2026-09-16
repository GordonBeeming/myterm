//
//  MouseEventEncodingTests.swift
//
//  encodeMouseEvent must produce exactly the bytes sendEvent emits, for every
//  mouse protocol, so views can deliver mouse input through their own path.
//
import Foundation
import Testing

@testable import SwiftTerm

final class MouseEventEncodingTests: TerminalDelegate {
    var sent: [UInt8] = []

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        sent.append(contentsOf: data)
    }

    private func makeTerminal(protocolSequence: String) -> Terminal {
        let terminal = Terminal(delegate: self, options: TerminalOptions(cols: 80, rows: 25))
        terminal.feed(text: "\u{1b}[?1000h" + protocolSequence)
        sent = []
        return terminal
    }

    @Test(arguments: ["", "\u{1b}[?1006h", "\u{1b}[?1016h", "\u{1b}[?1015h", "\u{1b}[?1005h"])
    func encodedEventMatchesSentEvent(protocolSequence: String) {
        let terminal = makeTerminal(protocolSequence: protocolSequence)
        let wheelUp = terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
        let release = terminal.encodeButton(button: 0, release: true, shift: false, meta: false, control: false)
        for flags in [wheelUp, release, 0] {
            sent = []
            terminal.sendEvent(buttonFlags: flags, x: 7, y: 3, pixelX: 70, pixelY: 45)
            let encoded = terminal.encodeMouseEvent(buttonFlags: flags, x: 7, y: 3, pixelX: 70, pixelY: 45)
            #expect(encoded == sent, "flags \(flags) with \(protocolSequence.debugDescription)")
            #expect(!encoded.isEmpty)
        }
    }

    @Test func sgrWheelUpEncoding() {
        let terminal = makeTerminal(protocolSequence: "\u{1b}[?1006h")
        let flags = terminal.encodeButton(button: 4, release: false, shift: false, meta: false, control: false)
        let encoded = terminal.encodeMouseEvent(buttonFlags: flags, x: 0, y: 0, pixelX: 0, pixelY: 0)
        #expect(String(decoding: encoded, as: UTF8.self) == "\u{1b}[<64;1;1M")
    }
}
