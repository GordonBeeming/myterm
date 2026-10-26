import Foundation
@preconcurrency import SwiftTerm
@testable import MyTermContinuity

@MainActor
enum PersistentTerminalTestEnvironment {
    static func make(columns: Int = 80, rows: Int = 25) throws -> [String: String] {
        let measured = TerminalImageGeometry.measuredDefault(columns: columns, rows: rows)
        let geometry = SessionHostImageGeometry(cellWidth: measured.cellSize.width, cellHeight: measured.cellSize.height,
            viewportWidth: measured.viewportSize.width, viewportHeight: measured.viewportSize.height,
            displayScale: measured.displayScale)
        var environment = try SessionHostClientAuthentication.testEnvironment()
        environment["MYTERM_PERSISTENT_IMAGE_GEOMETRY"] = try JSONEncoder().encode(geometry).base64EncodedString()
        return environment
    }
}
