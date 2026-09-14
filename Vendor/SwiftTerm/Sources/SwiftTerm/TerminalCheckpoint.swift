//
//  TerminalCheckpoint.swift
//  SwiftTerm
//
//  A bounded, versioned representation of terminal-emulator state. The wire
//  format intentionally contains values only; delegates and handler closures
//  remain attached to the receiving Terminal.
//

import Foundation

enum TerminalCheckpointLimits {
    static let encodedBytes = 32 * 1024 * 1024
    static let columns = 4_096
    static let rows = 4_096
    static let lines = 200_000
    static let cells = 2_000_000
    static let parserBytes = 8 * 1024 * 1024
    static let parserParameters = 4_096
    static let stringBytes = 1 * 1024 * 1024
    static let imageBytes = 24 * 1024 * 1024
    static let keyboardStack = 16
}

public enum TerminalCheckpointError: Error, Equatable, LocalizedError {
    case checkpointTooLarge(actual: Int, maximum: Int)
    case unsupportedVersion(Int)
    case corrupt(String)
    case unsupportedImage
    case unsupportedParserHandler

    public var errorDescription: String? {
        switch self {
        case .checkpointTooLarge(let actual, let maximum):
            return "Terminal checkpoint is \(actual) bytes; the limit is \(maximum) bytes."
        case .unsupportedVersion(let version):
            return "Terminal checkpoint version \(version) is not supported."
        case .corrupt(let reason):
            return "Terminal checkpoint is invalid: \(reason)"
        case .unsupportedImage:
            return "The terminal contains an image without a checkpoint representation."
        case .unsupportedParserHandler:
            return "The terminal parser has an unsupported active DCS handler."
        }
    }
}

struct TerminalCheckpointEnvelope: Codable {
    static let currentVersion = 1
    let version: Int
    let state: TerminalCheckpointState
}

struct TerminalCheckpointState: Codable {
    var columns: Int
    var rows: Int
    var tabStopWidth: Int
    var options: CheckpointOptions
    var normalBuffer: CheckpointBuffer
    var alternateBuffer: CheckpointBuffer
    var alternateActive: Bool
    var synchronizedOutputActive: Bool
    var synchronizedOutputRemainingNanoseconds: UInt64?
    var applicationKeypad: Bool
    var applicationCursor: Bool
    var keyboardNormal: CheckpointKeyboardMode
    var keyboardAlternate: CheckpointKeyboardMode
    var sendFocus: Bool
    var cursorHidden: Bool
    var originMode: Bool
    var marginMode: Bool
    var insertMode: Bool
    var wraparound: Bool
    var bracketedPasteMode: Bool
    var charset: CheckpointCharset?
    var gCharsets: [CheckpointCharset?]
    var gcharset: Int
    var reverseWraparound: Bool
    var currentAttribute: CheckpointAttribute
    var graphemes: [CheckpointGrapheme]
    var lastCharIndex: Int32
    var gLevel: UInt8
    var cursorBlink: Bool
    var allow80To132: Bool
    var parser: CheckpointParser
    var kitty: CheckpointKittyState
    var userScrolling: Bool
    var lineFeedMode: Bool
    var smoothScroll: Bool
    var installedColors: [CheckpointColor]
    var defaultAnsiColors: [CheckpointColor]
    var ansiColors: [CheckpointColor]
    var send8BitControls: Bool
    var hostCurrentDirectory: String?
    var hostCurrentDocument: String?
    var mouseProtocol: Int
    var foregroundColor: CheckpointColor
    var backgroundColor: CheckpointColor
    var cursorColor: CheckpointColor?
    var reportedFocusState: Bool
    var mouseMode: Int
    var mouseShiftCapture: Bool
    var xtermTitleSetUtf: Bool
    var xtermTitleSetHex: Bool
    var xtermTitleQueryUtf: Bool
    var xtermTitleQueryHex: Bool
    var conformance: Int
    var lastBufferCol: Int
    var silentLog: Bool
    var hyperlinkStart: CheckpointPosition?
    var hyperlinkPayload: String?
    var terminalTitle: String
    var iconTitle: String
    var terminalTitleStack: [String]
    var terminalIconStack: [String]
}

struct CheckpointOptions: Codable {
    var cols: Int
    var rows: Int
    var convertEol: Bool
    var termName: String
    var cursorStyle: Int
    var screenReaderMode: Bool
    var scrollback: Int
    var tabStopWidth: Int
    var enableSixelReported: Bool
    var kittyImageCacheLimitBytes: Int
    var ansi256PaletteStrategy: Int
    var regionalIndicatorWidth: Int
}

struct CheckpointKeyboardMode: Codable {
    var flags: Int
    var stack: [Int]
}

struct CheckpointCharset: Codable {
    struct Entry: Codable {
        var key: UInt8
        var value: String
    }
    var entries: [Entry]
}

struct CheckpointGrapheme: Codable {
    var index: Int32
    var character: String
}

struct CheckpointPosition: Codable {
    var column: Int
    var row: Int
}

struct CheckpointColor: Codable {
    var red: UInt16
    var green: UInt16
    var blue: UInt16
}

struct CheckpointAttributeColor: Codable {
    // 0 = ANSI, 1 = true color, 2 = default foreground, 3 = default background.
    var kind: UInt8
    var first: UInt8
    var second: UInt8
    var third: UInt8
}

struct CheckpointAttribute: Codable {
    var foreground: CheckpointAttributeColor
    var background: CheckpointAttributeColor
    var style: UInt8
    var underlineStyle: UInt8
    var underlineColor: CheckpointAttributeColor?
}

struct CheckpointCell: Codable {
    var code: Int32
    var width: Int8
    var attribute: CheckpointAttribute
    var hyperlink: String?
}

