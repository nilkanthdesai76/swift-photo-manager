import Foundation

/// Persistent record for asset byte footprints.
public struct AssetSizeRecord: Codable, Equatable, Sendable {
    public let totalBytes: Int64
    public let stillBytes: Int64
    public let videoBytes: Int64
    public let isLivePhoto: Bool
    public let modificationDate: Date?
    
    public init(
        totalBytes: Int64,
        stillBytes: Int64,
        videoBytes: Int64,
        isLivePhoto: Bool,
        modificationDate: Date?
    ) {
        self.totalBytes = totalBytes
        self.stillBytes = stillBytes
        self.videoBytes = videoBytes
        self.isLivePhoto = isLivePhoto
        self.modificationDate = modificationDate
    }
}

/// Persistent record for video fingerprints.
public struct VideoFingerprintRecord: Codable, Equatable, Sendable {
    public let duration: TimeInterval
    public let keyframeHash: UInt64
    public let pixelWidth: Int
    public let pixelHeight: Int

    /// True for hashes the old fallback path fabricated from metadata when no
    /// pixel bytes were available (iCloud-only assets, uniform frames):
    /// `width ^ height ^ Int(duration * 100)`. Any two same-resolution videos
    /// with near-identical durations collided, producing false "similar"
    /// groups, so the engine re-fingerprints these with real pixels.
    var isLegacyFabricatedHash: Bool {
        keyframeHash == UInt64(pixelWidth ^ pixelHeight ^ Int(duration * 100))
    }

