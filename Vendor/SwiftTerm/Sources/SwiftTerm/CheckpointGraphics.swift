#if os(macOS)
// Client-side conversion of retained Rust image resources using the native renderer.
import Foundation
import AppKit
import CoreGraphics
import ImageIO

struct BridgeImageBytes: Decodable {
    let data: Data

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let bytes = try? value.decode(Data.self) {
            data = bytes
        } else {
            data = Data(try value.decode([UInt8].self))
        }
    }
}

struct BridgeGraphicResource: Decodable {
    let key: String, rgba: BridgeImageBytes, encoded: BridgeImageBytes, width: Int, height: Int, displayWidth: Int, displayHeight: Int
    let request: BridgeImageRequest?
}
struct BridgeImageRequest: Decodable { let width: String, height: String, preserve: Bool }
struct BridgeGraphicPlacement: Decodable {
    let resource: String, column: Int, stripe: Int, imageId: UInt32?, placementId: UInt32?, zIndex: Int
}
private final class BridgeGraphicsDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

func bridgeRenderResources(_ resources: [BridgeGraphicResource], cellPixels: [Int], columns: Int,
    authoritativeGeometry: TerminalImageGeometry, requiresExactGeometry: Bool) throws -> [String: [CheckpointImage]] {
    guard cellPixels.count == 2, cellPixels.allSatisfy({(1...1024).contains($0)}), resources.count <= 2048 else {
        throw TerminalCheckpointError.corrupt("bridge image geometry")
    }
    // Text uses the checkpoint's row and column grid even when a native cell
    // ends at a fractional pixel the headless engine has rounded.
    guard requiresExactGeometry || !resources.isEmpty else { return [:] }
    let nativeCell = authoritativeGeometry.cellSize
    let scale = authoritativeGeometry.displayScale
    guard nativeCell.width.isFinite, nativeCell.height.isFinite, scale.isFinite,
          nativeCell.width > 0, nativeCell.height > 0, (0.1...8).contains(scale),
          abs(nativeCell.width * scale - CGFloat(cellPixels[0])) < 0.000_1,
          abs(nativeCell.height * scale - CGFloat(cellPixels[1])) < 0.000_1 else {
        throw TerminalCheckpointError.corrupt("bridge authoritative geometry mismatch")
    }
    // The server's stripe boundaries are given in physical pixels. Prepare
    // each raster at that scale before assigning its native drawing dimensions.
    let rasterGeometry = TerminalImageGeometry(
        cellSize: CGSize(width: cellPixels[0], height: cellPixels[1]),
        viewportSize: CGSize(width: authoritativeGeometry.viewportSize.width * scale,
                             height: authoritativeGeometry.viewportSize.height * scale),
        displayScale: 1
    )
    var result: [String: [CheckpointImage]] = [:]
    var sourceBytes = 0
    var storedBytes = 0
    var rasterBytes = 0
    for resource in resources {
        let rgba = resource.rgba.data
        let encoded = resource.encoded.data
        guard (1...10_000).contains(resource.width), (1...10_000).contains(resource.height),
              resource.width * resource.height <= 16 * 1024 * 1024,
              (1...65_535).contains(resource.displayWidth), (1...65_535).contains(resource.displayHeight),
              encoded.isEmpty ? rgba.count == resource.width * resource.height * 4 : rgba.isEmpty,
              result[resource.key] == nil else { throw TerminalCheckpointError.corrupt("bridge image resource") }
        sourceBytes += resource.width * resource.height * 4
        storedBytes += rgba.count + encoded.count
        let displayRows = (resource.displayHeight + cellPixels[1] - 1) / cellPixels[1]
        let displayColumns = (resource.displayWidth + cellPixels[0] - 1) / cellPixels[0]
        let raster = resource.displayWidth * displayRows * cellPixels[1] * 4
        rasterBytes += raster + 4096 * displayRows
        guard sourceBytes <= 64 * 1024 * 1024, storedBytes <= TerminalCheckpointLimits.imageBytes,
              displayRows <= 2048, displayColumns <= TerminalCheckpointLimits.columns,
              raster <= 8 * 1024 * 1024, rasterBytes <= 12 * 1024 * 1024 else {
            throw TerminalCheckpointError.corrupt("bridge image resource limit")
        }
        let png: Data
        if !encoded.isEmpty {
            png = encoded
            guard let source = CGImageSourceCreateWithData(png as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                  CGImageSourceGetCount(source)==1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == resource.width,
                  (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == resource.height else {
                throw TerminalCheckpointError.corrupt("bridge encoded image dimensions")
            }
        }
        else {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: rgba as CFData),
              let image = CGImage(width: resource.width,height: resource.height,bitsPerComponent: 8,bitsPerPixel: 32,
                bytesPerRow: resource.width*4,space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,decode: nil,shouldInterpolate: true,intent: .defaultIntent),
              let bytes = NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:]) else {
            throw TerminalCheckpointError.corrupt("bridge image encoding")
        }
        png = bytes
        }
        let delegate = BridgeGraphicsDelegate()
        var options = TerminalOptions.default
        options.cols = max(columns, displayColumns)
        options.rows = displayRows + 1
        options.scrollback = 0
        let temporary = Terminal(delegate: delegate, options: options)
        func size(_ text: String) throws -> ImageSizeRequest {
            if text=="auto" {return .auto}
            let unit: Int = text.hasSuffix("px") ? 2 : text.hasSuffix("%") ? 1 : 0
            let value = unit==2 ? String(text.dropLast(2)) : unit==1 ? String(text.dropLast()) : text
            guard let n = Int(value),(1...2048).contains(n) else {throw TerminalCheckpointError.corrupt("bridge image size request")}
            return unit==2 ? .pixels(n) : unit==1 ? .percent(n) : .cells(n)
        }
        let width = try resource.request.map {try size($0.width)} ?? .pixels(resource.displayWidth)
        let height = try resource.request.map {try size($0.height)} ?? .pixels(resource.displayHeight)
        TerminalImageRenderer(terminal: temporary, geometry: rasterGeometry).createImage(source: temporary, data: png,
            width: width,height: height,preserveAspectRatio: resource.request?.preserve ?? false)
        let checkpoint = try PropertyListDecoder().decode(TerminalCheckpointEnvelope.self,from: temporary.exportCheckpoint())
        let stripes = checkpoint.state.normalBuffer.lines.flatMap(\.images)
        guard stripes.count == displayRows else {
            throw TerminalCheckpointError.corrupt("bridge rendered image stripes")
        }
        result[resource.key] = stripes.map { stripe in
            var image = stripe
            image.pixelWidth = max(1, Int(CGFloat(stripe.pixelWidth) / scale))
            image.pixelHeight = max(1, Int(CGFloat(stripe.pixelHeight) / scale))
            return image
        }
    }
    return result
}

#if DEBUG
// Flush the same native display update used by the app before headless raster capture.
extension TerminalView {
    public func refreshRustPrototypeView() { updateDisplay() }
}

extension Terminal {
    public func prototypeRelativeProjections() -> UInt64 { kittyGraphicsState.projectionCount }
}

// The unwindowed experiment uses one coherent grid/image scale. A separate
// diagnostic setting reproduces the NSScreen fallback mismatch.
public final class RustPrototypeTerminalView: TerminalView {
    private let prototypeFontGridScale: CGFloat
    public init(frame: CGRect, fontGridScale: CGFloat) throws {
        guard fontGridScale == 1 || fontGridScale == 2 else {
            throw TerminalCheckpointError.corrupt("prototype font grid scale")
        }
        prototypeFontGridScale = fontGridScale
        super.init(frame: frame)
    }
    public required init?(coder: NSCoder) { return nil }
    override func backingScaleFactor() -> CGFloat { prototypeFontGridScale }
}
#endif
#endif
