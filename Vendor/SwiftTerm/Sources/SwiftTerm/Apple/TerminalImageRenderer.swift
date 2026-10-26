#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreGraphics
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The view supplies measured geometry; detached hosts retain the last authoritative geometry.
public struct TerminalImageGeometry: Codable, Equatable, Sendable {
    public var cellSize: CGSize
    public var viewportSize: CGSize
    public var displayScale: CGFloat

    public init(cellSize: CGSize, viewportSize: CGSize, displayScale: CGFloat) {
        self.cellSize = cellSize
        self.viewportSize = viewportSize
        self.displayScale = displayScale
    }

    /// Measures a real default-font native view for clients that have no visible window yet.
    @MainActor
    public static func measuredDefault(columns: Int, rows: Int) -> TerminalImageGeometry {
        let view = TerminalView(frame: .zero)
        let cell = view.imageRenderingGeometry.cellSize
        view.frame = CGRect(x: 0, y: 0, width: cell.width * CGFloat(columns), height: cell.height * CGFloat(rows))
        return view.imageRenderingGeometry
    }

}

/// Shared image placement and checkpoint stripes for visible and detached terminal emulators.
/// This owns no window or font assumptions; geometry is measured by the actual terminal view.
public final class TerminalImageRenderer {
    private let terminal: Terminal
    public var geometry: TerminalImageGeometry
    private static let maximumSourcePixels = 16 * 1_024 * 1_024
    private static let maximumNewRasterBytes = 8 * 1_024 * 1_024
    private static let maximumRetainedStripeCost = 12 * 1_024 * 1_024
    private static let maximumStripes = 2_048
    private var cellDimension: CGSize { geometry.cellSize }
    private var frame: CGRect { CGRect(origin: .zero, size: geometry.viewportSize) }
    private func getImageScale() -> CGFloat { geometry.displayScale }

    public init(terminal: Terminal, geometry: TerminalImageGeometry) {
        self.terminal = terminal
        self.geometry = geometry
    }