    public init(
        duration: TimeInterval,
        keyframeHash: UInt64,
        pixelWidth: Int,
        pixelHeight: Int
    ) {
        self.duration = duration
        self.keyframeHash = keyframeHash
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Unified persistence cache for sizes, perceptual hashes, and deduplication clusters.
/// Enables 50,000-photo libraries to launch and render in < 15ms on warm start.
public actor PhotoManagerCache {
    public static let shared = PhotoManagerCache()

    private let fileURL: URL
    private let legacyFileURL: URL
    private var sizes: [String: AssetSizeRecord] = [:]
    private var photoHashes: [String: UInt64] = [:]
    private var videoFingerprints: [String: VideoFingerprintRecord] = [:]
    private var photoDuplicates: [DedupeGroup] = []
    private var photoSimilars: [DedupeGroup] = []
    private var videoDuplicates: [DedupeGroup] = []
    private var videoSimilars: [DedupeGroup] = []
    private var aiCategories: [String: String] = [:]
    private var blurryPhotoIDs: Set<String> = []
    private var photoScanCompleted = false
    private var videoScanCompleted = false
    private var blurScanCompleted = false
    
    private var isDirty = false
    private var didBootstrap = false
    private var saveTask: Task<Void, Never>?
    
    /// Legacy JSON on-disk shape, kept only as the one-time migration source in `bootstrap()`.
    private struct CacheEnvelope: Codable {
        var sizes: [String: AssetSizeRecord]
        var photoHashes: [String: UInt64]
        var videoFingerprints: [String: VideoFingerprintRecord]
        var photoDuplicates: [DedupeGroup]
        var photoSimilars: [DedupeGroup]
        var videoDuplicates: [DedupeGroup]
        var videoSimilars: [DedupeGroup]
        var aiCategories: [String: String]?
        var blurryPhotoIDs: [String]?
        var photoScanCompleted: Bool?
        var videoScanCompleted: Bool?
        var blurScanCompleted: Bool?
    }
    
    public init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("com.nilkanth.PhotoManager", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("library_cache.bin")
        self.legacyFileURL = dir.appendingPathComponent("library_cache.json")
    }

    /// Loads cache from disk on launch. Takes < 15ms.
    public func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        if let data = try? Data(contentsOf: fileURL),
           let snapshot = PhotoManagerCacheBinaryCodec.decode(data) {
            applySnapshot(snapshot)
            return
        }

        // Migration fallback: adopt the legacy JSON blob once, then rewrite in binary.
        guard let legacyData = try? Data(contentsOf: legacyFileURL),
              let env = try? JSONDecoder().decode(CacheEnvelope.self, from: legacyData) else { return }
        let snapshot = PhotoManagerCacheSnapshot(
            sizes: env.sizes,
            photoHashes: env.photoHashes,
            videoFingerprints: env.videoFingerprints,
            photoDuplicates: env.photoDuplicates,
            photoSimilars: env.photoSimilars,
            videoDuplicates: env.videoDuplicates,
            videoSimilars: env.videoSimilars,
            aiCategories: env.aiCategories ?? [:],
            blurryPhotoIDs: Set(env.blurryPhotoIDs ?? []),
            photoScanCompleted: env.photoScanCompleted ?? false,
            videoScanCompleted: env.videoScanCompleted ?? false,
            blurScanCompleted: env.blurScanCompleted ?? false
        )
        applySnapshot(snapshot)
        let data = PhotoManagerCacheBinaryCodec.encode(snapshot)
        try? data.write(to: fileURL, options: .atomic)
    }
    
    // MARK: - Asset Sizes
    
    public func getSize(for id: String, modificationDate: Date? = nil) -> AssetSizeRecord? {
        guard let item = sizes[id] else { return nil }
        if let mod = modificationDate, let cachedMod = item.modificationDate {
            if abs(mod.timeIntervalSince(cachedMod)) > 1.0 {
                return nil
            }
        }
        return item
    }
    
    public func getAllSizes() -> [String: AssetSizeRecord] {
        return sizes
    }
    
    public func putSizeBatch(_ batch: [String: AssetSizeRecord]) {
        for (k, v) in batch {
            sizes[k] = v
        }
        isDirty = true
        scheduleDebouncedSave()
    }
    
    // MARK: - Photo Hashes
    
    public func getPhotoHash(for id: String) -> UInt64? {
        photoHashes[id]
    }
    
    public func getAllPhotoHashes() -> [String: UInt64] {
        photoHashes
    }
    
    public func putPhotoHashes(_ batch: [String: UInt64]) {
        for (k, v) in batch {
            photoHashes[k] = v
        }
        isDirty = true
        scheduleDebouncedSave()
    }
    
    // MARK: - Video Fingerprints
    
    public func getVideoFingerprint(for id: String) -> VideoFingerprintRecord? {
        videoFingerprints[id]
    }
    
    public func getAllVideoFingerprints() -> [String: VideoFingerprintRecord] {
        videoFingerprints
    }
    
    public func putVideoFingerprints(_ batch: [String: VideoFingerprintRecord]) {
        for (k, v) in batch {
            videoFingerprints[k] = v
        }
        isDirty = true
        scheduleDebouncedSave()
    }
    
    // MARK: - Dedupe Results
    
    public func getDedupeResults() -> (
        photoDuplicates: [DedupeGroup],
        photoSimilars: [DedupeGroup],
        videoDuplicates: [DedupeGroup],
        videoSimilars: [DedupeGroup]
    ) {
        return (photoDuplicates, photoSimilars, videoDuplicates, videoSimilars)
    }
    
    public func putPhotoGroups(duplicates: [DedupeGroup], similars: [DedupeGroup]) {
        self.photoDuplicates = duplicates
        self.photoSimilars = similars
        self.photoScanCompleted = true
        // NOTE: blur flags are harvested by the AI sort pass from its own
        // thumbnails — hashing no longer detects blur, so a photo scan must
        // not mark blur coverage here.
        isDirty = true
        scheduleDebouncedSave()
    }
    
    public func putVideoGroups(duplicates: [DedupeGroup], similars: [DedupeGroup]) {
        self.videoDuplicates = duplicates
        self.videoSimilars = similars
        self.videoScanCompleted = true
        isDirty = true
        scheduleDebouncedSave()
    }
    
    /// True when a full photo scan (hash + cluster) has completed for the library.
    public func isPhotoScanComplete() -> Bool {
        photoScanCompleted
    }
    
    /// True when every photo has passed through blur detection (via scan or backfill).
    public func isBlurScanComplete() -> Bool {
        blurScanCompleted
    }
    
    public func markBlurScanComplete() {
        blurScanCompleted = true
        isDirty = true
        scheduleDebouncedSave()
    }
    
    /// True when a full video scan (fingerprint + cluster) has completed for the library.
    public func isVideoScanComplete() -> Bool {
        videoScanCompleted
    }
    
    // MARK: - AI Categories
    
    public func getAICategory(for id: String) -> String? {
        aiCategories[id]
    }
    
    public func setAICategories(_ map: [String: String]) {
        guard !map.isEmpty else { return }
        for (id, cat) in map {
            aiCategories[id] = cat
        }
        isDirty = true
        scheduleDebouncedSave()
    }
    
    public func getAllAICategories() -> [String: String] {
        aiCategories
    }
    
    // MARK: - Blurry Photos
    
    /// IDs of photos flagged as blurry by the perceptual-hash pass. Only blurry IDs are stored.
    public func getBlurryPhotoIDs() -> Set<String> {
        blurryPhotoIDs
    }
    
    public func putBlurryPhotoIDs(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        blurryPhotoIDs.formUnion(ids)
        isDirty = true
        scheduleDebouncedSave()
    }

    /// Drops blur flags for assets PhotoKit has already deleted so a relaunch
    /// cannot rebuild the Blurry Photos album from stale IDs.
    public func removeBlurryPhotoIDs(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let before = blurryPhotoIDs.count
        blurryPhotoIDs.subtract(ids)
        guard blurryPhotoIDs.count != before else { return }
        isDirty = true
        scheduleDebouncedSave()
    }
    
    // MARK: - Persistence
    
    public func flush() async {
        guard isDirty else { return }
        isDirty = false

        let snapshot = makeSnapshot()
        let url = fileURL

        await Task.detached(priority: .utility) {
            let data = PhotoManagerCacheBinaryCodec.encode(snapshot)
            try? data.write(to: url, options: .atomic)
        }.value
    }
    
    public func clear() {
        sizes.removeAll()
        photoHashes.removeAll()
        videoFingerprints.removeAll()
        photoDuplicates.removeAll()
        photoSimilars.removeAll()
        videoDuplicates.removeAll()
        videoSimilars.removeAll()
        aiCategories.removeAll()
        blurryPhotoIDs.removeAll()
        photoScanCompleted = false
        videoScanCompleted = false
        blurScanCompleted = false
        isDirty = false
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: legacyFileURL)
    }
    
