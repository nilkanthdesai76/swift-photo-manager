import Foundation
import Photos

public enum ScanThresholds {
    public static let similarPhotoHammingDistance = 10
    public static let largePhotoMinBytes: Int64 = 5_000_000
    public static let largeVideoMinBytes: Int64 = 50_000_000
    public static let oldPhotoYears = 2

    public static let photoSignatureMinPixelDimension = 32
    public static let photoSignatureMinFileBytes: Int64 = 8_192
    public static let photoSignatureImageRequestTimeoutSeconds: Double = 2.0
}