    public func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0, width <= 8_192, height <= 8_192,
              width * height <= Self.maximumSourcePixels, bytes.count == width * height * 4 else { return }
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let pixelData = NSData(bytes: bytes, length: bytes.count)
        guard let providerRef: CGDataProvider = CGDataProvider(data: pixelData) else {
            return
        }
        guard let cgimage: CGImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: rgbColorSpace, bitmapInfo: bitmapInfo,
                provider: providerRef, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent) else {
            return
        }
        
        let image = TTImage (cgImage: cgimage, size: CGSize (width: width, height: height))
        if let context = terminal.kittyPlacementContext {
            insertImage (image, width: context.widthRequest, height: context.heightRequest, preserveAspectRatio: context.preserveAspectRatio)
        } else {
            insertImage (image, width: CGFloat (width) > frame.width ? .percent(100) : .auto, height: .auto, preserveAspectRatio: true)
        }
    }
   
    public func createImage (source: Terminal, data: Data, width widthRequest: ImageSizeRequest, height heightRequest: ImageSizeRequest, preserveAspectRatio: Bool)
    {
        guard let img = TTImage(data: data) else {
            return
        }
        insertImage (img, width: widthRequest, height: heightRequest, preserveAspectRatio: preserveAspectRatio)
    }
    
    // Inserts the specified image at the current buffer position (x, y) using the specified size requests
    // and aspect ratio request.   The insertion is done by adding slices of the image, one per line
    // to the buffer.
    private func insertImage (_ image: TTImage, width widthRequest: ImageSizeRequest, height heightRequest: ImageSizeRequest, preserveAspectRatio: Bool)
    {
        guard image.size.width.isFinite, image.size.height.isFinite,
              image.size.width > 0, image.size.height > 0,
              cellDimension.width.isFinite, cellDimension.height.isFinite,
              cellDimension.width > 0, cellDimension.height > 0,
              geometry.displayScale.isFinite, geometry.displayScale > 0 else { return }
        let buffer = terminal.buffer
        var img = image
        let displayScale = getImageScale ()
        let placementContext = terminal.kittyPlacementContext
        
        // Converts a size request in a single dimension into an absolute pixel value, where
        // the `dim` is the request, `regionSize` is the available view space, and `imageSize` is
        // the size of the image along the dimension being requested
        func getPixels (fromDim dim: ImageSizeRequest, regionSize: CGFloat, imageSize: CGFloat, cellSize: CGFloat) -> CGFloat {
            switch dim {
            case .auto:
                return imageSize/displayScale
            case .cells(let n):
                return cellSize * CGFloat (n)
            case .pixels(let n):
                return CGFloat (n)
            case .percent(let pct):
                return CGFloat (pct) * 0.01 * regionSize
            }
        }

        func pixelSizeForImage (_ image: TTImage) -> CGSize? {
            #if os(macOS)
            for rep in image.representations {
                if rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
                    return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                }
            }
            return nil
            #else
            if let cgImage = image.cgImage {
                return CGSize(width: cgImage.width, height: cgImage.height)
            }
            let scale = image.scale
            if scale > 0 {
                return CGSize(width: image.size.width * scale, height: image.size.height * scale)
            }
            return nil
            #endif
        }

        if let sourcePixels = pixelSizeForImage(img) {
            guard sourcePixels.width * sourcePixels.height <= CGFloat(Self.maximumSourcePixels) else { return }
        }
        let pixelSize = placementContext == nil ? nil : pixelSizeForImage(img)
        let widthImageSize: CGFloat
        let heightImageSize: CGFloat
        switch widthRequest {
        case .auto:
            widthImageSize = pixelSize?.width ?? img.size.width
        default:
            widthImageSize = img.size.width
        }
        switch heightRequest {
        case .auto:
            heightImageSize = pixelSize?.height ?? img.size.height
        default:
            heightImageSize = img.size.height
        }

        var width = getPixels (fromDim: widthRequest, regionSize: frame.width, imageSize: widthImageSize, cellSize: cellDimension.width)
        var height = getPixels (fromDim: heightRequest, regionSize: frame.height, imageSize: heightImageSize, cellSize: cellDimension.height)
        
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 8_192, height <= 8_192,
              width * height * 4 <= CGFloat(Self.maximumNewRasterBytes) else { return }
        if preserveAspectRatio {
            switch (widthRequest, heightRequest) {
            case (.auto, .auto):
                break
            case (_, .auto):
                height = (width * img.size.height) / img.size.width
            case (.auto, _):
                width = (height * img.size.width) / img.size.height
            case (_, _):
                img = scale (image: img, size: CGSize (width: width, height: height))
            }
        }
        
        let rowCount = ceil(height / cellDimension.height)
        let colCount = ceil(width / cellDimension.width)
        guard width.isFinite, height.isFinite, rowCount.isFinite, colCount.isFinite,
              rowCount > 0, rowCount <= CGFloat(Self.maximumStripes), colCount > 0, colCount <= 4_096 else { return }
        let rows = Int(rowCount)
        let cols = Int(colCount)
        let stripeRasterBytes = ceil(width) * ceil(cellDimension.height) * 4 * CGFloat(rows)
        // Reserve per-stripe encoding/metadata overhead and room for the helper's Kitty cache.
        let proposedCost = stripeRasterBytes + CGFloat(rows * 4_096)
        guard stripeRasterBytes <= CGFloat(Self.maximumNewRasterBytes),
              proposedCost <= CGFloat(Self.maximumRetainedStripeCost) else { return }
        evictOldStripes(reserving: proposedCost)
        let placementRow = buffer.y + buffer.yBase
        let placementCol = buffer.x
        if let context = placementContext,
           let imageId = context.imageId,
           let placementId = context.placementId {
            terminal.registerKittyPlacement(imageId: imageId,
                                            placementId: placementId,
                                            parentImageId: context.parentImageId,
                                            parentPlacementId: context.parentPlacementId,
                                            parentOffsetH: context.parentOffsetH,
                                            parentOffsetV: context.parentOffsetV,
                                            pixelOffsetX: context.pixelOffsetX,
                                            pixelOffsetY: context.pixelOffsetY,
                                            col: placementCol,
                                            row: placementRow,
                                            cols: cols,
                                            rows: rows,
                                            zIndex: context.zIndex,
                                            isVirtual: false)
        }
        
        let stripeSize = CGSize (width: width, height: cellDimension.height)
        var didScroll = false
        #if os(iOS) || os(visionOS)
        var srcY: CGFloat = 0
        #else
        var srcY: CGFloat = img.size.height
        #endif
        
        let heightRatio = img.size.height/height
        for _ in 0..<rows {
            #if os(macOS)
            srcY -= cellDimension.height * heightRatio
            #endif
            guard let stripe = drawImageInStripe (image: img, srcY: srcY, width: width, srcHeight: cellDimension.height * heightRatio, dstHeight: cellDimension.height, size: stripeSize) else {
                continue
            }
            #if os(iOS) || os(visionOS)
            srcY += cellDimension.height * heightRatio
            #endif
            
            let attachedImage = TerminalView.AppleImage (image: stripe, width: Int (stripeSize.width), height: Int (cellDimension.height), onCol: terminal.buffer.x)
            if let context = placementContext {
                attachedImage.kittyIsKitty = true
                attachedImage.kittyImageId = context.imageId
                attachedImage.kittyImageNumber = context.imageNumber
                attachedImage.kittyPlacementId = context.placementId
                attachedImage.kittyZIndex = context.zIndex
                attachedImage.kittyCol = placementCol
                attachedImage.kittyRow = placementRow
                attachedImage.kittyCols = cols
                attachedImage.kittyRows = rows
                attachedImage.kittyPixelOffsetX = context.pixelOffsetX
                attachedImage.kittyPixelOffsetY = context.pixelOffsetY
            }
            
            buffer.attachImage(attachedImage, toLineAt: buffer.y+buffer.yBase)

            terminal.updateRange (buffer.y)

            // The buffer.x position would have changed depending on the lineFeedMode (LNM)
            // for image rendering, we want the x to remain the same
            let savedX = buffer.x
            let previousYBase = buffer.yBase
            let previousLinesTop = buffer.linesTop
            terminal.cmdLineFeed()
            if buffer.yBase != previousYBase || buffer.linesTop != previousLinesTop {
                didScroll = true
            }
            buffer.x = savedX
        }
        if didScroll {
            terminal.updateFullScreen()
        }
        if let context = placementContext,
           context.cursorPolicy == 0,
           !context.isRelative {
            let moveCols = max(1, cols)
            let moveRows = max(1, rows)
            let targetCol = placementCol + moveCols
            let targetRow = placementRow + moveRows
            buffer.x = targetCol
            buffer.y = targetRow - buffer.yBase
            terminal.restrictCursor()
        }
    }
    

    private func retainedStripeCost() -> CGFloat {
        var total: CGFloat = 0
        for buffer in [terminal.normalBuffer, terminal.altBuffer] where buffer.hasAnyImages {
            for index in 0..<buffer.lines.count {
                for image in buffer.lines[index].images ?? [] {
                    total += CGFloat(image.pixelWidth) * CGFloat(image.pixelHeight) * 4 + 4_096
                }
            }
        }
        return total
    }

    /// Admission depends only on the incoming image and measured geometry. A spectator may have
    /// less history than the host, so a local retention count must never change cursor movement.
    private func evictOldStripes(reserving proposedCost: CGFloat) {
        var total = retainedStripeCost() + proposedCost
        guard total > CGFloat(Self.maximumRetainedStripeCost) else { return }
        for buffer in [terminal.normalBuffer, terminal.altBuffer] where buffer.hasAnyImages {
            for index in 0..<buffer.lines.count {
                guard let images = buffer.lines[index].images else { continue }
                total -= images.reduce(CGFloat.zero) {
                    $0 + CGFloat($1.pixelWidth) * CGFloat($1.pixelHeight) * 4 + 4_096
                }
                buffer.clearImagesFromLine(at: index)
                if total <= CGFloat(Self.maximumRetainedStripeCost) {
                    terminal.updateFullScreen()
                    return
                }
            }
        }
        terminal.updateFullScreen()
    }

    #if os(macOS)
    func scale (image: NSImage, size: CGSize) -> NSImage {
        
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                pixelsWide: max(1, Int(ceil(size.width))), pixelsHigh: max(1, Int(ceil(size.height))),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return image }
        let scaledImg = TTImage(size: size)
        scaledImg.addRepresentation(bitmap)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let srcRatio = image.size.height/image.size.width
        let scaledRatio = size.width/size.height
        let srcRect = CGRect(origin: CGPoint.zero, size: image.size)
        let dstRect: CGRect
        
        if srcRatio < scaledRatio {
            let nw = (size.height * image.size.width) / image.size.height
            dstRect = CGRect (x: (size.width-nw)/2, y: 0, width: nw, height: size.height)
        } else {
            let nh = (size.width * image.size.height) / image.size.width
            dstRect = CGRect (x: 0, y: (size.height-nh)/2, width: size.width, height: nh)
        }
        image.draw(in: dstRect, from: srcRect, operation: .copy, fraction: 1)
        
        return scaledImg
    }
    
    func drawImageInStripe (image: TTImage, srcY: CGFloat, width: CGFloat, srcHeight: CGFloat, dstHeight: CGFloat, size: CGSize) -> TTImage? {
        guard let bitmapImage = NSBitmapImageRep (
                bitmapDataPlanes: nil,
                pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false,
                colorSpaceName: NSColorSpaceName.calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            return nil
        }
        let stripe = NSImage (size: size)
        stripe.addRepresentation (bitmapImage)

        guard let context = NSGraphicsContext(bitmapImageRep: bitmapImage) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        let srcRect = CGRect(x: 0, y: CGFloat(srcY), width: image.size.width, height: srcHeight)
        let destRect = CGRect(x: 0, y: 0, width: width, height: dstHeight)
        image.draw(in: destRect, from: srcRect, operation: .copy, fraction: 1.0)
        return stripe
    }
    
    #else
    func scale (image: UIImage, size: CGSize) -> UIImage {
        UIGraphicsBeginImageContext(size)
        
        let srcRatio = image.size.height/image.size.width
        let scaledRatio = size.width/size.height
        
        let dstRect: CGRect
        
        if srcRatio < scaledRatio {
            let nw = (size.height * image.size.width) / image.size.height
            dstRect = CGRect (x: (size.width-nw)/2, y: 0, width: nw, height: size.height)
        } else {
            let nh = (size.width * image.size.height) / image.size.width
            dstRect = CGRect (x: 0, y: (size.height-nh)/2, width: size.width, height: nh)
        }
        image.draw (in: dstRect)
        
        let ret = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return ret
    }
    
    func drawImageInStripe (image: TTImage, srcY: CGFloat, width: CGFloat, srcHeight: CGFloat, dstHeight: CGFloat, size: CGSize) -> TTImage? {
        let srcRect = CGRect(x: 0, y: CGFloat(srcY), width: image.size.width, height: srcHeight)
        guard let cropCG = image.cgImage?.cropping(to: srcRect) else {
            return nil
        }
        let uicrop = UIImage (cgImage: cropCG)
        
        let destRect = CGRect(x: 0, y: 0, width: width, height: dstHeight)
        
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        guard let ctx = UIGraphicsGetCurrentContext() else {
            return nil
        }
        ctx.translateBy(x: 0, y: dstHeight)
        ctx.scaleBy(x: 1, y: -1)

        uicrop.draw(in: destRect)
        
        let stripe = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return stripe
    }

    #endif
}
#endif