    // MARK: - Targeted Clears (for the process dashboard)
    
    public func clearPhotoHashesAndBlur() {
        photoHashes.removeAll()
        blurryPhotoIDs.removeAll()
        photoScanCompleted = false
        blurScanCompleted = false
        isDirty = true
        scheduleDebouncedSave()
    }

    /// Clears only blur flags + completion (heuristic upgrade re-check).
    /// Hashes stay cached — the AI sort re-detects flags from its own
    /// thumbnails without re-hashing.
    public func clearBlurFlags() {
        blurryPhotoIDs.removeAll()
        blurScanCompleted = false
        isDirty = true
        scheduleDebouncedSave()
    }
    
    public func clearVideoFingerprints() {
        videoFingerprints.removeAll()
        videoScanCompleted = false
        isDirty = true
        scheduleDebouncedSave()
    }

    /// Drops fingerprints written by the old metadata-fallback path (plus
    /// zero-hash sentinels). Affected videos re-fingerprint with real pixels
    /// on the next video scan; the scan-complete flag resets through
    /// `clearGroups()` at the migration call site.
    public func purgeFabricatedVideoFingerprints() {
        let before = videoFingerprints.count
        videoFingerprints = videoFingerprints.filter { _, record in
            record.keyframeHash != 0 && !record.isLegacyFabricatedHash
        }
        guard videoFingerprints.count != before else { return }
        isDirty = true
        scheduleDebouncedSave()
    }
    
    public func clearSizes() {
        sizes.removeAll()
        isDirty = true
        scheduleDebouncedSave()
    }
    
    public func clearAICategories() {
        aiCategories.removeAll()
        isDirty = true
        scheduleDebouncedSave()
    }
    
