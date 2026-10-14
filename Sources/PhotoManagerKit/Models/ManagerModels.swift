import Foundation

/// High-level library storage overview.
public struct LibraryStorageOverview: Equatable, Sendable, Codable {
    public var totalBytes: Int64
    public var totalCount: Int
    
    public var photosBytes: Int64
    public var photosCount: Int
    
    public var livePhotosTotalBytes: Int64
    public var livePhotosStillBytes: Int64
    public var livePhotosVideoBytes: Int64
    public var livePhotosCount: Int
    
    public var videosBytes: Int64
    public var videosCount: Int
    
    public var otherBytes: Int64
    public var otherCount: Int
    
    public var isEstimated: Bool
    
    public init(
        totalBytes: Int64 = 0,
        totalCount: Int = 0,
        photosBytes: Int64 = 0,
        photosCount: Int = 0,
        livePhotosTotalBytes: Int64 = 0,
        livePhotosStillBytes: Int64 = 0,
        livePhotosVideoBytes: Int64 = 0,
        livePhotosCount: Int = 0,
        videosBytes: Int64 = 0,
        videosCount: Int = 0,
        otherBytes: Int64 = 0,
        otherCount: Int = 0,
        isEstimated: Bool = true
    ) {
        self.totalBytes = totalBytes
        self.totalCount = totalCount
        self.photosBytes = photosBytes
        self.photosCount = photosCount
        self.livePhotosTotalBytes = livePhotosTotalBytes
        self.livePhotosStillBytes = livePhotosStillBytes
        self.livePhotosVideoBytes = livePhotosVideoBytes
        self.livePhotosCount = livePhotosCount
        self.videosBytes = videosBytes
        self.videosCount = videosCount
        self.otherBytes = otherBytes
        self.otherCount = otherCount
        self.isEstimated = isEstimated
    }
    
    public static let empty = LibraryStorageOverview()
    
    public var formattedTotalSize: String { ByteFormatter.format(bytes: totalBytes) }
    public var formattedPhotosSize: String { ByteFormatter.format(bytes: photosBytes) }
    public var formattedLivePhotosSize: String { ByteFormatter.format(bytes: livePhotosTotalBytes) }
    public var formattedLivePhotosStillSize: String { ByteFormatter.format(bytes: livePhotosStillBytes) }
    public var formattedLivePhotosVideoSize: String { ByteFormatter.format(bytes: livePhotosVideoBytes) }
    public var formattedVideosSize: String { ByteFormatter.format(bytes: videosBytes) }
}

/// Representation of a system smart album or user collection card.
public struct SmartAlbumItem: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let title: String
    public var count: Int
    public var totalBytes: Int64
    public let sfSymbol: String
    public let accentColorName: String
    public var assetIDs: [String]
    public var newestAssetID: String?
    
    public init(
        id: String,
        title: String,
        count: Int,
        totalBytes: Int64,
        sfSymbol: String,
        accentColorName: String,
        assetIDs: [String] = [],
        newestAssetID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.count = count
        self.totalBytes = totalBytes
        self.sfSymbol = sfSymbol
        self.accentColorName = accentColorName
        self.assetIDs = assetIDs
        self.newestAssetID = newestAssetID
    }
    
    public var formattedSize: String {
        ByteFormatter.format(bytes: totalBytes)
    }
}

/// Classification of deduplication match.
public enum DedupeMatchKind: String, Codable, Sendable {
    case exactDuplicate
    case similar
    
    public var displayName: String {
        switch self {
        case .exactDuplicate: return "Exact Duplicate"
        case .similar: return "Similar"
        }
    }
}

/// An individual asset wrapped with size and selection metadata.
public struct DedupeAssetItem: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let creationDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let duration: TimeInterval
    public var totalBytes: Int64
    public var stillBytes: Int64
    public var videoBytes: Int64
    public let isLivePhoto: Bool
    public let isVideo: Bool
    public let isFavorite: Bool
    public var isSelectedForDeletion: Bool
    
    public init(
        id: String,
        creationDate: Date? = nil,
        pixelWidth: Int = 0,
        pixelHeight: Int = 0,
        duration: TimeInterval = 0,
        totalBytes: Int64 = 0,
        stillBytes: Int64 = 0,
        videoBytes: Int64 = 0,
        isLivePhoto: Bool = false,
        isVideo: Bool = false,
        isFavorite: Bool = false,
        isSelectedForDeletion: Bool = false
    ) {
        self.id = id
        self.creationDate = creationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.duration = duration
        self.totalBytes = totalBytes
        self.stillBytes = stillBytes
        self.videoBytes = videoBytes
        self.isLivePhoto = isLivePhoto
        self.isVideo = isVideo
        self.isFavorite = isFavorite
        self.isSelectedForDeletion = isSelectedForDeletion
    }
    
    public var formattedTotalSize: String { ByteFormatter.format(bytes: totalBytes) }
    public var formattedStillSize: String { ByteFormatter.format(bytes: stillBytes) }
    public var formattedVideoSize: String { ByteFormatter.format(bytes: videoBytes) }
}

/// A cluster of duplicate or similar photos/videos.
public struct DedupeGroup: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let matchKind: DedupeMatchKind
    public var items: [DedupeAssetItem]
    public var bestAssetID: String
    
    public init(
        id: String,
        matchKind: DedupeMatchKind,
        items: [DedupeAssetItem],
        bestAssetID: String
    ) {
        self.id = id
        self.matchKind = matchKind
        self.items = items
        self.bestAssetID = bestAssetID
    }
    
    public var totalGroupBytes: Int64 {
        items.reduce(0) { $0 + $1.totalBytes }
    }
    
    public var reclaimableBytes: Int64 {
        let best = items.first(where: { $0.id == bestAssetID })
        let bestSize = best?.totalBytes ?? 0
        return max(0, totalGroupBytes - bestSize)
    }
    
    public var selectedForDeletionBytes: Int64 {
        items.filter(\.isSelectedForDeletion).reduce(0) { $0 + $1.totalBytes }
    }
}

/// Real-time progress payload emitted by hashing and scanner pipelines.
public struct ScanProgress: Equatable, Sendable, Codable {
    public var processed: Int
    public var total: Int
    public var isScanning: Bool
    /// Optional phase label, e.g. "Hashing" or "Grouping", shown by progress cards.
    public var label: String?
    
    public init(processed: Int = 0, total: Int = 0, isScanning: Bool = false, label: String? = nil) {
        self.processed = processed
        self.total = total
        self.isScanning = isScanning
        self.label = label
    }
    
    public static let idle = ScanProgress(processed: 0, total: 0, isScanning: false)
    public static let done = ScanProgress(processed: 1, total: 1, isScanning: false)
    
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return min(1.0, max(0.0, Double(processed) / Double(total)))
    }
    
    public var percentString: String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

/// Standardized byte string formatter.
public enum ByteFormatter {
    private static let formatter: ByteCountFormatter = {
        let b = ByteCountFormatter()
        b.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        b.countStyle = .file
        b.includesUnit = true
        b.isAdaptive = true
        return b
    }()
    
    public static func format(bytes: Int64) -> String {
        guard bytes > 0 else { return "0 B" }
        return formatter.string(fromByteCount: bytes)
    }
}
