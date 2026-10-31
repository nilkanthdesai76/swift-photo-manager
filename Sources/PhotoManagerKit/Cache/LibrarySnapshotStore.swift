import Foundation

/// Persisted copy of the library snapshot's model layer — everything
/// `LibrarySnapshot` carries except the `PHAsset` arrays. A relaunch paints
/// Home/Swipe from this within milliseconds and lets the PhotoKit fetch +
/// rebuild validate it in the background, instead of shimmering for seconds.
struct PersistedLibrarySnapshot: Codable {
    var storageOverview: LibraryStorageOverview
    var photoSmartAlbums: [SmartAlbumItem]
    var videoSmartAlbums: [SmartAlbumItem]
    var largePhotosAlbum: SmartAlbumItem?
    var oldPhotosAlbum: SmartAlbumItem?
    var largeVideosAlbum: SmartAlbumItem?
    var blurryPhotosAlbum: SmartAlbumItem?
    var yearSections: [YearSection]
    var aiCategoryItems: [AICategoryItem]
    var userAlbums: [UserAlbumItem]
    var photoCount: Int
    var videoCount: Int
}

enum LibrarySnapshotStore {
    private static let snapshotFileName = "library_snapshot.plist"

    /// Same caches directory as `PhotoManagerCache` — one clear wipes both.
    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base
            .appendingPathComponent("com.nilkanth.PhotoManager", isDirectory: true)
            .appendingPathComponent(snapshotFileName)
    }

    /// Binary plist — considerably faster to encode/decode than JSON for
    /// tens of thousands of asset-ID strings. Callers run this off the
    /// MainActor; a missing or undecodable file means "no early paint".
    static func load() -> PersistedLibrarySnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? PropertyListDecoder().decode(PersistedLibrarySnapshot.self, from: data)
    }

    static func save(_ snapshot: PersistedLibrarySnapshot) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