    /// Drops cached video clusters and the video scan-complete flag.
    /// Fingerprints stay, so the next video scan re-clusters without re-hashing.
    public func clearVideoGroups() {
        videoDuplicates.removeAll()
        videoSimilars.removeAll()
        videoScanCompleted = false
        isDirty = true
        scheduleDebouncedSave()
    }

    /// Clears only the clustered groups + scan-complete flags, keeping hashes/fingerprints.
    /// Used by "Re-group only" — the re-scan then skips hashing and re-runs just the clustering.
    public func clearGroups() {
        photoDuplicates.removeAll()
        photoSimilars.removeAll()
        videoDuplicates.removeAll()
        videoSimilars.removeAll()
        photoScanCompleted = false
        videoScanCompleted = false
        isDirty = true
        scheduleDebouncedSave()
    }
    
    /// Snapshot of current cache contents for the process dashboard.
    public func stats() -> (
        sizes: Int,
        photoHashes: Int,
        videoFingerprints: Int,
        aiCategories: Int,
        blurryPhotos: Int,
        groups: Int
    ) {
        (
            sizes.count,
            photoHashes.count,
            videoFingerprints.count,
            aiCategories.count,
            blurryPhotoIDs.count,
            photoDuplicates.count + photoSimilars.count + videoDuplicates.count + videoSimilars.count
        )
    }
    
    private func scheduleDebouncedSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            await self?.flush()
        }
    }

    private func makeSnapshot() -> PhotoManagerCacheSnapshot {
        PhotoManagerCacheSnapshot(
            sizes: sizes,
            photoHashes: photoHashes,
            videoFingerprints: videoFingerprints,
            photoDuplicates: photoDuplicates,
            photoSimilars: photoSimilars,
            videoDuplicates: videoDuplicates,
            videoSimilars: videoSimilars,
            aiCategories: aiCategories,
            blurryPhotoIDs: blurryPhotoIDs,
            photoScanCompleted: photoScanCompleted,
            videoScanCompleted: videoScanCompleted,
            blurScanCompleted: blurScanCompleted
        )
    }

    private func applySnapshot(_ snapshot: PhotoManagerCacheSnapshot) {
        sizes = snapshot.sizes
        photoHashes = snapshot.photoHashes
        videoFingerprints = snapshot.videoFingerprints
        photoDuplicates = snapshot.photoDuplicates
        photoSimilars = snapshot.photoSimilars
        videoDuplicates = snapshot.videoDuplicates
        videoSimilars = snapshot.videoSimilars
        aiCategories = snapshot.aiCategories
        blurryPhotoIDs = snapshot.blurryPhotoIDs
        photoScanCompleted = snapshot.photoScanCompleted
        videoScanCompleted = snapshot.videoScanCompleted
        blurScanCompleted = snapshot.blurScanCompleted
    }
}

// MARK: - Binary snapshot

/// Full in-memory snapshot of everything `PhotoManagerCache` persists.
struct PhotoManagerCacheSnapshot: Equatable, Sendable {
    var sizes: [String: AssetSizeRecord]
    var photoHashes: [String: UInt64]
    var videoFingerprints: [String: VideoFingerprintRecord]
    var photoDuplicates: [DedupeGroup]
    var photoSimilars: [DedupeGroup]
    var videoDuplicates: [DedupeGroup]
    var videoSimilars: [DedupeGroup]
    var aiCategories: [String: String]
    var blurryPhotoIDs: Set<String>
    var photoScanCompleted: Bool
    var videoScanCompleted: Bool
    var blurScanCompleted: Bool
}

