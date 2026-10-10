import CoreGraphics
import Foundation

/// Converts between AppKit global points, display-local points, and captured image pixels.
///
/// AppKit and ScreenCaptureKit expose display geometry in a lower-left, y-up coordinate space.
/// CGImage pixels use an upper-left, y-down coordinate space. Conversion rounds outward so an
/// edge pixel is never lost, then clamps to the authoritative captured image dimensions.
struct DisplayGeometry: Equatable, Sendable {
    let descriptor: ScreenDescriptor
    let imageSize: PixelSize

    init(descriptor: ScreenDescriptor, imageSize: PixelSize? = nil) {
        self.descriptor = descriptor
        self.imageSize = imageSize ?? descriptor.pixelSize
    }

    var isValid: Bool {
        descriptor.frame.isFinite && descriptor.pointPixelScale.isFinite && descriptor.pointPixelScale > 0 && imageSize.isValid
    }

    func validate() throws {
        guard descriptor.frame.isFinite, descriptor.frame.rect.width > 0, descriptor.frame.rect.height > 0 else {
            throw DisplayGeometryError.invalidFrame
        }
        guard descriptor.pointPixelScale.isFinite && descriptor.pointPixelScale > 0 else {
            throw DisplayGeometryError.invalidScale
        }
        guard imageSize.isValid else { throw DisplayGeometryError.invalidImageSize }
    }

    func validate(globalRect: GlobalScreenRect) throws {
        try validate()
        guard globalRect.isFinite else { throw DisplayGeometryError.nonFiniteRect }
    }

    func validate(displayLocalRect: DisplayLocalRect) throws {
        try validate()
        guard displayLocalRect.isFinite else { throw DisplayGeometryError.nonFiniteRect }
    }

    func displayLocalRect(for globalRect: GlobalScreenRect) -> DisplayLocalRect {
        let frame = descriptor.frame.rect
        return DisplayLocalRect(CGRect(
            x: globalRect.rect.origin.x - frame.origin.x,
            y: globalRect.rect.origin.y - frame.origin.y,
            width: globalRect.rect.width,
            height: globalRect.rect.height
        ).standardized)
    }

    func globalRect(for displayLocalRect: DisplayLocalRect) -> GlobalScreenRect {
        let frame = descriptor.frame.rect
        return GlobalScreenRect(CGRect(
            x: displayLocalRect.rect.origin.x + frame.origin.x,
            y: displayLocalRect.rect.origin.y + frame.origin.y,
            width: displayLocalRect.rect.width,
            height: displayLocalRect.rect.height
        ).standardized)
    }

    func imagePixelRect(for globalRect: GlobalScreenRect) -> ImagePixelRect {
        imagePixelRect(for: displayLocalRect(for: globalRect))
    }

    func imagePixelRect(for displayLocalRect: DisplayLocalRect) -> ImagePixelRect {
        let rect = displayLocalRect.rect.standardized
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width > 0, rect.size.height > 0,
              descriptor.pointPixelScale.isFinite, descriptor.pointPixelScale > 0
        else {
            return ImagePixelRect(x: 0, y: 0, width: 0, height: 0)
        }

        let scale = CGFloat(descriptor.pointPixelScale)
        let imageHeight = CGFloat(imageSize.height)
        let rawMinX = rect.minX * scale
        let rawMaxX = rect.maxX * scale
        // Convert lower-left point bounds into upper-left pixel bounds before rounding.
        let rawMinY = imageHeight - (rect.maxY * scale)
        let rawMaxY = imageHeight - (rect.minY * scale)

        let minX = Int(floor(min(rawMinX, rawMaxX)))
        let maxX = Int(ceil(max(rawMinX, rawMaxX)))
        let minY = Int(floor(min(rawMinY, rawMaxY)))
        let maxY = Int(ceil(max(rawMinY, rawMaxY)))
        return ImagePixelRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY).clamped(to: imageSize)
    }

    func displayLocalRect(for imageRect: ImagePixelRect) -> DisplayLocalRect {
        let rect = imageRect.clamped(to: imageSize)
        let scale = CGFloat(descriptor.pointPixelScale)
        guard scale.isFinite, scale > 0 else { return DisplayLocalRect(.zero) }
        let imageHeight = CGFloat(imageSize.height)
        let localMinX = CGFloat(rect.minX) / scale
        let localMaxY = (imageHeight - CGFloat(rect.minY)) / scale
        let localMaxX = CGFloat(rect.maxX) / scale
        let localMinY = (imageHeight - CGFloat(rect.maxY)) / scale
        return DisplayLocalRect(CGRect(
            x: localMinX,
            y: localMinY,
            width: localMaxX - localMinX,
            height: localMaxY - localMinY
        ).standardized)
    }

    func globalRect(for imageRect: ImagePixelRect) -> GlobalScreenRect {
        globalRect(for: displayLocalRect(for: imageRect))
    }

    func imagePixelRect(for displayLocalRect: DisplayLocalRect, clampedTo imageSize: PixelSize) -> ImagePixelRect {
        DisplayGeometry(descriptor: descriptor, imageSize: imageSize).imagePixelRect(for: displayLocalRect)
    }

    /// Alternate explicit labels make call sites self-documenting at layer boundaries.
    func globalToDisplayLocal(_ rect: GlobalScreenRect) -> DisplayLocalRect { displayLocalRect(for: rect) }
    func displayLocalToImagePixels(_ rect: DisplayLocalRect) -> ImagePixelRect { imagePixelRect(for: rect) }
    func imagePixelsToDisplayLocal(_ rect: ImagePixelRect) -> DisplayLocalRect { displayLocalRect(for: rect) }
    func globalToImagePixels(_ rect: GlobalScreenRect) -> ImagePixelRect { imagePixelRect(for: rect) }
    func imagePixelsToGlobal(_ rect: ImagePixelRect) -> GlobalScreenRect { globalRect(for: rect) }
}
