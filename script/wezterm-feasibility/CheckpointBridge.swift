// Throwaway bridge, compiled inside a scratch SwiftTerm module for internal DTO access.
import Foundation

private struct BridgeAttribute: Decodable {
    let fg: [UInt8], bg: [UInt8], style: UInt8, underline: UInt8
    let underlineColor: [UInt8]
    let link: String?
    func value() throws -> Attribute {
        func color(_ c: [UInt8]) throws -> Attribute.Color {
            guard c.count == 4 else { throw TerminalCheckpointError.corrupt("bridge color") }
            return try CheckpointAttributeColor(kind: c[0], first: c[1], second: c[2], third: c[3]).value()
        }
        guard let u = UnderlineStyle(rawValue: underline) else {
            throw TerminalCheckpointError.corrupt("bridge underline")
        }
        return try Attribute(fg: color(fg), bg: color(bg), style: CharacterStyle(rawValue: style),
                             underlineStyle: u, underlineColor: underlineColor.first == 2 ? nil : color(underlineColor))
    }
}
private struct BridgeCell: Decodable { let x: Int, text: String, width: Int, repetitions: Int, attribute: BridgeAttribute }
private struct BridgeLine: Decodable { let wrapped: Bool, cells: [BridgeCell], width: Int, images: [BridgeGraphicPlacement] }
private struct BridgeSaved: Decodable { let x: Int, y: Int, wrapNext: Bool, origin: Bool, pen: BridgeAttribute; let wrap: Bool, reverseWrap: Bool, margin: Bool }
private struct BridgeBuffer: Decodable { let lines: [BridgeLine], saved: BridgeSaved?, margins: [Int], defaultSavedY: Int }
private struct BridgeModes: Decodable {
    let applicationCursor: Bool, applicationKeypad: Bool, origin: Bool, margin: Bool, insert: Bool
    let wrap: Bool, reverseWrap: Bool, paste: Bool, focus: Bool, cursorHidden: Bool, newline: Bool
    let mouse: Int, mouseProtocol: Int
}
private struct BridgeKeyboard: Decodable { let flags: Int, stack: [Int] }
private struct BridgeKittyImage: Decodable { let id: UInt32, rgba: [UInt8], width: Int, height: Int }
private struct BridgeKittyNumber: Decodable { let number: UInt32, id: UInt32 }
private struct BridgeKittyPlacementBuffer: Decodable { let id: UInt32, placement: UInt32?, alternate: Bool }
private struct BridgeKitty: Decodable { let pendingCommands: [[UInt8]], images: [BridgeKittyImage], numbers: [BridgeKittyNumber]; let placementBuffers: [BridgeKittyPlacementBuffer] }
private struct BridgeState: Decodable {
    let columns: Int, rows: Int, normal: BridgeBuffer, alternate: BridgeBuffer, alternateActive: Bool
    let cursor: [Int], wrapNext: Bool, pen: BridgeAttribute, title: String, iconTitle: String?
    let tabs: [Bool], tabWidth: Int, margins: [Int], modes: BridgeModes, directory: String?
    let cursorStyle: Int
    let lastStorage: [[Int]?]
    let keyboard: [BridgeKeyboard]
    let graphics: [BridgeGraphicResource], cellPixels: [Int]
    let kitty: BridgeKitty
}
private struct BridgeEnvelope: Decodable {
    let version: Int, sequence: Int, state: BridgeState, pending: [UInt8]
}
private final class BridgeTemplateDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