extension CheckpointCell {
    init(_ cell: CharData) throws {
        code = cell.code
        width = cell.width
        attribute = CheckpointAttribute(cell.attribute)
        if cell.hasPayload {
            guard let value = cell.getPayload() as? String else {
                throw TerminalCheckpointError.corrupt("cell payload is not a hyperlink")
            }
            hyperlink = value
        } else {
            hyperlink = nil
        }
    }

    func value() throws -> CharData {
        guard width >= 0 && width <= 2 else {
            throw TerminalCheckpointError.corrupt("cell width is outside 0...2")
        }
        var cell = CharData(attribute: try attribute.value(), code: code, size: width)
        if let hyperlink {
            guard let atom = TinyAtom.lookupCheckpointHyperlink(hyperlink) else {
                throw TerminalCheckpointError.corrupt("hyperlink table is full")
            }
            cell.setPayload(atom: atom)
        }
        return cell
    }
}

struct CheckpointImage: Codable {
    var data: Data
    var pixelWidth: Int
    var pixelHeight: Int
    var column: Int
    var isKitty: Bool
    var imageId: UInt32?
    var imageNumber: UInt32?
    var placementId: UInt32?
    var zIndex: Int
    var kittyColumn: Int
    var kittyRow: Int
    var kittyColumns: Int
    var kittyRows: Int
    var pixelOffsetX: Int
    var pixelOffsetY: Int
}

struct CheckpointLine: Codable {
    var isWrapped: Bool
    var renderMode: Int
    var fillCharacter: CheckpointCell
    var cellCount: Int
    var cellData: Data
    var hyperlinks: [String]
    var images: [CheckpointImage]
    var generation: UInt64
}

enum CheckpointCellCodec {
    static let encodedCellBytes = 23

    static func encode<Cells: Collection>(_ cells: Cells) throws -> (data: Data, hyperlinks: [String])
    where Cells.Element == CharData {
        var data = Data()
        data.reserveCapacity(cells.count * encodedCellBytes)
        var hyperlinks: [String] = []
        var hyperlinkIndexes: [String: Int32] = [:]
        for cell in cells {
            appendUInt32(UInt32(bitPattern: cell.code), to: &data)
            data.append(UInt8(bitPattern: cell.width))
            appendColor(CheckpointAttributeColor(cell.attribute.fg), to: &data)
            appendColor(CheckpointAttributeColor(cell.attribute.bg), to: &data)
            data.append(cell.attribute.style.rawValue)
            data.append(cell.attribute.underlineStyle.rawValue)
            if let underlineColor = cell.attribute.underlineColor {
                appendColor(CheckpointAttributeColor(underlineColor), to: &data)
            } else {
                data.append(contentsOf: [255, 0, 0, 0])
            }
            let hyperlinkIndex: Int32
            if cell.hasPayload {
                guard let hyperlink = cell.getPayload() as? String else {
                    throw TerminalCheckpointError.corrupt("cell payload is not a hyperlink")
                }
                if let existing = hyperlinkIndexes[hyperlink] {
                    hyperlinkIndex = existing
                } else {
                    guard hyperlinks.count < Int(Int32.max) else {
                        throw TerminalCheckpointError.corrupt("too many hyperlinks")
                    }
                    hyperlinkIndex = Int32(hyperlinks.count)
                    hyperlinks.append(hyperlink)
                    hyperlinkIndexes[hyperlink] = hyperlinkIndex
                }
            } else {
                hyperlinkIndex = -1
            }
            appendUInt32(UInt32(bitPattern: hyperlinkIndex), to: &data)
        }
        return (data, hyperlinks)
    }

    static func decode(data: Data, count: Int, hyperlinks: [String],
                       hyperlinkAtoms: inout [String: TinyAtom]) throws -> [CharData] {
        guard count >= 0, count <= TerminalCheckpointLimits.columns,
              data.count == count * encodedCellBytes else {
            throw TerminalCheckpointError.corrupt("compact cell data length is invalid")
        }
        var cells: [CharData] = []
        cells.reserveCapacity(count)
        var offset = 0
        for _ in 0..<count {
            let code = Int32(bitPattern: readUInt32(data, at: &offset))
            let width = Int8(bitPattern: data[offset]); offset += 1
            let foreground = readColor(data, at: &offset)
            let background = readColor(data, at: &offset)
            let style = data[offset]; offset += 1
            let underlineStyle = data[offset]; offset += 1
            let rawUnderline = readColor(data, at: &offset)
            let underlineColor = rawUnderline.kind == 255 ? nil : rawUnderline
            let hyperlinkIndex = Int32(bitPattern: readUInt32(data, at: &offset))
            let hyperlink: String?
            if hyperlinkIndex == -1 {
                hyperlink = nil
            } else {
                guard hyperlinkIndex >= 0, Int(hyperlinkIndex) < hyperlinks.count else {
                    throw TerminalCheckpointError.corrupt("compact cell hyperlink index is invalid")
                }
                hyperlink = hyperlinks[Int(hyperlinkIndex)]
            }
            guard width >= 0 && width <= 2 else {
                throw TerminalCheckpointError.corrupt("cell width is outside 0...2")
            }
            let attribute = try CheckpointAttribute(
                foreground: foreground, background: background, style: style,
                underlineStyle: underlineStyle, underlineColor: underlineColor
            ).value()
            var cell = CharData(attribute: attribute, code: code, size: width)
            if let hyperlink {
                let atom: TinyAtom
                if let existing = hyperlinkAtoms[hyperlink] {
                    atom = existing
                } else {
                    guard let created = TinyAtom.lookupCheckpointHyperlink(hyperlink) else {
                        throw TerminalCheckpointError.corrupt("hyperlink table is full")
                    }
                    hyperlinkAtoms[hyperlink] = created
                    atom = created
                }
                cell.setPayload(atom: atom)
            }
            cells.append(cell)
        }
        return cells
    }