/// Packed binary codec for `PhotoManagerCacheSnapshot`.
///
/// One envelope per file so a save stays a single atomic write. Every read is
/// bounds-checked against the remaining bytes and each section pre-validates its
/// record count, so a corrupt or truncated file returns `nil` instead of crashing.
nonisolated enum PhotoManagerCacheBinaryCodec {
    /// ASCII "PLMC" — Photo Library Manager Cache.
    private static let magic: [UInt8] = [0x50, 0x4C, 0x4D, 0x43]
    /// Bump when the field layout changes; older files fall back to the legacy JSON path.
    private static let version: UInt32 = 1

    // MARK: Encoding

    static func encode(_ snapshot: PhotoManagerCacheSnapshot) -> Data {
        var writer = BinaryWriter(reserveCapacity: estimatedByteCount(for: snapshot))
        for byte in magic { writer.append(byte) }
        writer.append(version)

        var flags: UInt8 = 0
        if snapshot.photoScanCompleted { flags |= 0x01 }
        if snapshot.videoScanCompleted { flags |= 0x02 }
        if snapshot.blurScanCompleted { flags |= 0x04 }
        writer.append(flags)

        writer.append(UInt32(snapshot.sizes.count))
        for (id, record) in snapshot.sizes {
            writer.append(string: id)
            writer.append(record.totalBytes)
            writer.append(record.stillBytes)
            writer.append(record.videoBytes)
            writer.append(record.isLivePhoto)
            if let modificationDate = record.modificationDate {
                writer.append(true)
                writer.append(modificationDate.timeIntervalSince1970)
            } else {
                writer.append(false)
            }
        }

        writer.append(UInt32(snapshot.photoHashes.count))
        for (id, hash) in snapshot.photoHashes {
            writer.append(string: id)
            writer.append(hash)
        }

        writer.append(UInt32(snapshot.videoFingerprints.count))
        for (id, fingerprint) in snapshot.videoFingerprints {
            writer.append(string: id)
            writer.append(fingerprint.duration)
            writer.append(fingerprint.keyframeHash)
            writer.append(Int64(fingerprint.pixelWidth))
            writer.append(Int64(fingerprint.pixelHeight))
        }

        for groups in [
            snapshot.photoDuplicates,
            snapshot.photoSimilars,
            snapshot.videoDuplicates,
            snapshot.videoSimilars,
        ] {
            writer.append(UInt32(groups.count))
            for group in groups {
                writer.append(string: group.id)
                writer.append(group.matchKind == .exactDuplicate ? UInt8(0) : UInt8(1))
                writer.append(UInt32(group.items.count))
                for item in group.items {
                    writer.append(string: item.id)
                    if let creationDate = item.creationDate {
                        writer.append(true)
                        writer.append(creationDate.timeIntervalSince1970)
                    } else {
                        writer.append(false)
                    }
                    writer.append(Int64(item.pixelWidth))
                    writer.append(Int64(item.pixelHeight))
                    writer.append(item.duration)
                    writer.append(item.totalBytes)
                    writer.append(item.stillBytes)
                    writer.append(item.videoBytes)
                    var itemFlags: UInt8 = 0
                    if item.isLivePhoto { itemFlags |= 0x01 }
                    if item.isVideo { itemFlags |= 0x02 }
                    if item.isFavorite { itemFlags |= 0x04 }
                    if item.isSelectedForDeletion { itemFlags |= 0x08 }
                    writer.append(itemFlags)
                }
                writer.append(string: group.bestAssetID)
            }
        }

        writer.append(UInt32(snapshot.aiCategories.count))
        for (id, category) in snapshot.aiCategories {
            writer.append(string: id)
            writer.append(string: category)
        }

        writer.append(UInt32(snapshot.blurryPhotoIDs.count))
        for id in snapshot.blurryPhotoIDs {
            writer.append(string: id)
        }

        return writer.data
    }

    // MARK: Decoding

    static func decode(_ data: Data) -> PhotoManagerCacheSnapshot? {
        var reader = BinaryReader(data: data)
        do {
            guard try reader.readBytes(magic.count) == magic else { throw BinaryCodecError.badMagic }
            guard try reader.readUInt32() == version else { throw BinaryCodecError.unsupportedVersion }
            let flags = try reader.readByte()

            let sizeCount = Int(try reader.beginSection(minRecordBytes: 30))
            var sizes = [String: AssetSizeRecord](minimumCapacity: sizeCount)
            for _ in 0..<sizeCount {
                let id = try reader.readString()
                let totalBytes = try reader.readInt64()
                let stillBytes = try reader.readInt64()
                let videoBytes = try reader.readInt64()
                let isLivePhoto = try reader.readBool()
                let modificationDate = try reader.readBool()
                    ? Date(timeIntervalSince1970: try reader.readDouble())
                    : nil
                sizes[id] = AssetSizeRecord(
                    totalBytes: totalBytes,
                    stillBytes: stillBytes,
                    videoBytes: videoBytes,
                    isLivePhoto: isLivePhoto,
                    modificationDate: modificationDate
                )
            }

            let hashCount = Int(try reader.beginSection(minRecordBytes: 12))
            var photoHashes = [String: UInt64](minimumCapacity: hashCount)
            for _ in 0..<hashCount {
                let id = try reader.readString()
                photoHashes[id] = try reader.readUInt64()
            }

            let fingerprintCount = Int(try reader.beginSection(minRecordBytes: 36))
            var videoFingerprints = [String: VideoFingerprintRecord](minimumCapacity: fingerprintCount)
            for _ in 0..<fingerprintCount {
                let id = try reader.readString()
                let duration = try reader.readDouble()
                let keyframeHash = try reader.readUInt64()
                let pixelWidth = try reader.readInt64()
                let pixelHeight = try reader.readInt64()
                videoFingerprints[id] = VideoFingerprintRecord(
                    duration: duration,
                    keyframeHash: keyframeHash,
                    pixelWidth: Int(pixelWidth),
                    pixelHeight: Int(pixelHeight)
                )
            }

            func readGroups() throws -> [DedupeGroup] {
                let count = Int(try reader.beginSection(minRecordBytes: 13))
                var groups = [DedupeGroup]()
                groups.reserveCapacity(count)
                for _ in 0..<count {
                    let id = try reader.readString()
                    let matchKind: DedupeMatchKind
                    switch try reader.readByte() {
                    case 0: matchKind = .exactDuplicate
                    case 1: matchKind = .similar
                    default: throw BinaryCodecError.invalidValue
                    }
                    let itemCount = Int(try reader.beginSection(minRecordBytes: 54))
                    var items = [DedupeAssetItem]()
                    items.reserveCapacity(itemCount)
                    for _ in 0..<itemCount {
                        let itemID = try reader.readString()
                        let creationDate = try reader.readBool()
                            ? Date(timeIntervalSince1970: try reader.readDouble())
                            : nil
                        let pixelWidth = try reader.readInt64()
                        let pixelHeight = try reader.readInt64()
                        let duration = try reader.readDouble()
                        let totalBytes = try reader.readInt64()
                        let stillBytes = try reader.readInt64()
                        let videoBytes = try reader.readInt64()
                        let itemFlags = try reader.readByte()
                        items.append(
                            DedupeAssetItem(
                                id: itemID,
                                creationDate: creationDate,
                                pixelWidth: Int(pixelWidth),
                                pixelHeight: Int(pixelHeight),
                                duration: duration,
                                totalBytes: totalBytes,
                                stillBytes: stillBytes,
                                videoBytes: videoBytes,
                                isLivePhoto: itemFlags & 0x01 != 0,
                                isVideo: itemFlags & 0x02 != 0,
                                isFavorite: itemFlags & 0x04 != 0,
                                isSelectedForDeletion: itemFlags & 0x08 != 0
                            )
                        )
                    }
                    let bestAssetID = try reader.readString()
                    groups.append(
                        DedupeGroup(id: id, matchKind: matchKind, items: items, bestAssetID: bestAssetID)
                    )
                }
                return groups
            }

            let photoDuplicates = try readGroups()
            let photoSimilars = try readGroups()
            let videoDuplicates = try readGroups()
            let videoSimilars = try readGroups()

            let aiCategoryCount = Int(try reader.beginSection(minRecordBytes: 8))
            var aiCategories = [String: String](minimumCapacity: aiCategoryCount)
            for _ in 0..<aiCategoryCount {
                let id = try reader.readString()
                aiCategories[id] = try reader.readString()
            }

            let blurryCount = Int(try reader.beginSection(minRecordBytes: 4))
            var blurryPhotoIDs = Set<String>(minimumCapacity: blurryCount)
            for _ in 0..<blurryCount {
                blurryPhotoIDs.insert(try reader.readString())
            }

            return PhotoManagerCacheSnapshot(
                sizes: sizes,
                photoHashes: photoHashes,
                videoFingerprints: videoFingerprints,
                photoDuplicates: photoDuplicates,
                photoSimilars: photoSimilars,
                videoDuplicates: videoDuplicates,
                videoSimilars: videoSimilars,
                aiCategories: aiCategories,
                blurryPhotoIDs: blurryPhotoIDs,
                photoScanCompleted: flags & 0x01 != 0,
                videoScanCompleted: flags & 0x02 != 0,
                blurScanCompleted: flags & 0x04 != 0
            )
        } catch {
            return nil
        }
    }

    /// Rough payload estimate so the encoder avoids repeated buffer growth.
    private static func estimatedByteCount(for snapshot: PhotoManagerCacheSnapshot) -> Int {
        var total = 64
        total += snapshot.sizes.count * 64
        total += snapshot.photoHashes.count * 28
        total += snapshot.videoFingerprints.count * 48
        total += (
            snapshot.photoDuplicates.count + snapshot.photoSimilars.count
                + snapshot.videoDuplicates.count + snapshot.videoSimilars.count
        ) * 96
        total += snapshot.aiCategories.count * 40
        total += snapshot.blurryPhotoIDs.count * 40
        return total
    }
}

