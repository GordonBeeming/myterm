#if os(macOS)
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
private struct BridgeLine: Decodable { let wrapped: Bool, cells: Data, width: Int, images: [BridgeGraphicPlacement] }
private struct BridgeSaved: Decodable { let x: Int, y: Int, wrapNext: Bool, origin: Bool, pen: BridgeAttribute; let wrap: Bool, reverseWrap: Bool, margin: Bool }
private struct BridgeBuffer: Decodable { let lines: [BridgeLine], firstWrapped: Bool?, cursor: [Int]?, saved: BridgeSaved?, margins: [Int], defaultSavedY: Int }
private struct BridgeModes: Decodable {
    let applicationCursor: Bool, applicationKeypad: Bool, origin: Bool, margin: Bool, insert: Bool
    let wrap: Bool, reverseWrap: Bool, paste: Bool, focus: Bool, cursorHidden: Bool, newline: Bool
    let mouse: Int, mouseProtocol: Int
}
private struct BridgeKeyboard: Decodable { let flags: Int, stack: [Int] }
private struct BridgeKittyImage: Decodable { let id: UInt32, rgba: BridgeImageBytes, width: Int, height: Int }
private struct BridgeKittyNumber: Decodable { let number: UInt32, id: UInt32 }
private struct BridgeKittyPlacementBuffer: Decodable {
    let id: UInt32, placement: UInt32?, alternate: Bool
    let parentImageId: UInt32?, parentPlacementId: UInt32?, parentOffsetH: Int?, parentOffsetV: Int?, isVirtual: Bool?
    let column: Int, row: Int, imageColumn: Int, imageRow: Int, columns: Int, rows: Int, zIndex: Int, pixelOffsetX: Int, pixelOffsetY: Int
}
private struct BridgeRelativeResource: Decodable { let id: UInt32, placement: UInt32, resource: String }
private struct BridgeKitty: Decodable { let pendingCommands: [[UInt8]], images: [BridgeKittyImage], numbers: [BridgeKittyNumber]; let placementBuffers: [BridgeKittyPlacementBuffer]; let nextPlacementId: UInt32?; let nextImageId: UInt32?; let relativeResources: [BridgeRelativeResource]? }
private struct BridgeState: Decodable {
    let scrollback: Int, omittedScrollbackLines: Int?, attributes: [BridgeAttribute]
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
    let version: Int, sequence: UInt64, state: BridgeState, pending: [UInt8]