    private static func appendColor(_ color: CheckpointAttributeColor, to data: inout Data) {
        data.append(contentsOf: [color.kind, color.first, color.second, color.third])
    }

    private static func readColor(_ data: Data, at offset: inout Int) -> CheckpointAttributeColor {
        defer { offset += 4 }
        return CheckpointAttributeColor(
            kind: data[offset], first: data[offset + 1], second: data[offset + 2], third: data[offset + 3]
        )
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func readUInt32(_ data: Data, at offset: inout Int) -> UInt32 {
        defer { offset += 4 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

struct CheckpointBuffer: Codable {
    var columns: Int
    var rows: Int
    var scrollback: Int?
    var maximumLines: Int
    var lines: [CheckpointLine]
    var xDisplay: Int
    var yDisplay: Int
    var xBase: Int
    var x: Int
    var y: Int
    var yBase: Int
    var linesTop: Int
    var scrollBottom: Int
    var scrollTop: Int
    var tabStops: [Bool]
    var savedX: Int
    var savedY: Int
    var savedOriginMode: Bool
    var savedMarginMode: Bool
    var savedWraparound: Bool
    var savedReverseWraparound: Bool
    var marginLeft: Int
    var marginRight: Int
    var savedAttribute: CheckpointAttribute
    var savedCharset: CheckpointCharset?
    var currentAttribute: CheckpointAttribute
    var insertMode: Bool
    var marginMode: Bool
    var wraparound: Bool
    var lastStorageY: Int
    var lastStorageX: Int
    var lastStorageColumns: Int
    var lastStorageRows: Int
}

struct CheckpointParser: Codable {
    // ParserState raw values are part of this versioned wire format.
    var initialState: UInt8
    var currentState: UInt8
    var osc: [UInt8]
    var apc: [UInt8]
    var parameters: [Int]
    var parameterText: [UInt8]
    var collect: [UInt8]
    var pendingUtf8: [UInt8]
    // nil, "decrqss", or "sixel".
    var dcsHandler: String?
    var dcsData: [UInt8]
}

struct CheckpointKittyControl: Codable {
    var action: String
    var suppressResponses: Int
    var format: Int
    var transmission: String
    var width: Int
    var height: Int
    var cropX: Int
    var cropY: Int
    var cropWidth: Int
    var cropHeight: Int
    var dataSize: Int
    var dataOffset: Int
    var imageId: UInt32?
    var imageNumber: UInt32?
    var placementId: UInt32?
    var parentImageId: UInt32?
    var parentPlacementId: UInt32?
    var offsetH: Int
    var offsetV: Int
    var pixelOffsetX: Int
    var pixelOffsetY: Int
    var unicodePlaceholder: Int
    var zIndex: Int
    var more: Int
    var compression: String?
    var columns: Int
    var rows: Int
    var cursorPolicy: Int
    var deleteMode: String?
}

struct CheckpointKittyImage: Codable {
    var id: UInt32
    // 0 = PNG, 1 = RGBA.
    var kind: UInt8
    var data: Data
    var width: Int
    var height: Int
    var byteSize: Int
    var lastAccessTick: UInt64
}

struct CheckpointKittyNumber: Codable {
    var number: UInt32
    var imageId: UInt32
}

struct CheckpointKittyPlacement: Codable {
    var imageId: UInt32
    var placementId: UInt32
    var parentImageId: UInt32?
    var parentPlacementId: UInt32?
    var parentOffsetH: Int
    var parentOffsetV: Int
    var pixelOffsetX: Int
    var pixelOffsetY: Int
    var column: Int
    var row: Int
    var columns: Int
    var rows: Int
    var zIndex: Int
    var isVirtual: Bool
    var isAlternateBuffer: Bool
}

struct CheckpointKittyPending: Codable {
    var control: CheckpointKittyControl
    var base64Payload: [UInt8]
}

struct CheckpointKittyState: Codable {
    var images: [CheckpointKittyImage]
    var imageNumbers: [CheckpointKittyNumber]
    var nextImageId: UInt32
    var nextPlacementId: UInt32
    var pending: CheckpointKittyPending?
    var placements: [CheckpointKittyPlacement]
    var totalImageBytes: Int
    var nextImageAccessTick: UInt64
}

protocol TerminalCheckpointImageExporting: TerminalImage {
    func terminalCheckpointEncodedImage() -> Data?
}

final class RestoredTerminalImage: TerminalCheckpointImageExporting, KittyPlacementImage {
    let encodedImage: Data
    var pixelWidth: Int
    var pixelHeight: Int
    var col: Int
    var kittyIsKitty: Bool
    var kittyImageId: UInt32?
    var kittyImageNumber: UInt32?
    var kittyPlacementId: UInt32?
    var kittyZIndex: Int
    var kittyCol: Int
    var kittyRow: Int
    var kittyCols: Int
    var kittyRows: Int
    var kittyPixelOffsetX: Int
    var kittyPixelOffsetY: Int

    init(_ snapshot: CheckpointImage) {
        encodedImage = snapshot.data
        pixelWidth = snapshot.pixelWidth
        pixelHeight = snapshot.pixelHeight
        col = snapshot.column
        kittyIsKitty = snapshot.isKitty
        kittyImageId = snapshot.imageId
        kittyImageNumber = snapshot.imageNumber
        kittyPlacementId = snapshot.placementId
        kittyZIndex = snapshot.zIndex
        kittyCol = snapshot.kittyColumn
        kittyRow = snapshot.kittyRow
        kittyCols = snapshot.kittyColumns
        kittyRows = snapshot.kittyRows
        kittyPixelOffsetX = snapshot.pixelOffsetX
        kittyPixelOffsetY = snapshot.pixelOffsetY
    }

    func terminalCheckpointEncodedImage() -> Data? { encodedImage }
}

extension CheckpointColor {
    init(_ color: Color) {
        red = color.red
        green = color.green
        blue = color.blue
    }

    var color: Color { Color(red: red, green: green, blue: blue) }
}

extension CheckpointAttributeColor {
    init(_ color: Attribute.Color) {
        switch color {
        case .ansi256(let code):
            self.init(kind: 0, first: code, second: 0, third: 0)
        case .trueColor(let red, let green, let blue):
            self.init(kind: 1, first: red, second: green, third: blue)
        case .defaultColor:
            self.init(kind: 2, first: 0, second: 0, third: 0)
        case .defaultInvertedColor:
            self.init(kind: 3, first: 0, second: 0, third: 0)
        }
    }

    func value() throws -> Attribute.Color {
        switch kind {
        case 0: return .ansi256(code: first)
        case 1: return .trueColor(red: first, green: second, blue: third)
        case 2: return .defaultColor
        case 3: return .defaultInvertedColor
        default: throw TerminalCheckpointError.corrupt("unknown attribute color kind")
        }
    }
}

extension CheckpointAttribute {
    init(_ attribute: Attribute) {
        foreground = CheckpointAttributeColor(attribute.fg)
        background = CheckpointAttributeColor(attribute.bg)
        style = attribute.style.rawValue
        underlineStyle = attribute.underlineStyle.rawValue
        underlineColor = attribute.underlineColor.map(CheckpointAttributeColor.init)
    }

    func value() throws -> Attribute {
        guard let underline = UnderlineStyle(rawValue: underlineStyle) else {
            throw TerminalCheckpointError.corrupt("unknown underline style")
        }
        return Attribute(
            fg: try foreground.value(),
            bg: try background.value(),
            style: CharacterStyle(rawValue: style),
            underlineStyle: underline,
            underlineColor: try underlineColor?.value()
        )
    }
}

extension CheckpointCharset {
    init(_ charset: [UInt8: String]) {
        entries = charset.map { Entry(key: $0.key, value: $0.value) }.sorted { $0.key < $1.key }
    }

    func value() -> [UInt8: String] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.value) })
    }
}

