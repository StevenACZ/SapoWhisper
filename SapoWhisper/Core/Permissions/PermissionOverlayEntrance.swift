import CoreGraphics
import Foundation

struct PermissionOverlayEntrance {
    let origin: CGPoint
    let startedAt: TimeInterval

    func progress(at time: TimeInterval) -> CGFloat {
        let fraction = min(1, max(0, (time - startedAt) / 0.28))
        return CGFloat(1 - pow(1 - fraction, 3))
    }

    func origin(toward target: CGPoint, progress: CGFloat) -> CGPoint {
        CGPoint(
            x: origin.x + (target.x - origin.x) * progress,
            y: origin.y + (target.y - origin.y) * progress
        )
    }
}