extension Terminal {
    /// Returns the committed sequence. Transport must deliver exactly sequence + 1 next.
    /// Delegate callbacks are disconnected during import and token restoration.
    public func importRustPrototypeCheckpoint(_ data: Data, geometry: TerminalImageGeometry) throws -> Int {
        guard data.count <= 1_048_576 else { throw TerminalCheckpointError.corrupt("bridge byte limit") }
        let envelope = try JSONDecoder().decode(BridgeEnvelope.self, from: data)
        let s = envelope.state
        guard envelope.version == 2, envelope.sequence >= 0, envelope.sequence < Int.max,
              (2...1000).contains(s.columns), (1...1000).contains(s.rows),
              s.cursor.count == 2, s.margins.count == 4, s.lastStorage.count == 2, s.keyboard.count == 2,
              s.keyboard.allSatisfy({$0.stack.count <= 128}), s.tabs.count >= s.columns,
              s.tabs.count <= 1000, (1...1000).contains(s.tabWidth),
              envelope.pending.count <= 16384 else {
            throw TerminalCheckpointError.corrupt("bridge envelope bounds")
        }
        guard (0...s.columns).contains(s.cursor[0]), (0..<s.rows).contains(s.cursor[1]),
              !s.wrapNext || s.cursor[0] < s.columns else {
            throw TerminalCheckpointError.corrupt("bridge cursor bounds")
        }
        guard s.margins[0] >= 0, s.margins[1] > s.margins[0], s.margins[1] <= s.rows,
              s.margins[2] >= 0, s.margins[3] > s.margins[2], s.margins[3] <= s.columns else {
            throw TerminalCheckpointError.corrupt("bridge margin bounds")
        }
        let pending = envelope.pending
        if !pending.isEmpty {
            let csi = pending.starts(with: [27, 91]) && pending.dropFirst(2).allSatisfy { (0x20...0x3f).contains($0) }
            let terminatorPending = pending.last == 27 && pending.count > 1
            let graphicsBody = terminatorPending ? Array(pending.dropLast()) : pending
            let osc = graphicsBody.starts(with: [27, 93]) && graphicsBody.dropFirst(2).allSatisfy { $0 >= 0x20 }
            let dcs = Array(graphicsBody.dropFirst(2))
            let finalIndex = dcs.firstIndex(where: { !(0x30...0x3f).contains($0) })
            let sixel = graphicsBody.starts(with: [27, 80]) && (finalIndex.map {
                dcs[$0] == 0x71 && dcs.dropFirst($0+1).allSatisfy { (0x20...0x7e).contains($0) }
            } ?? true)
            let lead = pending[0]
            var utf8 = (0xc2...0xf4).contains(lead) && pending.dropFirst().allSatisfy { (0x80...0xbf).contains($0) }
                && pending.count < (lead < 0xe0 ? 2 : lead < 0xf0 ? 3 : 4)
            if pending.count > 1 {
                utf8 = utf8 && !(lead == 0xe0 && pending[1] < 0xa0)
                    && !(lead == 0xed && pending[1] >= 0xa0)
                    && !(lead == 0xf0 && pending[1] < 0x90)
                    && !(lead == 0xf4 && pending[1] >= 0x90)
            }
            guard pending == [27] || csi || osc || utf8 || sixel else {
                throw TerminalCheckpointError.corrupt("bridge token is complete or unsupported")
            }
        }
        // A separate new terminal supplies defaults and grapheme allocation.
        // Importing must never inherit palette, parser or mode state from self.
        let templateDelegate = BridgeTemplateDelegate()
        var templateOptions = TerminalOptions.default
        templateOptions.cols = 20; templateOptions.rows = 6; templateOptions.scrollback = 40
        let freshTerminal = Terminal(delegate: templateDelegate, options: templateOptions)
        var native = try PropertyListDecoder().decode(TerminalCheckpointEnvelope.self, from: freshTerminal.exportCheckpoint()).state
        guard s.kitty.pendingCommands.count <= 128,
              s.kitty.pendingCommands.reduce(0, {$0+$1.count}) <= 16384 else {
            throw TerminalCheckpointError.corrupt("bridge pending Kitty limit")
        }
        for command in s.kitty.pendingCommands {
            guard command.starts(with: [27,95,71]), command.suffix(2) == [27,92] else {
                throw TerminalCheckpointError.corrupt("bridge pending Kitty command")
            }
            guard let text = String(bytes: command.dropFirst(3).dropLast(2), encoding: .ascii),
                  let divider = text.firstIndex(of: ";") else { throw TerminalCheckpointError.corrupt("bridge pending Kitty syntax") }
            let payload = text[text.index(after: divider)...]
            guard payload.utf8.allSatisfy({(65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || $0==43 || $0==47 || $0==61}) else {
                throw TerminalCheckpointError.corrupt("bridge pending Kitty payload")
            }
            var controls: [String:String] = [:]
            for entry in text[..<divider].split(separator: ",") {
                let pair = entry.split(separator: "=",omittingEmptySubsequences: false)
                guard pair.count==2, controls[String(pair[0])]==nil else { throw TerminalCheckpointError.corrupt("bridge pending Kitty keys") }
                controls[String(pair[0])] = String(pair[1])
            }
            guard controls["a"] == nil || controls["a"] == "t" || controls["a"] == "T", controls["m"] == "1", controls["t"] == nil || controls["t"] == "d",
                  Set(controls.keys).isSubset(of: ["a","f","s","v","i","I","m","q","o","t","p","c","r","C","z"]) else {
                throw TerminalCheckpointError.corrupt("bridge Kitty requires unfinished direct transmission")
            }
            freshTerminal.feed(byteArray: command)
        }
        if !s.kitty.pendingCommands.isEmpty {
            let transfer = try PropertyListDecoder().decode(TerminalCheckpointEnvelope.self, from: freshTerminal.exportCheckpoint()).state
            guard transfer.kitty.images.isEmpty, transfer.kitty.placements.isEmpty, transfer.kitty.pending != nil else {
                throw TerminalCheckpointError.corrupt("bridge Kitty transfer must remain unfinished")
            }
            native.kitty = transfer.kitty
        }
        guard s.kitty.images.count <= 32, s.kitty.numbers.count <= 32 else { throw TerminalCheckpointError.corrupt("bridge Kitty cache count") }
        var kittyBytes = 0
        var ids = Set<UInt32>()
        native.kitty.images = try s.kitty.images.enumerated().map { index, image in
            guard ids.insert(image.id).inserted, (1...2048).contains(image.width), (1...2048).contains(image.height),
                  image.rgba.count == image.width*image.height*4 else { throw TerminalCheckpointError.corrupt("bridge Kitty cache image") }
            kittyBytes += image.rgba.count
            guard kittyBytes <= 262144 else { throw TerminalCheckpointError.corrupt("bridge Kitty cache byte limit") }
            return CheckpointKittyImage(id: image.id,kind: 1,data: Data(image.rgba),width: image.width,height: image.height,
                byteSize: image.rgba.count,lastAccessTick: UInt64(index+1))
        }
        native.kitty.imageNumbers = try s.kitty.numbers.map { number in
            guard ids.contains(number.id) else { throw TerminalCheckpointError.corrupt("bridge Kitty number reference") }
            return CheckpointKittyNumber(number: number.number,imageId: number.id)
        }
        native.kitty.totalImageBytes = kittyBytes
        native.kitty.nextImageAccessTick = UInt64(s.kitty.images.count+1)
        native.columns = s.columns; native.rows = s.rows
        native.options.cols = s.columns; native.options.rows = s.rows
        native.options.scrollback = 40; native.tabStopWidth = s.tabWidth
        native.options.cursorStyle = s.cursorStyle
        native.alternateActive = s.alternateActive
        native.keyboardNormal = CheckpointKeyboardMode(flags: s.keyboard[0].flags, stack: s.keyboard[0].stack)
        native.keyboardAlternate = CheckpointKeyboardMode(flags: s.keyboard[1].flags, stack: s.keyboard[1].stack)
        native.applicationCursor = s.modes.applicationCursor
        native.applicationKeypad = s.modes.applicationKeypad
        native.originMode = s.modes.origin; native.marginMode = s.modes.margin
        native.insertMode = s.modes.insert; native.wraparound = s.modes.wrap
        native.reverseWraparound = s.modes.reverseWrap; native.bracketedPasteMode = s.modes.paste
        native.sendFocus = s.modes.focus; native.cursorHidden = s.modes.cursorHidden
        native.lineFeedMode = s.modes.newline; native.mouseMode = s.modes.mouse
        native.mouseProtocol = s.modes.mouseProtocol
        native.currentAttribute = try CheckpointAttribute(s.pen.value())
        native.terminalTitle = s.title; native.iconTitle = s.iconTitle ?? ""
        native.hostCurrentDirectory = s.directory
        let renderedResources = try bridgeRenderResources(s.graphics, cellPixels: s.cellPixels, columns: s.columns,
            authoritativeGeometry: geometry)
        var cellBudget = 0
        func buffer(_ source: BridgeBuffer, _ template: CheckpointBuffer, active: Bool, normal: Bool) throws -> CheckpointBuffer {
            guard source.lines.count >= s.rows, source.lines.count <= s.rows + (normal ? 40 : 0),
                  source.margins.count == 4, source.margins[0] >= 0, source.margins[1] > source.margins[0],
                  source.margins[1] <= s.rows, source.margins[2] >= 0, source.margins[3] > source.margins[2],
                  source.margins[3] <= s.columns, (0..<s.rows).contains(source.defaultSavedY) else {
                throw TerminalCheckpointError.corrupt("bridge line limit")
            }
            if let saved = source.saved {
                guard (0...s.columns).contains(saved.x), (0..<s.rows).contains(saved.y),
                      !saved.wrapNext || saved.x < s.columns else {
                    throw TerminalCheckpointError.corrupt("bridge saved cursor bounds")
                }
            }
            var result = template
            result.columns = s.columns; result.rows = s.rows
            result.scrollback = normal ? 40 : nil
            result.maximumLines = s.rows + (normal ? 40 : 0)
            result.yBase = source.lines.count - s.rows; result.yDisplay = result.yBase
            result.xBase = 0; result.xDisplay = 0; result.linesTop = 0
            result.x = active ? s.cursor[0] + (s.wrapNext ? 1 : 0) : source.saved?.x ?? 0
            result.y = active ? s.cursor[1] : source.saved?.y ?? 0
            result.scrollTop = source.margins[0]; result.scrollBottom = source.margins[1] - 1
            result.marginLeft = source.margins[2]; result.marginRight = source.margins[3] - 1
            result.tabStops = Array(s.tabs.prefix(s.columns))
            result.savedX = (source.saved?.x ?? 0) + (source.saved?.wrapNext == true ? 1 : 0)
            result.savedY = source.saved?.y ?? source.defaultSavedY
            result.savedOriginMode = source.saved?.origin ?? false
            result.savedMarginMode = source.saved?.margin ?? false
            result.savedAttribute = try CheckpointAttribute(source.saved?.pen.value() ?? Attribute.empty)
            result.currentAttribute = native.currentAttribute
            result.insertMode = s.modes.insert; result.marginMode = s.modes.margin; result.wraparound = s.modes.wrap
            if source.saved != nil {
                result.savedWraparound = source.saved?.wrap ?? false
                result.savedReverseWraparound = source.saved?.reverseWrap ?? false
            }
            if let storage = s.lastStorage[normal ? 0 : 1] {
                guard storage.count == 4, storage[0] >= 0, storage[0] < 1000,
                      storage[1] >= 0, storage[1] < source.lines.count,
                      (2...1000).contains(storage[2]), (1...1000).contains(storage[3]) else {
                    throw TerminalCheckpointError.corrupt("bridge last-storage bounds")
                }
                result.lastStorageX = storage[0]; result.lastStorageY = storage[1]
                result.lastStorageColumns = storage[2]; result.lastStorageRows = storage[3]
            }
            result.lines = try source.lines.enumerated().map { index, line in
                guard line.width >= s.columns, line.width <= 1000, !normal || line.width == s.columns else {
                    throw TerminalCheckpointError.corrupt("bridge stored width")
                }
                cellBudget += line.width
                guard cellBudget <= 100000 else { throw TerminalCheckpointError.corrupt("bridge cell limit") }
                var cells = Array(repeating: CharData(attribute: .empty), count: line.width)
                var nextColumn = 0
                for c in line.cells {
                    guard c.x >= nextColumn, c.x < line.width, (1...2).contains(c.width),
                          (1...1000).contains(c.repetitions), c.width == 1 || c.repetitions == 1,
                          c.width * c.repetitions <= line.width - c.x,
                          c.text.count == 1, let character = c.text.first else {
                        throw TerminalCheckpointError.corrupt("bridge cell geometry or grapheme")
                    }
                    var value = try freshTerminal.makeCharData(attribute: c.attribute.value(), char: character, size: Int8(c.width))
                    if let link = c.attribute.link {
                        guard let atom = TinyAtom.lookupCheckpointHyperlink(link) else {
                            throw TerminalCheckpointError.corrupt("bridge hyperlink table full")
                        }
                        value.setPayload(atom: atom)
                    }
                    for column in c.x..<(c.x + c.width * c.repetitions) { cells[column] = value }
                    if c.width == 2 { cells[c.x + 1] = CharData(attribute: value.attribute, code: 0, size: 0) }
                    nextColumn = c.x + c.width * c.repetitions
                }
                let encoded = try CheckpointCellCodec.encode(cells)
                let ownedImages = line.images.filter { placement in
                    guard let id = placement.imageId else { return true }
                    return s.kitty.placementBuffers.contains(where: {
                        $0.id == id && $0.placement == placement.placementId && $0.alternate == !normal
                    })
                }
                let images = try ownedImages.map { placement -> CheckpointImage in
                    guard let stripes = renderedResources[placement.resource], stripes.indices.contains(placement.stripe),
                          (0..<line.width).contains(placement.column) else { throw TerminalCheckpointError.corrupt("bridge image placement") }
                    var image = stripes[placement.stripe]
                    image.column = placement.column
                    image.isKitty = placement.imageId != nil
                    image.imageId = placement.imageId; image.placementId = placement.placementId
                    image.zIndex = placement.zIndex
                    if image.isKitty {
                        guard placement.placementId != nil, let resource = s.graphics.first(where: {$0.key == placement.resource}) else {
                            throw TerminalCheckpointError.corrupt("bridge Kitty placement identity")
                        }
                        image.kittyColumn = placement.column; image.kittyRow = index-placement.stripe
                        image.kittyColumns = (resource.displayWidth+s.cellPixels[0]-1)/s.cellPixels[0]
                        image.kittyRows = stripes.count
                        image.imageNumber = s.kitty.numbers.first(where: {$0.id == placement.imageId})?.number
                    }
                    return image
                }
                return CheckpointLine(isWrapped: index > 0 && source.lines[index - 1].wrapped, renderMode: 0,
                    fillCharacter: try CheckpointCell(CharData(attribute: .empty)), cellCount: line.width,
                    cellData: encoded.data, hyperlinks: encoded.hyperlinks, images: images, generation: 0)
            }
            return result
        }
        native.normalBuffer = try buffer(s.normal, native.normalBuffer, active: !s.alternateActive, normal: true)
        native.alternateBuffer = try buffer(s.alternate, native.alternateBuffer, active: s.alternateActive, normal: false)
        var placementKeys = Set<String>()
        native.kitty.placements = []
        for (alternate,buffer) in [(false,native.normalBuffer),(true,native.alternateBuffer)] {
            for line in buffer.lines { for image in line.images where image.isKitty {
                guard let id = image.imageId, let placement = image.placementId, ids.contains(id) else {
                    throw TerminalCheckpointError.corrupt("bridge Kitty placement reference")
                }
                guard let owner = s.kitty.placementBuffers.first(where: {$0.id == id && $0.placement == placement}) else {
                    throw TerminalCheckpointError.corrupt("bridge Kitty placement owner")
                }
                if owner.alternate != alternate { continue }
                let key = "\(id):\(placement)"
                if placementKeys.insert(key).inserted {
                    native.kitty.placements.append(CheckpointKittyPlacement(imageId: id,placementId: placement,
                        parentImageId: nil,parentPlacementId: nil,parentOffsetH: 0,parentOffsetV: 0,pixelOffsetX: 0,pixelOffsetY: 0,
                        column: image.kittyColumn,row: image.kittyRow,columns: image.kittyColumns,rows: image.kittyRows,
                        zIndex: image.zIndex,isVirtual: false,isAlternateBuffer: alternate))
                }
            }}
        }
        native.graphemes = freshTerminal.indexToCharMap.map { CheckpointGrapheme(index: $0.key, character: String($0.value)) }
        native.lastCharIndex = freshTerminal.lastCharIndex
        try native.validate()
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let savedDelegate = tdel
        tdel = nil
        defer { tdel = savedDelegate }
        try importCheckpoint(encoder.encode(TerminalCheckpointEnvelope(version: 1, state: native)))
        // Only the bounded *unfinished* parser token is replayed, never session
        // history. Completed queries, bells, clipboard commands and images are absent.
        feed(byteArray: envelope.pending)
        return envelope.sequence
    }
}