extension CheckpointImage {
    init(_ image: TerminalImage) throws {
        guard let exportable = image as? TerminalCheckpointImageExporting,
              let data = exportable.terminalCheckpointEncodedImage() else {
            throw TerminalCheckpointError.unsupportedImage
        }
        self.data = data
        pixelWidth = image.pixelWidth
        pixelHeight = image.pixelHeight
        column = image.col
        if let kitty = image as? KittyPlacementImage {
            isKitty = kitty.kittyIsKitty
            imageId = kitty.kittyImageId
            imageNumber = kitty.kittyImageNumber
            placementId = kitty.kittyPlacementId
            zIndex = kitty.kittyZIndex
            kittyColumn = kitty.kittyCol
            kittyRow = kitty.kittyRow
            kittyColumns = kitty.kittyCols
            kittyRows = kitty.kittyRows
            pixelOffsetX = kitty.kittyPixelOffsetX
            pixelOffsetY = kitty.kittyPixelOffsetY
        } else {
            isKitty = false
            imageId = nil
            imageNumber = nil
            placementId = nil
            zIndex = 0
            kittyColumn = 0
            kittyRow = 0
            kittyColumns = 0
            kittyRows = 0
            pixelOffsetX = 0
            pixelOffsetY = 0
        }
    }
}

extension Terminal {
    /// Serializes all emulator state needed to continue parsing a future byte suffix.
    /// Delegate references and registered handler closures remain local to each Terminal.
    public func exportCheckpoint() throws -> Data {
        guard kittyPlacementContext == nil else {
            throw TerminalCheckpointError.corrupt("checkpoint requested during image placement")
        }
        let state = try makeCheckpointState()
        try state.validate()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(
            TerminalCheckpointEnvelope(version: TerminalCheckpointEnvelope.currentVersion, state: state)
        )
        guard data.count <= TerminalCheckpointLimits.encodedBytes else {
            throw TerminalCheckpointError.checkpointTooLarge(
                actual: data.count, maximum: TerminalCheckpointLimits.encodedBytes
            )
        }
        return data
    }