// MARK: - Binary primitives

private enum BinaryCodecError: Error {
    case truncated
    case badMagic
    case unsupportedVersion
    case invalidUTF8
    case invalidValue
}

nonisolated private struct BinaryWriter {
    var data: Data

    init(reserveCapacity: Int) {
        data = Data()
        data.reserveCapacity(reserveCapacity)
    }

    mutating func append(_ byte: UInt8) {
        data.append(byte)
    }

    mutating func append(_ flag: Bool) {
        data.append(flag ? 1 : 0)
    }

    mutating func append(_ value: UInt32) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: UInt64) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func append(_ value: Int64) {
        append(UInt64(bitPattern: value))
    }

    /// Raw bit pattern — survives round trips bit-exactly, unlike a text format.
    mutating func append(_ value: Double) {
        append(value.bitPattern)
    }

    mutating func append(string value: String) {
        let utf8 = Array(value.utf8)
        append(UInt32(utf8.count))
        data.append(contentsOf: utf8)
    }
}

nonisolated private struct BinaryReader {
    let data: Data
    var offset: Int = 0

    var remaining: Int { data.count - offset }

    /// Reads a section count and rejects values no valid payload could contain,
    /// so corrupt data fails here instead of after a huge preallocation.
    mutating func beginSection(minRecordBytes: Int) throws -> UInt32 {
        let count = try readUInt32()
        guard Int(count) <= remaining / minRecordBytes else { throw BinaryCodecError.truncated }
        return count
    }

    mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count <= remaining else { throw BinaryCodecError.truncated }
        defer { offset += count }
        return Array(data[offset..<(offset + count)])
    }

    mutating func readByte() throws -> UInt8 {
        guard remaining >= 1 else { throw BinaryCodecError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readBool() throws -> Bool {
        switch try readByte() {
        case 0: return false
        case 1: return true
        default: throw BinaryCodecError.invalidValue
        }
    }

    mutating func readUInt32() throws -> UInt32 {
        guard remaining >= 4 else { throw BinaryCodecError.truncated }
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(data[offset + i]) << UInt32(i * 8)
        }
        offset += 4
        return value
    }

    mutating func readUInt64() throws -> UInt64 {
        guard remaining >= 8 else { throw BinaryCodecError.truncated }
        var value: UInt64 = 0
        for i in 0..<8 {
            value |= UInt64(data[offset + i]) << UInt64(i * 8)
        }
        offset += 8
        return value
    }

    mutating func readInt64() throws -> Int64 {
        Int64(bitPattern: try readUInt64())
    }

    mutating func readDouble() throws -> Double {
        Double(bitPattern: try readUInt64())
    }

    mutating func readString() throws -> String {
        let length = Int(try readUInt32())
        guard length <= remaining else { throw BinaryCodecError.truncated }
        defer { offset += length }
        guard let string = String(bytes: data[offset..<(offset + length)], encoding: .utf8) else {
            throw BinaryCodecError.invalidUTF8
        }
        return string
    }
}
