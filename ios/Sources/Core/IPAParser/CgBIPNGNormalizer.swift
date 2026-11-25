import Foundation
import ImageIO
import UIKit

/// Khôi phục ảnh biểu tượng Apple CgBI PNG sang PNG chuẩn RGBA thông qua ImageIO gốc của iOS
public enum CgBIPNGNormalizer {
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    public static func isCgBIEncoded(_ data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        let bytes = [UInt8](data.prefix(16))
        guard Array(bytes[0..<8]) == pngSignature else { return false }
        return bytes[12] == 0x43 && bytes[13] == 0x67 && bytes[14] == 0x42 && bytes[15] == 0x49
    }

    public static func normalizePNGData(_ rawData: Data) -> Data? {
        guard rawData.count >= 16 else { return nil }
        if let source = CGImageSourceCreateWithData(rawData as CFData, nil),
           let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return UIImage(cgImage: cgImage).pngData() ?? rawData
        }
        if let uiImg = UIImage(data: rawData) {
            return uiImg.pngData() ?? rawData
        }
        return nil
    }

    /// Quét tìm ảnh PNG nhúng bên trong tệp Assets.car nếu gói .app không để icon rời bên ngoài
    public static func extractLargestPNGFromAssetsCar(_ carData: Data) -> Data? {
        let sigData = Data(pngSignature)
        let iendTag = Data([0x49, 0x45, 0x4E, 0x44]) // "IEND"
        var searchRange = carData.startIndex..<carData.endIndex
        var bestPNG: Data?
        var bestPixelArea = 0

        while let pngRange = carData.range(of: sigData, options: [], in: searchRange) {
            let start = pngRange.lowerBound
            let afterSig = pngRange.upperBound
            guard afterSig < carData.endIndex else { break }

            let maxScanEnd = carData.index(start, offsetBy: min(8 * 1024 * 1024, carData.distance(from: start, to: carData.endIndex)))
            if let iendRange = carData.range(of: iendTag, options: [], in: afterSig..<maxScanEnd) {
                let end = carData.index(iendRange.upperBound, offsetBy: 4, limitedBy: carData.endIndex) ?? iendRange.upperBound
                let slice = carData.subdata(in: start..<end)
                if let img = UIImage(data: slice) {
                    let area = Int(img.size.width * img.scale * img.size.height * img.scale)
                    if area > bestPixelArea, let norm = img.pngData() {
                        bestPixelArea = area
                        bestPNG = norm
                    }
                }
                searchRange = end..<carData.endIndex
            } else {
                searchRange = afterSig..<carData.endIndex
            }
        }
        return bestPNG
    }
}