    /// Replaces emulator state without invoking delegate callbacks. The receiver keeps
    /// its delegate, custom OSC handlers, and parser callback closures.
    public func importCheckpoint(_ data: Data) throws {
        guard data.count <= TerminalCheckpointLimits.encodedBytes else {
            throw TerminalCheckpointError.checkpointTooLarge(
                actual: data.count, maximum: TerminalCheckpointLimits.encodedBytes
            )
        }
        let envelope: TerminalCheckpointEnvelope
        do {
            envelope = try PropertyListDecoder().decode(TerminalCheckpointEnvelope.self, from: data)
        } catch {
            throw TerminalCheckpointError.corrupt("wire data could not be decoded")
        }
        guard envelope.version == TerminalCheckpointEnvelope.currentVersion else {
            throw TerminalCheckpointError.unsupportedVersion(envelope.version)
        }
        try envelope.state.validate()

        let state = envelope.state
        let restoredOptions = try Self.restoreOptions(state.options)
        var hyperlinkAtoms: [String: TinyAtom] = [:]
        let restoredNormal = try Buffer.restore(
            from: state.normalBuffer, tabStopWidth: state.tabStopWidth, hyperlinkAtoms: &hyperlinkAtoms
        )
        let restoredAlternate = try Buffer.restore(
            from: state.alternateBuffer, tabStopWidth: state.tabStopWidth, hyperlinkAtoms: &hyperlinkAtoms
        )
        let restoredKitty = try KittyGraphicsState.restore(from: state.kitty)
        let restoredCurrentAttribute = try state.currentAttribute.value()
        let restoreParser = try parser.prepareRestoration(from: state.parser, terminal: self)
        let restoredMouseProtocol = try Self.restoreMouseProtocol(state.mouseProtocol)
        let restoredMouseMode = try Self.restoreMouseMode(state.mouseMode)
        let restoredConformance = try Self.restoreConformance(state.conformance)
        var restoredIndexToChar: [Int32: Character] = [:]
        var restoredCharToIndex: [Character: Int32] = [:]
        for entry in state.graphemes {
            guard entry.character.count == 1, let character = entry.character.first else {
                throw TerminalCheckpointError.corrupt("grapheme entry is not one Character")
            }
            restoredIndexToChar[entry.index] = character
            restoredCharToIndex[character] = entry.index
        }

        let delegate = tdel
        tdel = nil
        defer { tdel = delegate }
        synchronizedOutputTimeoutItem?.cancel()
        synchronizedOutputTimeoutItem = nil
        synchronizedOutputDeadlineUptimeNanoseconds = nil
        cols = state.columns
        rows = state.rows
        tabStopWidth = state.tabStopWidth
        options = restoredOptions
        normalBuffer = restoredNormal
        altBuffer = restoredAlternate
        buffer = state.alternateActive ? restoredAlternate : restoredNormal
        normalBuffer.scroll = { [weak self] wrapped in self?.scroll(isWrapped: wrapped) }
        altBuffer.scroll = { [weak self] wrapped in self?.scroll(isWrapped: wrapped) }
        synchronizedOutputActive = state.synchronizedOutputActive
        if let remaining = state.synchronizedOutputRemainingNanoseconds {
            scheduleSynchronizedOutputTimeout(afterNanoseconds: remaining)
        }
        applicationKeypad = state.applicationKeypad
        applicationCursor = state.applicationCursor
        keyboardModeNormal = KeyboardModeState(
            flags: KittyKeyboardFlags(rawValue: state.keyboardNormal.flags),
            stack: state.keyboardNormal.stack.map { KittyKeyboardFlags(rawValue: $0) }
        )
        keyboardModeAlt = KeyboardModeState(
            flags: KittyKeyboardFlags(rawValue: state.keyboardAlternate.flags),
            stack: state.keyboardAlternate.stack.map { KittyKeyboardFlags(rawValue: $0) }
        )
        sendFocus = state.sendFocus
        cursorHidden = state.cursorHidden
        originMode = state.originMode
        marginMode = state.marginMode
        insertMode = state.insertMode
        wraparound = state.wraparound
        bracketedPasteMode = state.bracketedPasteMode
        charset = state.charset?.value()
        gCharsets = state.gCharsets.map { $0?.value() }
        gcharset = state.gcharset
        reverseWraparound = state.reverseWraparound
        curAttr = restoredCurrentAttribute
        charToIndexMap = restoredCharToIndex
        indexToCharMap = restoredIndexToChar
        lastCharIndex = state.lastCharIndex
        gLevel = state.gLevel
        cursorBlink = state.cursorBlink
        allow80To132 = state.allow80To132
        readingBuffer = ReadingBuffer()
        readingBuffer.putbackBuffer = state.parser.pendingUtf8
        restoreParser()
        kittyGraphicsState = restoredKitty
        kittyPlacementContext = nil
        refreshStart = 0
        refreshEnd = max(0, rows - 1)
        scrollInvariantRefreshStart = min(normalBuffer.linesTop, altBuffer.linesTop)
        scrollInvariantRefreshEnd = max(
            normalBuffer.linesTop + normalBuffer.lines.count,
            altBuffer.linesTop + altBuffer.lines.count
        )
        userScrolling = state.userScrolling
        lineFeedMode = state.lineFeedMode
        smoothScroll = state.smoothScroll
        installedColors = state.installedColors.map(\.color)
        defaultAnsiColors = state.defaultAnsiColors.map(\.color)
        ansiColors = state.ansiColors.map(\.color)
        cc.send8bit = state.send8BitControls
        hostCurrentDirectory = state.hostCurrentDirectory
        hostCurrentDocument = state.hostCurrentDocument
        mouseProtocol = restoredMouseProtocol
        settingFgColor = false
        settingBgColor = false
        settingCursorColor = false
        foregroundColor = state.foregroundColor.color
        backgroundColor = state.backgroundColor.color
        cursorColor = state.cursorColor?.color
        reportedFocusState = state.reportedFocusState
        mouseMode = restoredMouseMode
        mouseShiftCapture = state.mouseShiftCapture
        xtermTitleSetUtf = state.xtermTitleSetUtf
        xtermTitleSetHex = state.xtermTitleSetHex
        xtermTitleQueryUtf = state.xtermTitleQueryUtf
        xtermTitleQueryHex = state.xtermTitleQueryHex
        conformance = restoredConformance
        lastBufferCol = state.lastBufferCol
        silentLog = state.silentLog
        if let start = state.hyperlinkStart, let payload = state.hyperlinkPayload {
            hyperLinkTracking = (Position(col: start.column, row: start.row), payload)
        } else {
            hyperLinkTracking = nil
        }
        terminalTitle = state.terminalTitle
        iconTitle = state.iconTitle
        terminalTitleStack = state.terminalTitleStack
        terminalIconStack = state.terminalIconStack
    }
}