    static func decode(_ data: Data) throws -> BridgeEnvelope {
        guard data.count <= TerminalCheckpointLimits.encodedBytes else {
            throw TerminalCheckpointError.checkpointTooLarge(actual: data.count, maximum: TerminalCheckpointLimits.encodedBytes)
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func imageGeometry(displayScale: CGFloat) throws -> TerminalImageGeometry {
        guard state.cellPixels.count == 2, state.cellPixels.allSatisfy({ (1...1024).contains($0) }),
              (2...1000).contains(state.columns), (1...1000).contains(state.rows),
              displayScale.isFinite, (0.1...8).contains(displayScale) else {
            throw TerminalCheckpointError.corrupt("bridge image geometry")
        }
        let width = CGFloat(state.cellPixels[0]) / displayScale
        let height = CGFloat(state.cellPixels[1]) / displayScale
        return TerminalImageGeometry(
            cellSize: CGSize(width: width, height: height),
            viewportSize: CGSize(width: width * CGFloat(state.columns), height: height * CGFloat(state.rows)),
            displayScale: displayScale
        )
    }
}
private final class BridgeTemplateDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

extension Terminal {
    fileprivate func importWezTermCheckpoint(_ envelope: BridgeEnvelope, expectedSequence: UInt64,
                                              geometry: TerminalImageGeometry) throws {
        let s = envelope.state
        let omitted = s.omittedScrollbackLines ?? 0
        guard envelope.version == 3 else { throw TerminalCheckpointError.unsupportedVersion(envelope.version) }
        guard envelope.sequence == expectedSequence, expectedSequence < UInt64.max,
              (2...1000).contains(s.columns), (1...1000).contains(s.rows),
              (0...100_000).contains(s.scrollback), (0...s.scrollback).contains(omitted),
              s.attributes.count <= TerminalCheckpointLimits.cells,
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
        var unfinishedGraphics = false
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
            let oscCommand = graphicsBody.dropFirst(2).prefix { (0x30...0x39).contains($0) }
            unfinishedGraphics = sixel || (osc && Int(String(decoding: oscCommand, as: UTF8.self)) == 1337)
        }
        // A separate new terminal supplies defaults and grapheme allocation.
        // Importing must never inherit palette, parser or mode state from self.
        let templateDelegate = BridgeTemplateDelegate()
        var templateOptions = TerminalOptions.default
        templateOptions.cols = s.columns; templateOptions.rows = s.rows; templateOptions.scrollback = s.scrollback
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
                  Set(controls.keys).isSubset(of: ["a","f","s","v","i","I","m","q","o","t","p","c","r","C","z","U","P","Q","H","V","x","y","w","h","X","Y"]) else {
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
        guard s.kitty.images.count <= 2048, s.kitty.numbers.count <= 2048 else { throw TerminalCheckpointError.corrupt("bridge Kitty cache count") }
        var kittyBytes = 0
        var ids = Set<UInt32>()
        native.kitty.images = try s.kitty.images.enumerated().map { index, image in
            guard ids.insert(image.id).inserted, (1...10_000).contains(image.width), (1...10_000).contains(image.height),
                  image.rgba.data.count == image.width*image.height*4 else { throw TerminalCheckpointError.corrupt("bridge Kitty cache image") }
            kittyBytes += image.rgba.data.count
            guard kittyBytes <= TerminalCheckpointLimits.imageBytes else { throw TerminalCheckpointError.corrupt("bridge Kitty cache byte limit") }
            return CheckpointKittyImage(id: image.id,kind: 1,data: image.rgba.data,width: image.width,height: image.height,
                byteSize: image.rgba.data.count,lastAccessTick: UInt64(index+1))
        }
        native.kitty.imageNumbers = try s.kitty.numbers.map { number in
            guard ids.contains(number.id) else { throw TerminalCheckpointError.corrupt("bridge Kitty number reference") }
            return CheckpointKittyNumber(number: number.number,imageId: number.id)
        }
        native.kitty.nextImageId = s.kitty.nextImageId ?? 1
        native.kitty.nextPlacementId = s.kitty.nextPlacementId ?? 1
        native.kitty.totalImageBytes = kittyBytes
        native.kitty.nextImageAccessTick = UInt64(s.kitty.images.count+1)
        native.columns = s.columns; native.rows = s.rows
        native.options.cols = s.columns; native.options.rows = s.rows
        native.options.scrollback = s.scrollback; native.tabStopWidth = s.tabWidth
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
        let requiresExactGeometry = unfinishedGraphics || !s.kitty.pendingCommands.isEmpty
            || !s.kitty.images.isEmpty || !s.kitty.placementBuffers.isEmpty || s.kitty.relativeResources?.isEmpty == false
        let renderedResources = try bridgeRenderResources(
            s.graphics, cellPixels: s.cellPixels, columns: s.columns,
            authoritativeGeometry: geometry, requiresExactGeometry: requiresExactGeometry
        )
        let attributes = try s.attributes.map { try $0.value() }
        var cellBudget = 0
        var packedCellBytes = 0
        func buffer(_ source: BridgeBuffer, _ template: CheckpointBuffer, active: Bool, normal: Bool) throws -> CheckpointBuffer {
            // Alternate saved rows can outlive a height shrink; restore clamps
            // the live cursor. Bound retained rows by the experiment's maximum height.
            let savedRows = normal ? s.rows : 1000
            guard source.lines.count >= s.rows, source.lines.count <= s.rows + (normal ? s.scrollback - omitted : 0),
                  source.margins.count == 4, source.margins[0] >= 0, source.margins[1] > source.margins[0],
                  source.margins[1] <= s.rows, source.margins[2] >= 0, source.margins[3] > source.margins[2],
                  source.margins[3] <= s.columns, (0..<savedRows).contains(source.defaultSavedY) else {
                throw TerminalCheckpointError.corrupt("bridge line limit")
            }
            if let saved = source.saved {
                guard (0...s.columns).contains(saved.x), (0..<savedRows).contains(saved.y),
                      !saved.wrapNext || saved.x < s.columns else {
                    throw TerminalCheckpointError.corrupt("bridge saved cursor bounds")
                }
            }
            if let cursor = source.cursor {
                guard cursor.count == 2, (0...s.columns).contains(cursor[0]), (0..<s.rows).contains(cursor[1]) else {
                    throw TerminalCheckpointError.corrupt("bridge inactive cursor bounds")
                }
            }
            var result = template
            result.columns = s.columns; result.rows = s.rows
            result.scrollback = normal ? s.scrollback : nil
            result.maximumLines = s.rows + (normal ? s.scrollback : 0)
            result.yBase = source.lines.count - s.rows; result.yDisplay = result.yBase
            result.xBase = 0; result.xDisplay = 0; result.linesTop = normal ? omitted : 0
            result.x = active ? s.cursor[0] + (s.wrapNext ? 1 : 0) : source.cursor?[0] ?? source.saved?.x ?? 0
            result.y = active ? s.cursor[1] : source.cursor?[1] ?? source.saved?.y ?? 0
            result.scrollTop = source.margins[0]; result.scrollBottom = source.margins[1] - 1
            result.marginLeft = source.margins[2]; result.marginRight = source.margins[3] - 1
            result.tabStops = Array(s.tabs.prefix(s.columns))
            result.savedX = (source.saved?.x ?? 0) + (source.saved?.wrapNext == true ? 1 : 0)
            result.savedY = source.saved?.y ?? source.defaultSavedY
            result.savedOriginMode = source.saved?.origin ?? false
            result.savedMarginMode = source.saved?.margin ?? false
            result.savedAttribute = try CheckpointAttribute(source.saved?.pen.value() ?? CharData.defaultAttr)
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
                packedCellBytes += line.cells.count
                guard cellBudget <= TerminalCheckpointLimits.cells, packedCellBytes <= 24 * 1024 * 1024 else {
                    throw TerminalCheckpointError.corrupt("bridge cell limit")
                }
                var cells = Array(repeating: CharData(attribute: CharData.defaultAttr), count: line.width)
                try line.cells.withUnsafeBytes { bytes in
                    // Each run contains a column, repetition count, attribute-table index,
                    // cell width and a length-prefixed UTF-8 grapheme.
                    let headerSize = 13
                    var nextColumn = 0
                    var offset = 0
                    while offset < bytes.count {
                        guard bytes.count - offset >= headerSize else {
                            throw TerminalCheckpointError.corrupt("bridge cell header")
                        }
                        let column = Int(UInt16(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self)))
                        let repetitions = Int(UInt16(bigEndian: bytes.loadUnaligned(fromByteOffset: offset + 2, as: UInt16.self)))
                        let attributeIndex = Int(UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset + 4, as: UInt32.self)))
                        let width = Int(bytes[offset + 8])
                        let textBytes = Int(UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset + 9, as: UInt32.self)))
                        offset += headerSize
                        guard textBytes > 0, textBytes <= bytes.count - offset, attributes.indices.contains(attributeIndex),
                              column >= nextColumn, column < line.width, (1...2).contains(width),
                              (1...1000).contains(repetitions), width == 1 || repetitions == 1,
                              width * repetitions <= line.width - column || (width == 2 && column == line.width - 1),
                              let text = String(bytes: bytes[offset..<(offset + textBytes)], encoding: .utf8),
                              text.count == 1, let character = text.first else {
                            throw TerminalCheckpointError.corrupt("bridge cell geometry or grapheme")
                        }
                        offset += textBytes
                        var value = try freshTerminal.makeCharData(
                            attribute: attributes[attributeIndex], char: character, size: Int8(width)
                        )
                        if let link = s.attributes[attributeIndex].link {
                            guard let atom = TinyAtom.lookupCheckpointHyperlink(link) else {
                                throw TerminalCheckpointError.corrupt("bridge hyperlink table full")
                            }
                            value.setPayload(atom: atom)
                        }
                        nextColumn = column + width * repetitions
                        for cell in column..<min(line.width, nextColumn) { cells[cell] = value }
                        if width == 2, column + 1 < line.width {
                            cells[column + 1] = CharData(attribute: value.attribute, code: 0, size: 0)
                        }
                    }
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
                          (placement.column < line.width && (placement.column>=0 || placement.imageId != nil)) else { throw TerminalCheckpointError.corrupt("bridge image placement") }
                    var image = stripes[placement.stripe]
                    image.column = placement.column
                    image.isKitty = placement.imageId != nil
                    image.imageId = placement.imageId; image.placementId = placement.placementId
                    image.zIndex = placement.zIndex
                    if image.isKitty {
                        guard placement.placementId != nil, let resource = s.graphics.first(where: {$0.key == placement.resource}) else {
                            throw TerminalCheckpointError.corrupt("bridge Kitty placement identity")
                        }
                        guard let owner = s.kitty.placementBuffers.first(where: {
                            $0.id == placement.imageId && $0.placement == placement.placementId
                        }) else { throw TerminalCheckpointError.corrupt("bridge Kitty stripe owner") }
                        image.pixelOffsetX = owner.pixelOffsetX; image.pixelOffsetY = owner.pixelOffsetY
                        image.kittyColumn = owner.imageColumn; image.kittyRow = owner.imageRow
                        image.kittyColumns = (resource.displayWidth+s.cellPixels[0]-1)/s.cellPixels[0]
                        image.kittyRows = stripes.count
                        image.imageNumber = s.kitty.numbers.first(where: {$0.id == placement.imageId})?.number
                    }
                    return image
                }
                return CheckpointLine(isWrapped: index > 0 ? source.lines[index - 1].wrapped : source.firstWrapped ?? false, renderMode: 0,
                    fillCharacter: try CheckpointCell(CharData(attribute: CharData.defaultAttr)), cellCount: line.width,
                    cellData: encoded.data, hyperlinks: encoded.hyperlinks, images: images, generation: 0)
            }
            return result
        }
        native.normalBuffer = try buffer(s.normal, native.normalBuffer, active: !s.alternateActive, normal: true)
        native.alternateBuffer = try buffer(s.alternate, native.alternateBuffer, active: s.alternateActive, normal: false)
        guard s.kitty.placementBuffers.count <= 1024 else {
            throw TerminalCheckpointError.corrupt("bridge Kitty placement count")
        }
        var placementKeys = Set<String>()
        native.kitty.placements = try s.kitty.placementBuffers.map { record in
            let rows = record.alternate ? 0...1000 : (-omitted)...(s.rows + s.scrollback - omitted)
            guard let placement = record.placement, ids.contains(record.id),
                  placementKeys.insert("\(record.id):\(placement)").inserted,
                  (record.parentImageId == nil ? (0...1000).contains(record.column) : (-68_719_478_000...68_719_478_000).contains(record.column)),
                  (record.parentImageId == nil ? rows.contains(record.row) : (-68_719_478_000...68_719_478_000).contains(record.row)),
                  (record.parentImageId == nil ? (0...1000).contains(record.imageColumn) : (-68_719_478_000...68_719_478_000).contains(record.imageColumn)),
                  (record.parentImageId == nil ? rows.contains(record.imageRow) : (-68_719_478_000...68_719_478_000).contains(record.imageRow)),
                  ((record.isVirtual == true ? 0 : 1)...2048).contains(record.columns),
                  ((record.isVirtual == true ? 0 : 1)...2048).contains(record.rows),
                  (0...1024).contains(record.pixelOffsetX), (0...1024).contains(record.pixelOffsetY) else {
                throw TerminalCheckpointError.corrupt("bridge Kitty placement record")
            }
            return CheckpointKittyPlacement(imageId: record.id,placementId: placement,
                parentImageId: record.parentImageId,parentPlacementId: record.parentPlacementId,
                parentOffsetH: record.parentOffsetH ?? 0,parentOffsetV: record.parentOffsetV ?? 0,
                pixelOffsetX: record.pixelOffsetX,pixelOffsetY: record.pixelOffsetY,
                column: record.column,row: record.row,columns: record.columns,rows: record.rows,
                zIndex: record.zIndex,isVirtual: record.isVirtual ?? false,isAlternateBuffer: record.alternate)
        }
        guard native.kitty.nextPlacementId > 0, native.kitty.nextImageId > 0 else { throw TerminalCheckpointError.corrupt("bridge Kitty next identity") }
        let records = Dictionary(uniqueKeysWithValues: native.kitty.placements.map {
            (KittyPlacementKey(imageId: $0.imageId, placementId: $0.placementId), $0)
        })
        for record in native.kitty.placements {
            guard (Int(Int32.min)...Int(Int32.max)).contains(record.parentOffsetH),
                  (Int(Int32.min)...Int(Int32.max)).contains(record.parentOffsetV),
                  (record.parentImageId == nil) == (record.parentPlacementId == nil),
                  !record.isVirtual || record.parentImageId == nil else {
                throw TerminalCheckpointError.corrupt("bridge Kitty parent metadata")
            }
            var current = record
            var visited = Set([KittyPlacementKey(imageId: record.imageId, placementId: record.placementId)])
            var depth = 0
            while let id = current.parentImageId, let placement = current.parentPlacementId {
                let key = KittyPlacementKey(imageId: id, placementId: placement)
                depth += 1
                guard depth <= 32, visited.insert(key).inserted,
                      let parent = records[key], parent.isAlternateBuffer == record.isAlternateBuffer else {
                    throw TerminalCheckpointError.corrupt("bridge Kitty parent graph")
                }
                current = parent
            }
        }
        let relativeResources = s.kitty.relativeResources ?? []
        guard relativeResources.count<=128 else { throw TerminalCheckpointError.corrupt("bridge Kitty relative count limit") }
        var relativeKeys = Set<KittyPlacementKey>()
        var relativeRasterCost = 0
        native.kitty.relativeImages = relativeResources.isEmpty ? nil : try relativeResources.map { item in
            let key = KittyPlacementKey(imageId: item.id, placementId: item.placement)
            guard relativeKeys.insert(key).inserted, let owner = records[key], owner.parentImageId != nil,
                  let stripes = renderedResources[item.resource], stripes.count == owner.rows else {
                throw TerminalCheckpointError.corrupt("bridge Kitty relative resource")
            }
            relativeRasterCost += stripes.reduce(0) { $0 + $1.pixelWidth*$1.pixelHeight*4+4096 }
            guard relativeRasterCost <= 12 * 1024 * 1024 else { throw TerminalCheckpointError.corrupt("bridge Kitty relative raster byte limit") }
            let images = stripes.map { stripe in
                var image = stripe
                image.isKitty = true; image.imageId = item.id; image.placementId = item.placement
                image.imageNumber = s.kitty.numbers.first(where: { $0.id == item.id })?.number
                image.column = owner.column; image.kittyColumn = owner.column; image.kittyRow = owner.row
                image.kittyColumns = owner.columns; image.kittyRows = owner.rows; image.zIndex = owner.zIndex
                image.pixelOffsetX = owner.pixelOffsetX; image.pixelOffsetY = owner.pixelOffsetY
                return image
            }
            return CheckpointKittyRelativeImages(imageId: item.id, placementId: item.placement, images: images)
        }
        guard relativeKeys.count == native.kitty.placements.filter({ $0.parentImageId != nil }).count else {
            throw TerminalCheckpointError.corrupt("bridge Kitty missing relative resource")
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
    }
}

