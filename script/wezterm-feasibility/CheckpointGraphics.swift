// Client-side conversion of retained Rust image resources using the native renderer.
import Foundation
import AppKit
import CoreGraphics
import ImageIO

struct BridgeGraphicResource: Decodable {
    let key: String, rgba: [UInt8], encoded: [UInt8], width: Int, height: Int, displayWidth: Int, displayHeight: Int
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
    authoritativeGeometry: TerminalImageGeometry) throws -> [String: [CheckpointImage]] {
    guard cellPixels.count == 2, cellPixels.allSatisfy({(1...1024).contains($0)}), resources.count <= 32 else {
        throw TerminalCheckpointError.corrupt("bridge image geometry")
    }
    let nativeCell = authoritativeGeometry.cellSize
    let scale = authoritativeGeometry.displayScale
    guard nativeCell.width.isFinite, nativeCell.height.isFinite, scale.isFinite,
          nativeCell.width > 0, nativeCell.height > 0, scale > 0,
          abs((nativeCell.width * scale).rounded() - CGFloat(cellPixels[0])) < 0.5,
          abs((nativeCell.height * scale).rounded() - CGFloat(cellPixels[1])) < 0.5 else {
        throw TerminalCheckpointError.corrupt("bridge authoritative geometry mismatch")
    }
    var result: [String: [CheckpointImage]] = [:]
    var total = 0
    var rasterBytes = 0
    for resource in resources {
        guard (1...2048).contains(resource.width), (1...2048).contains(resource.height),
              (1...2048).contains(resource.displayWidth), (1...2048).contains(resource.displayHeight),
              (resource.encoded.isEmpty ? resource.rgba.count == resource.width * resource.height * 4
                : resource.encoded.count <= 262144 && resource.rgba.isEmpty),
              result[resource.key] == nil else { throw TerminalCheckpointError.corrupt("bridge image resource") }
        total += resource.width * resource.height * 4
        guard total <= 262144 else { throw TerminalCheckpointError.corrupt("bridge image byte limit") }
        rasterBytes += resource.displayWidth * ((resource.displayHeight+cellPixels[1]-1)/cellPixels[1]) * cellPixels[1] * 4
        guard rasterBytes <= 2097152 else { throw TerminalCheckpointError.corrupt("bridge rendered image byte limit") }
        let png: Data
        if !resource.encoded.isEmpty {
            png = Data(resource.encoded)
            guard let source = CGImageSourceCreateWithData(png as CFData,[kCGImageSourceShouldCache:false] as CFDictionary),
                  CGImageSourceGetCount(source)==1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
                  (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == resource.width,
                  (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == resource.height else {
                throw TerminalCheckpointError.corrupt("bridge encoded image dimensions")
            }
        }
        else {
        guard let provider = CGDataProvider(data: Data(resource.rgba) as CFData),
              let image = CGImage(width: resource.width,height: resource.height,bitsPerComponent: 8,bitsPerPixel: 32,
                bytesPerRow: resource.width*4,space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,decode: nil,shouldInterpolate: true,intent: .defaultIntent),
              let bytes = NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:]) else {
            throw TerminalCheckpointError.corrupt("bridge image encoding")
        }
        png = bytes
        }
        let delegate = BridgeGraphicsDelegate()
        var options = TerminalOptions.default
        options.cols = max(columns, (resource.displayWidth + cellPixels[0]-1)/cellPixels[0])
        options.rows = (resource.displayHeight + cellPixels[1]-1)/cellPixels[1] + 1
        options.scrollback = 0
        let temporary = Terminal(delegate: delegate, options: options)
        let geometry = authoritativeGeometry
        func size(_ text: String) throws -> ImageSizeRequest {
            if text=="auto" {return .auto}
            let unit: Int = text.hasSuffix("px") ? 2 : text.hasSuffix("%") ? 1 : 0
            let value = unit==2 ? String(text.dropLast(2)) : unit==1 ? String(text.dropLast()) : text
            guard let n = Int(value),(1...2048).contains(n) else {throw TerminalCheckpointError.corrupt("bridge image size request")}
            return unit==2 ? .pixels(n) : unit==1 ? .percent(n) : .cells(n)
        }
        let width = try resource.request.map {try size($0.width)} ?? .pixels(resource.displayWidth)
        let height = try resource.request.map {try size($0.height)} ?? .pixels(resource.displayHeight)
        TerminalImageRenderer(terminal: temporary,geometry: geometry).createImage(source: temporary,data: png,
            width: width,height: height,preserveAspectRatio: resource.request?.preserve ?? false)
        let checkpoint = try PropertyListDecoder().decode(TerminalCheckpointEnvelope.self,from: temporary.exportCheckpoint())
        let stripes = checkpoint.state.normalBuffer.lines.flatMap(\.images)
        guard stripes.count == (resource.displayHeight + cellPixels[1]-1)/cellPixels[1] else {
            throw TerminalCheckpointError.corrupt("bridge rendered image stripes")
        }
        result[resource.key] = stripes
    }
    return result
}