extension TerminalCheckpointState {
    func validate() throws {
        guard columns >= 2, columns <= TerminalCheckpointLimits.columns,
              rows >= 1, rows <= TerminalCheckpointLimits.rows,
              options.cols == columns, options.rows == rows,
              tabStopWidth >= 1, tabStopWidth <= TerminalCheckpointLimits.columns,
              options.scrollback >= 0, options.scrollback <= TerminalCheckpointLimits.lines,
              options.kittyImageCacheLimitBytes >= 0 else {
            throw TerminalCheckpointError.corrupt("terminal dimensions or options are out of bounds")
        }
        guard gCharsets.count == 4, (0..<4).contains(gcharset), gLevel <= 3,
              keyboardNormal.stack.count <= TerminalCheckpointLimits.keyboardStack,
              keyboardAlternate.stack.count <= TerminalCheckpointLimits.keyboardStack,
              synchronizedOutputActive == (synchronizedOutputRemainingNanoseconds != nil),
              synchronizedOutputRemainingNanoseconds ?? 0 <= 1_000_000_000 else {
            throw TerminalCheckpointError.corrupt("mode stack or charset state is invalid")
        }
        let knownKeyboardFlags = KittyKeyboardFlags.knownMask
        let keyboardValues = [keyboardNormal.flags, keyboardAlternate.flags]
            + keyboardNormal.stack + keyboardAlternate.stack
        guard keyboardValues.allSatisfy({ $0 >= 0 && ($0 & ~knownKeyboardFlags) == 0 }) else {
            throw TerminalCheckpointError.corrupt("unknown keyboard enhancement flags")
        }
        try validateString(options.termName)
        try validateString(hostCurrentDirectory)
        try validateString(hostCurrentDocument)
        try validateString(hyperlinkPayload)
        try validateString(terminalTitle)
        try validateString(iconTitle)
        try terminalTitleStack.forEach(validateString)
        try terminalIconStack.forEach(validateString)
        try validateCharset(charset)
        try gCharsets.forEach(validateCharset)
        guard installedColors.count == 16,
              defaultAnsiColors.count == 256,
              ansiColors.count == 256 else {
            throw TerminalCheckpointError.corrupt("palette sizes are invalid")
        }

        var cellCount = 0
        var imageBytes = 0
        try validateBuffer(normalBuffer, expectedScrollback: options.scrollback,
                           cellCount: &cellCount, imageBytes: &imageBytes)
        try validateBuffer(alternateBuffer, expectedScrollback: nil,
                           cellCount: &cellCount, imageBytes: &imageBytes)
        guard cellCount <= TerminalCheckpointLimits.cells else {
            throw TerminalCheckpointError.corrupt("checkpoint contains too many cells")
        }

        let parserByteCount = parser.osc.count + parser.apc.count + parser.parameterText.count
            + parser.collect.count + parser.pendingUtf8.count + parser.dcsData.count
        guard parserByteCount <= TerminalCheckpointLimits.parserBytes,
              parser.parameters.count <= TerminalCheckpointLimits.parserParameters,
              parser.pendingUtf8.count <= 4 else {
            throw TerminalCheckpointError.corrupt("parser state exceeds its bounds")
        }
        if parser.dcsHandler != nil && parser.dcsHandler != "decrqss" && parser.dcsHandler != "sixel" {
            throw TerminalCheckpointError.corrupt("unknown DCS handler")
        }

        var kittyImageBytes = 0
        var kittyIds = Set<UInt32>()
        for image in kitty.images {
            guard image.id > 0, kittyIds.insert(image.id).inserted,
                  image.byteSize >= 0, image.data.count == image.byteSize,
                  image.width >= 0, image.width <= 10_000,
                  image.height >= 0, image.height <= 10_000 else {
                throw TerminalCheckpointError.corrupt("Kitty image metadata is invalid")
            }
            if image.kind == 1 {
                guard image.width > 0, image.height > 0,
                      image.width <= Int.max / image.height / 4,
                      image.data.count == image.width * image.height * 4 else {
                    throw TerminalCheckpointError.corrupt("Kitty RGBA image size is invalid")
                }
            } else if image.kind != 0 {
                throw TerminalCheckpointError.corrupt("unknown Kitty image kind")
            }
            kittyImageBytes += image.data.count
        }
        imageBytes += kittyImageBytes
        guard imageBytes <= TerminalCheckpointLimits.imageBytes,
              kitty.totalImageBytes == kitty.images.reduce(0, { $0 + $1.byteSize }),
              kitty.pending?.base64Payload.count ?? 0 <= TerminalCheckpointLimits.parserBytes else {
            throw TerminalCheckpointError.corrupt("image state exceeds its bounds")
        }
        guard Set(kitty.imageNumbers.map(\.number)).count == kitty.imageNumbers.count,
              kitty.imageNumbers.allSatisfy({ kittyIds.contains($0.imageId) }),
              Set(kitty.placements.map { "\($0.imageId):\($0.placementId)" }).count == kitty.placements.count,
              kitty.placements.allSatisfy({ kittyIds.contains($0.imageId) }) else {
            throw TerminalCheckpointError.corrupt("Kitty references are invalid")
        }

        var graphemeIndexes = Set<Int32>()
        for entry in graphemes {
            guard entry.index > Int32(CharData.maxRune),
                  graphemeIndexes.insert(entry.index).inserted,
                  entry.character.count == 1 else {
                throw TerminalCheckpointError.corrupt("grapheme map is invalid")
            }
        }
        guard lastCharIndex >= Int32(CharData.maxRune + 1) else {
            throw TerminalCheckpointError.corrupt("grapheme allocation cursor is invalid")
        }
    }