extension TerminalView {
    /// Restores an authoritative server snapshot at the supplied delivery sequence.
    /// The owner delivers only events after this sequence and keeps terminal replies on the server.
    @MainActor
    public func importWezTermCheckpoint(_ data: Data, expectedSequence: UInt64) throws {
        try importWezTermCheckpoint(data, expectedSequence: expectedSequence, adoptingServerGeometry: false)
    }

    /// A server attachment adopts the checkpoint's physical geometry using this
    /// view's backing scale. The geometry remains authoritative until a server resize.
    @MainActor
    public func importWezTermCheckpoint(_ data: Data, expectedSequence: UInt64,
                                        adoptingServerGeometry: Bool) throws {
        let checkpoint = try BridgeEnvelope.decode(data)
        let previousGeometry = authoritativeImageGeometry
        let localGeometry = imageRenderingGeometry
        let geometry = adoptingServerGeometry
            ? try checkpoint.imageGeometry(displayScale: localGeometry.displayScale)
            : previousGeometry ?? localGeometry
        do {
            try getTerminal().importWezTermCheckpoint(checkpoint, expectedSequence: expectedSequence, geometry: geometry)
            if adoptingServerGeometry { authoritativeImageGeometry = geometry }
            try invalidateAfterCheckpointImport()
        } catch {
            authoritativeImageGeometry = previousGeometry
            throw error
        }
    }
}
#endif
