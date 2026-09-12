import CoreGraphics

struct PermissionOverlayPlacement {
    static func frame(settings: CGRect, visible: CGRect, height: CGFloat) -> CGRect? {
        let sidebar = min(240, max(180, settings.width * 0.31))
        let left = ceil(max(settings.minX + sidebar + 20, visible.minX))
        let right = floor(min(settings.maxX - 20, visible.maxX))
        let bottom = ceil(max(settings.minY + 20, visible.minY))
        let top = floor(min(settings.maxY - 20, visible.maxY))
        guard right - left >= 400, top - bottom >= ceil(height) else { return nil }
        return CGRect(x: left, y: bottom, width: right - left, height: ceil(height))
    }
}