    private func validateBuffer(_ buffer: CheckpointBuffer, expectedScrollback: Int?,
                                cellCount: inout Int, imageBytes: inout Int) throws {
        guard buffer.columns == columns, buffer.rows == rows,
              buffer.scrollback == expectedScrollback,
              buffer.lines.count <= TerminalCheckpointLimits.lines,
              buffer.maximumLines >= max(rows, buffer.lines.count),
              buffer.maximumLines <= TerminalCheckpointLimits.lines,
              buffer.scrollTop >= 0, buffer.scrollTop < rows,
              buffer.scrollBottom >= buffer.scrollTop, buffer.scrollBottom < rows,
              buffer.marginLeft >= 0, buffer.marginLeft < columns,
              buffer.marginRight >= buffer.marginLeft, buffer.marginRight < columns,
              buffer.tabStops.count >= columns,
              buffer.tabStops.count <= TerminalCheckpointLimits.columns,
              buffer.x >= 0, buffer.x <= columns,
              buffer.y >= 0, buffer.y < rows,
              buffer.yBase >= 0, buffer.yDisplay >= 0,
              buffer.yBase <= buffer.lines.count,
              buffer.yDisplay <= buffer.yBase else {
            throw TerminalCheckpointError.corrupt(
                "buffer geometry is invalid (cols=\(buffer.columns), rows=\(buffer.rows), lines=\(buffer.lines.count), max=\(buffer.maximumLines), x=\(buffer.x), y=\(buffer.y), yBase=\(buffer.yBase), yDisplay=\(buffer.yDisplay), scroll=\(buffer.scrollTop)...\(buffer.scrollBottom), margins=\(buffer.marginLeft)...\(buffer.marginRight), tabs=\(buffer.tabStops.count))"
            )
        }
        for line in buffer.lines {
            guard line.cellCount == columns,
                  line.cellData.count == line.cellCount * CheckpointCellCodec.encodedCellBytes else {
                throw TerminalCheckpointError.corrupt("line width does not match terminal width")
            }
            try line.hyperlinks.forEach(validateString)
            cellCount += line.cellCount
            for image in line.images {
                guard image.pixelWidth > 0, image.pixelHeight > 0,
                      image.column >= 0, image.column < columns else {
                    throw TerminalCheckpointError.corrupt("line image geometry is invalid")
                }
                imageBytes += image.data.count
            }
        }
    }

    private func validateCharset(_ charset: CheckpointCharset?) throws {
        guard let charset else { return }
        guard Set(charset.entries.map(\.key)).count == charset.entries.count else {
            throw TerminalCheckpointError.corrupt("charset has duplicate keys")
        }
        try charset.entries.forEach { try validateString($0.value) }
    }

    private func validateString(_ value: String?) throws {
        guard let value else { return }
        guard value.utf8.count <= TerminalCheckpointLimits.stringBytes else {
            throw TerminalCheckpointError.corrupt("string exceeds its bound")
        }
    }
}

extension Terminal {
    private func makeCheckpointState() throws -> TerminalCheckpointState {
        let hyperlinkPosition = hyperLinkTracking.map {
            CheckpointPosition(column: $0.start.col, row: $0.start.row)
        }
        return TerminalCheckpointState(
            columns: cols, rows: rows, tabStopWidth: tabStopWidth,
            options: Self.checkpointOptions(options),
            normalBuffer: try normalBuffer.makeCheckpoint(),
            alternateBuffer: try altBuffer.makeCheckpoint(),
            alternateActive: isCurrentBufferAlternate,
            synchronizedOutputActive: synchronizedOutputActive,
            synchronizedOutputRemainingNanoseconds: checkpointSynchronizedOutputRemainingNanoseconds(),
            applicationKeypad: applicationKeypad, applicationCursor: applicationCursor,
            keyboardNormal: CheckpointKeyboardMode(
                flags: keyboardModeNormal.flags.rawValue,
                stack: keyboardModeNormal.stack.map(\.rawValue)
            ),
            keyboardAlternate: CheckpointKeyboardMode(
                flags: keyboardModeAlt.flags.rawValue,
                stack: keyboardModeAlt.stack.map(\.rawValue)
            ),
            sendFocus: sendFocus, cursorHidden: cursorHidden, originMode: originMode,
            marginMode: marginMode, insertMode: insertMode, wraparound: wraparound,
            bracketedPasteMode: bracketedPasteMode,
            charset: charset.map(CheckpointCharset.init),
            gCharsets: gCharsets.map { $0.map(CheckpointCharset.init) },
            gcharset: gcharset, reverseWraparound: reverseWraparound,
            currentAttribute: CheckpointAttribute(curAttr),
            graphemes: indexToCharMap.map {
                CheckpointGrapheme(index: $0.key, character: String($0.value))
            }.sorted { $0.index < $1.index },
            lastCharIndex: lastCharIndex, gLevel: gLevel, cursorBlink: cursorBlink,
            allow80To132: allow80To132,
            parser: try parser.makeCheckpoint(pendingUtf8: readingBuffer.putbackBuffer),
            kitty: kittyGraphicsState.makeCheckpoint(),
            userScrolling: userScrolling, lineFeedMode: lineFeedMode, smoothScroll: smoothScroll,
            installedColors: installedColors.map(CheckpointColor.init),
            defaultAnsiColors: defaultAnsiColors.map(CheckpointColor.init),
            ansiColors: ansiColors.map(CheckpointColor.init), send8BitControls: cc.send8bit,
            hostCurrentDirectory: hostCurrentDirectory, hostCurrentDocument: hostCurrentDocument,
            mouseProtocol: checkpointMouseProtocol(),
            foregroundColor: CheckpointColor(foregroundColor),
            backgroundColor: CheckpointColor(backgroundColor),
            cursorColor: cursorColor.map(CheckpointColor.init),
            reportedFocusState: reportedFocusState, mouseMode: checkpointMouseMode(),
            mouseShiftCapture: mouseShiftCapture,
            xtermTitleSetUtf: xtermTitleSetUtf, xtermTitleSetHex: xtermTitleSetHex,
            xtermTitleQueryUtf: xtermTitleQueryUtf, xtermTitleQueryHex: xtermTitleQueryHex,
            conformance: checkpointConformance(), lastBufferCol: lastBufferCol, silentLog: silentLog,
            hyperlinkStart: hyperlinkPosition, hyperlinkPayload: hyperLinkTracking?.payload,
            terminalTitle: terminalTitle, iconTitle: iconTitle,
            terminalTitleStack: terminalTitleStack, terminalIconStack: terminalIconStack
        )
    }

