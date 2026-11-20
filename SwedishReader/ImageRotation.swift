import ImageIO
import UIKit

extension CGImagePropertyOrientation {
    /// The orientation matching a photo shown rotated clockwise by `quarterTurns` × 90°.
    init(quarterTurns: Int?) {
        let turns = (((quarterTurns ?? 0) % 4) + 4) % 4
        self = [.up, .right, .down, .left][turns]
    }
}

extension UIImage {
    /// The same pixels shown rotated clockwise by `quarterTurns` × 90°. Only the orientation
    /// flag changes, so this is instant and repeated rotations don't lose quality.
    func rotated(quarterTurns: Int?) -> UIImage {
        let turns = (((quarterTurns ?? 0) % 4) + 4) % 4
        guard turns != 0, let cgImage else { return self }
        let orientations: [UIImage.Orientation] = [.up, .right, .down, .left]
        return UIImage(cgImage: cgImage, scale: scale, orientation: orientations[turns])
    }
}
