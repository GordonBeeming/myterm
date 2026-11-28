//
//  ReflowTests.swift
//  
//
//  Created by Miguel de Icaza on 4/17/20.
//
#if os(macOS)
import Foundation
import Testing

@testable import SwiftTerm

final class ReflowTests {
    
    @Test func testDoesNotCrashWhenReflowingToTinyWidth() {
        let options = TerminalOptions(cols: 10, rows: 10, scrollback: 1)
        let h = HeadlessTerminal (queue: SwiftTermTests.queue, options: options) { exitCode in }
        
        let t = h.terminal!
        
        t.feed (text: "1234567890\r\n")
        t.feed (text: "ABCDEFGH\r\n")
        t.feed (text: "abcdefghijklmnopqrstxxx\r\n")
        t.feed (text: "\r\n")
        
        // if we resize to a small column width, content is pushed back up and out the top
        // of the buffer. Ensure that this does not crash
        t.resize(cols: 3, rows: 10)
        #expect(Bool(true))
    }

    @Test func wideningPreservesHiddenColumnsInRestoredWrappedRows() {
        let options = TerminalOptions(cols: 8, rows: 5, scrollback: 5)
        let headless = HeadlessTerminal(queue: SwiftTermTests.queue, options: options) { _ in }
        let terminal = headless.terminal!
        terminal.buffer.y = 3
        let line = terminal.buffer.lines[1]
        line.isWrapped = true
        line.resize(cols: 16, fillData: .Null)
        let marker = terminal.makeCharData(attribute: CharData.defaultAttr, char: "X")
        line[15] = marker

        terminal.resize(cols: 12, rows: 5)

        #expect(terminal.buffer.lines[1].count == 16)
        #expect(terminal.buffer.lines[1][15].code == marker.code)
    }
}
#endif