    private static func checkpointOptions(_ options: TerminalOptions) -> CheckpointOptions {
        let cursorStyle: Int
        switch options.cursorStyle {
        case .blinkBlock: cursorStyle = 0
        case .steadyBlock: cursorStyle = 1
        case .blinkUnderline: cursorStyle = 2
        case .steadyUnderline: cursorStyle = 3
        case .blinkBar: cursorStyle = 4
        case .steadyBar: cursorStyle = 5
        }
        let palette: Int
        switch options.ansi256PaletteStrategy {
        case .xterm: palette = 0
        case .base16Lab: palette = 1
        case .base16LabHarmonious: palette = 2
        }
        return CheckpointOptions(
            cols: options.cols, rows: options.rows, convertEol: options.convertEol,
            termName: options.termName, cursorStyle: cursorStyle,
            screenReaderMode: options.screenReaderMode, scrollback: options.scrollback,
            tabStopWidth: options.tabStopWidth, enableSixelReported: options.enableSixelReported,
            kittyImageCacheLimitBytes: options.kittyImageCacheLimitBytes,
            ansi256PaletteStrategy: palette,
            regionalIndicatorWidth: options.regionalIndicatorWidth == .wide ? 0 : 1
        )
    }

    private func checkpointSynchronizedOutputRemainingNanoseconds() -> UInt64? {
        guard synchronizedOutputActive,
              let deadline = synchronizedOutputDeadlineUptimeNanoseconds else {
            return nil
        }
        let now = DispatchTime.now().uptimeNanoseconds
        return deadline > now ? deadline - now : 0
    }

    private static func restoreOptions(_ value: CheckpointOptions) throws -> TerminalOptions {
        let cursorStyle: CursorStyle
        switch value.cursorStyle {
        case 0: cursorStyle = .blinkBlock
        case 1: cursorStyle = .steadyBlock
        case 2: cursorStyle = .blinkUnderline
        case 3: cursorStyle = .steadyUnderline
        case 4: cursorStyle = .blinkBar
        case 5: cursorStyle = .steadyBar
        default: throw TerminalCheckpointError.corrupt("unknown cursor style")
        }
        let palette: Ansi256PaletteStrategy
        switch value.ansi256PaletteStrategy {
        case 0: palette = .xterm
        case 1: palette = .base16Lab
        case 2: palette = .base16LabHarmonious
        default: throw TerminalCheckpointError.corrupt("unknown palette strategy")
        }
        let regional: RegionalIndicatorWidth
        switch value.regionalIndicatorWidth {
        case 0: regional = .wide
        case 1: regional = .narrow
        default: throw TerminalCheckpointError.corrupt("unknown regional indicator width")
        }
        return TerminalOptions(
            cols: value.cols, rows: value.rows, convertEol: value.convertEol,
            termName: value.termName, cursorStyle: cursorStyle,
            screenReaderMode: value.screenReaderMode, scrollback: value.scrollback,
            tabStopWidth: value.tabStopWidth, enableSixelReported: value.enableSixelReported,
            kittyImageCacheLimitBytes: value.kittyImageCacheLimitBytes,
            ansi256PaletteStrategy: palette, regionalIndicatorWidth: regional
        )
    }

    private func checkpointMouseProtocol() -> Int {
        switch mouseProtocol {
        case .x10: return 0
        case .utf8: return 1
        case .sgr: return 2
        case .urxvt: return 3
        case .sgrPixel: return 4
        }
    }

    private static func restoreMouseProtocol(_ value: Int) throws -> MouseProtocolEncoding {
        switch value {
        case 0: return .x10
        case 1: return .utf8
        case 2: return .sgr
        case 3: return .urxvt
        case 4: return .sgrPixel
        default: throw TerminalCheckpointError.corrupt("unknown mouse protocol")
        }
    }

    private func checkpointMouseMode() -> Int {
        switch mouseMode {
        case .off: return 0
        case .x10: return 1
        case .vt200: return 2
        case .buttonEventTracking: return 3
        case .anyEvent: return 4
        }
    }

    private static func restoreMouseMode(_ value: Int) throws -> MouseMode {
        switch value {
        case 0: return .off
        case 1: return .x10
        case 2: return .vt200
        case 3: return .buttonEventTracking
        case 4: return .anyEvent
        default: throw TerminalCheckpointError.corrupt("unknown mouse mode")
        }
    }

    private func checkpointConformance() -> Int {
        switch conformance {
        case .vt100: return 0
        case .vt200: return 1
        case .vt300: return 2
        case .vt400: return 3
        case .vt500: return 4
        }
    }

    private static func restoreConformance(_ value: Int) throws -> TerminalConformance {
        switch value {
        case 0: return .vt100
        case 1: return .vt200
        case 2: return .vt300
        case 3: return .vt400
        case 4: return .vt500
        default: throw TerminalCheckpointError.corrupt("unknown terminal conformance")
        }
    }
}
