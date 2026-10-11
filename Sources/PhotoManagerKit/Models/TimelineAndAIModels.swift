import Foundation

/// A single month group containing photos taken within that month.
public struct MonthGroup: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let year: Int
    public let month: Int
    public let monthName: String
    public let assetIDs: [String]
    public let coverAssetID: String?
    public let count: Int
    public let totalBytes: Int64
    
    public init(
        id: String,
        year: Int,
        month: Int,
        monthName: String,
        assetIDs: [String],
        coverAssetID: String?,
        count: Int,
        totalBytes: Int64
    ) {
        self.id = id
        self.year = year
        self.month = month
        self.monthName = monthName
        self.assetIDs = assetIDs
        self.coverAssetID = coverAssetID
        self.count = count
        self.totalBytes = totalBytes
    }
    
    public var formattedSize: String {
        ByteFormatter.format(bytes: totalBytes)
    }
}

/// A collapsible year section containing month groups.
public struct YearSection: Identifiable, Equatable, Sendable, Codable {
    public var id: Int { year }
    public let year: Int
    public var months: [MonthGroup]
    public var totalCount: Int
    public var totalBytes: Int64
    
    public init(
        year: Int,
        months: [MonthGroup],
        totalCount: Int,
        totalBytes: Int64
    ) {
        self.year = year
        self.months = months
        self.totalCount = totalCount
        self.totalBytes = totalBytes
    }
    
    public var formattedSize: String {
        ByteFormatter.format(bytes: totalBytes)
    }
}

/// AI Classified photo category item.
public struct AICategoryItem: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let title: String
    public let sfSymbol: String
    public let colorName: String
    public var count: Int
    public var totalBytes: Int64
    public var assetIDs: [String]
    public var coverAssetID: String?
    
    public init(
        id: String,
        title: String,
        sfSymbol: String,
        colorName: String,
        count: Int,
        totalBytes: Int64,
        assetIDs: [String],
        coverAssetID: String?
    ) {
        self.id = id
        self.title = title
        self.sfSymbol = sfSymbol
        self.colorName = colorName
        self.count = count
        self.totalBytes = totalBytes
        self.assetIDs = assetIDs
        self.coverAssetID = coverAssetID
    }
    
    public var formattedSize: String {
        ByteFormatter.format(bytes: totalBytes)
    }
}

/// User created album representation.
public struct UserAlbumItem: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let title: String
    public var count: Int
    public var totalBytes: Int64
    public var assetIDs: [String]
    public var coverAssetID: String?
    
    public init(
        id: String,
        title: String,
        count: Int,
        totalBytes: Int64,
        assetIDs: [String],
        coverAssetID: String?
    ) {
        self.id = id
        self.title = title
        self.count = count
        self.totalBytes = totalBytes
        self.assetIDs = assetIDs
        self.coverAssetID = coverAssetID
    }
    
    public var formattedSize: String {
        ByteFormatter.format(bytes: totalBytes)
    }
}
