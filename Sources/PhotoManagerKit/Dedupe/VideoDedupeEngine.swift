import Foundation
import CoreGraphics

#if canImport(Photos)
import Photos
#endif

#if canImport(UIKit)
import UIKit
#endif

/// High-throughput perceptual hashing & duplicate clustering engine for videos.
/// Emits live progress directly to video cards and caches fingerprints to disk.
/// Optimized for large libraries with memory-bounded clustering and fast duration pruning.
public enum VideoDedupeEngine {
    
    #if canImport(Photos)
    /// Scans an array of video assets, checks cached fingerprints, hashes keyframes, and clusters into duplicate/similar groups.
    public static func scanVideoDedupe(
        videos: [PHAsset],
        cache: PhotoManagerCache = .shared,
        sizeRecords: [String: AssetSizeRecord] = [:],
        preset: SimilarityPreset = .balanced,
        pause: (@Sendable () async -> Void)? = nil,
        progressHandler: (@Sendable (ScanProgress) -> Void)? = nil
    ) async -> (duplicates: [DedupeGroup], similars: [DedupeGroup]) {
        guard !videos.isEmpty else {
            progressHandler?(.done)
            return ([], [])
        }

        let totalCount = videos.count
        let fingerprintMap = await fingerprintAndCacheVideos(videos: videos, cache: cache, pause: pause, progressHandler: progressHandler)
        
        var videoRecords: [(asset: PHAsset, fingerprint: VideoFingerprintRecord)] = []
        videoRecords.reserveCapacity(totalCount)
        for video in videos {
            if let fp = fingerprintMap[video.localIdentifier] {
                videoRecords.append((video, fp))
            }
        }
        
        // Cluster into Duplicate & Similar Groups
        // Signal the grouping phase immediately so the card switches from "Hashing" to "Grouping".
        progressHandler?(
            ScanProgress(
                processed: totalCount,
                total: totalCount,
                isScanning: true,
                label: "Grouping"
            )
        )
        let clustered = await clusterVideos(
            videoRecords,
            sizeRecords: sizeRecords,
            preset: preset,
            pause: pause,
            progressHandler: progressHandler
        )
        await cache.putVideoGroups(duplicates: clustered.duplicates, similars: clustered.similars)
        progressHandler?(ScanProgress(processed: totalCount, total: totalCount, isScanning: false))
        return clustered
    }
    
    /// Warms the video fingerprint cache for all videos without clustering. Safe to run concurrently
    /// with size fetching so that video fingerprinting wall-clock time overlaps the size index build.
    public static func warmVideoFingerprintCache(
        videos: [PHAsset],
        cache: PhotoManagerCache = .shared,
        progressHandler: (@Sendable (ScanProgress) -> Void)? = nil
    ) async {
        guard !videos.isEmpty else { return }
        _ = await fingerprintAndCacheVideos(videos: videos, cache: cache, pause: nil, progressHandler: progressHandler)
    }

    /// Incrementally folds newly-added videos into existing dedupe groups.
    ///
    /// Fingerprints only the new videos, matches each against the full cached
    /// fingerprint set — identical keyframe hash (or same-dimension posters
    /// within `exactPromotionDistance`, i.e. re-encoded copies) inside the
    /// exact duration window for duplicates, a non-zero hamming distance
    /// within the similar window for similars — then appends the newcomer to
    /// the group a match already belongs to, or forms a new cluster. An exact
    /// match is pulled out of any similar group it was sitting in. Mirrors
    /// the full scan's rules without re-clustering the library.
    ///
    /// Returns the fully merged group arrays plus whether anything changed;
    /// the caller publishes and persists them only when `merged` is true.
    public static func mergeNewVideos(
        _ videos: [PHAsset],
        intoDuplicates existingDuplicates: [DedupeGroup],
        similars existingSimilars: [DedupeGroup],
        cache: PhotoManagerCache = .shared,
        sizeRecords: [String: AssetSizeRecord] = [:],
        preset: SimilarityPreset = .balanced
    ) async -> (duplicates: [DedupeGroup], similars: [DedupeGroup], merged: Bool) {
        guard !videos.isEmpty else { return (existingDuplicates, existingSimilars, false) }

        // 1. Fingerprint only uncached new videos; complete ID→fingerprint map.
        let allFingerprints = await fingerprintAndCacheVideos(videos: videos, cache: cache, pause: nil, progressHandler: nil)
        guard allFingerprints.count > 1 else { return (existingDuplicates, existingSimilars, false) }

        // 2. Candidate search per new video vs the whole library.
        let hammingThreshold = Self.videoSimilarThreshold(preset)
        var exactMatchesByID: [String: [String]] = [:]
        var similarMatchesByID: [String: [String]] = [:]

        for video in videos {
            if Task.isCancelled { return (existingDuplicates, existingSimilars, false) }
            let id = video.localIdentifier
            guard let fingerprint = allFingerprints[id], fingerprint.keyframeHash != 0 else { continue }
            var exact: [String] = []
            var similar: [String] = []
            for (otherID, other) in allFingerprints where otherID != id {
                // Skip unreliably-fingerprinted peers (iCloud-only bytes etc.) —
                // the old engine's fabricated hashes grouped unrelated clips.
                guard other.keyframeHash != 0, !other.isLegacyFabricatedHash else { continue }
                let durationDiff = abs(other.duration - fingerprint.duration)
                let dist = (fingerprint.keyframeHash ^ other.keyframeHash).nonzeroBitCount
                if durationDiff <= Self.exactVideoDurationWindow &&
                    (dist == 0 || Self.isPromotedExactMatch(
                        fingerprint.keyframeHash,
                        pixelWidth: fingerprint.pixelWidth,
                        pixelHeight: fingerprint.pixelHeight,
                        other.keyframeHash,
                        otherWidth: other.pixelWidth,
                        otherHeight: other.pixelHeight
                    )) {
                    exact.append(otherID)
                } else if Self.isSimilarDuration(fingerprint.duration, other.duration)
                    && dist > 0 && dist <= hammingThreshold {
                    // Creation-date gate applied below once candidate assets resolve.
                    similar.append(otherID)
                }
            }
            if !exact.isEmpty { exactMatchesByID[id] = exact }
            if !similar.isEmpty { similarMatchesByID[id] = similar }
        }

        var candidateIDs = Set(exactMatchesByID.values.joined())
        candidateIDs.formUnion(similarMatchesByID.values.joined())
        guard !candidateIDs.isEmpty else { return (existingDuplicates, existingSimilars, false) }

        // 3. Resolve candidate assets so ungrouped matches can join new groups.
        var candidateAssets: [String: PHAsset] = [:]
        candidateAssets.reserveCapacity(videos.count)
        for video in videos { candidateAssets[video.localIdentifier] = video }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: Array(candidateIDs), options: nil)
        fetched.enumerateObjects { asset, _, _ in
            if candidateAssets[asset.localIdentifier] == nil {
                candidateAssets[asset.localIdentifier] = asset
            }
        }

        // 4. Merge into copies of the published groups.
        var duplicates = existingDuplicates
        var similars = existingSimilars
        var membership: [String: (isDup: Bool, index: Int)] = [:]
        for (index, group) in duplicates.enumerated() {
            for item in group.items { membership[item.id] = (true, index) }
        }
        for (index, group) in similars.enumerated() {
            for item in group.items { membership[item.id] = (false, index) }
        }

        var didMerge = false
        for video in videos {
            if Task.isCancelled { break }
            let id = video.localIdentifier

            // EXACT phase wins. Identical copies are removed from Similar so
            // the same clip cannot stay in both lists.
            if let exacts = exactMatchesByID[id], !exacts.isEmpty {
                if placeExactCluster(
                    video,
                    matches: exacts,
                    candidateAssets: candidateAssets,
                    duplicates: &duplicates,
                    similars: &similars,
                    membership: &membership,
                    sizeRecords: sizeRecords
                ) {
                    didMerge = true
                }
                continue
            }
            if let sims = similarMatchesByID[id], !sims.isEmpty {
                // A near match of a duplicate stays out of that duplicate group.
                // Creation-date proximity matches the full-cluster ~4h window.
                let anchorDate = video.creationDate ?? .distantPast
                let usable = sims.filter { matchID in
                    guard let peer = candidateAssets[matchID] else { return false }
                    let peerDate = peer.creationDate ?? .distantPast
                    guard abs(peerDate.timeIntervalSince(anchorDate)) <= Self.similarVideoCreationWindow
                    else { return false }
                    guard let ref = membership[matchID] else { return true }
                    return !ref.isDup
                }
                if !usable.isEmpty {
                    mergeNewVideo(
                        video,
                        matches: usable,
                        candidateAssets: candidateAssets,
                        into: &duplicates,
                        similars: &similars,
                        membership: &membership,
                        isExact: false,
                        sizeRecords: sizeRecords
                    )
                    didMerge = true
                }
            }
        }

        if removeDuplicateMembers(from: &similars, duplicates: duplicates) {
            didMerge = true
        }

        return (duplicates, similars, didMerge)
    }

    /// Shared merge step: absorb the newcomer into the first group containing
    /// one of its matches (folding ungrouped matches in as full members), or
    /// create a new cluster from the newcomer + ungrouped matches.
    private static func mergeNewVideo(
        _ asset: PHAsset,
        matches: [String],
        candidateAssets: [String: PHAsset],
        into duplicates: inout [DedupeGroup],
        similars: inout [DedupeGroup],
        membership: inout [String: (isDup: Bool, index: Int)],
        isExact: Bool,
        sizeRecords: [String: AssetSizeRecord]
    ) {
        let id = asset.localIdentifier
        var target: (isDup: Bool, index: Int)?
        for matchID in matches {
            guard let ref = membership[matchID] else { continue }
            // Exact copies join a duplicate group only. Near matches join a
            // similar group only — crossing the two is how one clip showed
            // up in both Similar Videos and Duplicate Videos.
            if isExact != ref.isDup { continue }
            let group = ref.isDup ? duplicates[ref.index] : similars[ref.index]
            if group.items.contains(where: { $0.id == id }) { return }
            target = ref
            break
        }

        if let target {
            for matchID in matches where membership[matchID] == nil {
                guard let member = candidateAssets[matchID] else { continue }
                if target.isDup {
                    appendVideoAsset(member, to: &duplicates[target.index], sizeRecords: sizeRecords)
                } else {
                    appendVideoAsset(member, to: &similars[target.index], sizeRecords: sizeRecords)
                }
                membership[matchID] = target
            }
            if target.isDup {
                appendVideoAsset(asset, to: &duplicates[target.index], sizeRecords: sizeRecords)
            } else {
                appendVideoAsset(asset, to: &similars[target.index], sizeRecords: sizeRecords)
            }
            membership[id] = target
            return
        }

        var members: [PHAsset] = [asset]
        for matchID in matches {
            if membership[matchID] == nil, let member = candidateAssets[matchID] {
                members.append(member)
            }
        }
        guard members.count > 1 else { return }
        let group = makeVideoGroup(from: members, kind: isExact ? .exactDuplicate : .similar, sizeRecords: sizeRecords)
        let index: Int
        if isExact {
            index = duplicates.count
            duplicates.append(group)
        } else {
            index = similars.count
            similars.append(group)
        }
        for member in members {
            membership[member.localIdentifier] = (isExact, index)
        }
    }

    /// Appends one video to an existing group and recomputes the keeper
    /// (favorite first, then largest pixel area — identical to `makeVideoGroup`).
    private static func appendVideoAsset(
        _ asset: PHAsset,
        to group: inout DedupeGroup,
        sizeRecords: [String: AssetSizeRecord]
    ) {
        let total = sizeRecords[asset.localIdentifier]?.totalBytes ?? 0
        group.items.append(
            DedupeAssetItem(
                id: asset.localIdentifier,
                creationDate: asset.creationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                duration: asset.duration,
                totalBytes: total,
                stillBytes: 0,
                videoBytes: total,
                isLivePhoto: false,
                isVideo: true,
                isFavorite: asset.isFavorite,
                isSelectedForDeletion: false // recomputed below
            )
        )
        guard let best = group.items.max(by: {
            ($0.isFavorite ? 1 : 0, $0.pixelWidth * $0.pixelHeight)
                < ($1.isFavorite ? 1 : 0, $1.pixelWidth * $1.pixelHeight)
        }) else { return }
        group.bestAssetID = best.id
        for index in group.items.indices {
            group.items[index].isSelectedForDeletion = group.items[index].id != best.id
        }
    }

    /// Puts the newcomer and its identical-hash matches into one duplicate
    /// group, and takes those clips out of Similar Videos.
    ///
    /// - Returns: `true` when a duplicate group was created or extended.
    private static func placeExactCluster(
        _ asset: PHAsset,
        matches: [String],
        candidateAssets: [String: PHAsset],
        duplicates: inout [DedupeGroup],
        similars: inout [DedupeGroup],
        membership: inout [String: (isDup: Bool, index: Int)],
        sizeRecords: [String: AssetSizeRecord]
    ) -> Bool {
        var memberIDs: [String] = [asset.localIdentifier]
        for match in matches where match != asset.localIdentifier && !memberIDs.contains(match) {
            memberIDs.append(match)
        }

        var sourceIndices = Set<Int>()
        for id in memberIDs {
            if let ref = membership[id], ref.isDup {
                sourceIndices.insert(ref.index)
            }
        }

        var items: [DedupeAssetItem] = []
        var seen = Set<String>()
        for index in sourceIndices.sorted() {
            for item in duplicates[index].items where seen.insert(item.id).inserted {
                items.append(item)
            }
        }
        for id in memberIDs where !seen.contains(id) {
            guard let member = candidateAssets[id] else { continue }
            seen.insert(id)
            let total = sizeRecords[id]?.totalBytes ?? 0
            items.append(
                DedupeAssetItem(
                    id: id,
                    creationDate: member.creationDate,
                    pixelWidth: member.pixelWidth,
                    pixelHeight: member.pixelHeight,
                    duration: member.duration,
                    totalBytes: total,
                    stillBytes: 0,
                    videoBytes: total,
                    isLivePhoto: false,
                    isVideo: true,
                    isFavorite: member.isFavorite,
                    isSelectedForDeletion: false
                )
            )
        }
        guard let grouped = videoGroup(id: UUID().uuidString, kind: .exactDuplicate, items: items) else {
            return false
        }

        if !sourceIndices.isEmpty {
            duplicates = duplicates.enumerated().compactMap { index, group in
                sourceIndices.contains(index) ? nil : group
            }
        }
        _ = removeIDs(seen, from: &similars)
        duplicates.append(grouped)
        membership = membershipMap(duplicates: duplicates, similars: similars)
        return true
    }

    /// Drops any clip that already belongs to a duplicate group from Similar.
    /// A similar group left with fewer than two clips is removed.
    private static func removeDuplicateMembers(
        from similars: inout [DedupeGroup],
        duplicates: [DedupeGroup]
    ) -> Bool {
        let exactIDs = Set(duplicates.flatMap { $0.items.map(\.id) })
        guard !exactIDs.isEmpty else { return false }
        return removeIDs(exactIDs, from: &similars)
    }

    private static func removeIDs(_ ids: Set<String>, from similars: inout [DedupeGroup]) -> Bool {
        guard !ids.isEmpty else { return false }
        var changed = false
        var next: [DedupeGroup] = []
        next.reserveCapacity(similars.count)
        for group in similars {
            let kept = group.items.filter { !ids.contains($0.id) }
            if kept.count == group.items.count {
                next.append(group)
                continue
            }
            changed = true
            if let rebuilt = videoGroup(id: group.id, kind: .similar, items: kept) {
                next.append(rebuilt)
            }
        }
        if changed { similars = next }
        return changed
    }

    private static func videoGroup(
        id: String,
        kind: DedupeMatchKind,
        items: [DedupeAssetItem]
    ) -> DedupeGroup? {
        var seen = Set<String>()
        var unique = items.filter { seen.insert($0.id).inserted }
        guard unique.count > 1 else { return nil }
        let bestID = unique.max(by: {
            ($0.isFavorite ? 1 : 0, $0.pixelWidth * $0.pixelHeight)
                < ($1.isFavorite ? 1 : 0, $1.pixelWidth * $1.pixelHeight)
        })?.id ?? unique[0].id
        for index in unique.indices {
            unique[index].isSelectedForDeletion = unique[index].id != bestID
        }
        return DedupeGroup(id: id, matchKind: kind, items: unique, bestAssetID: bestID)
    }

    private static func membershipMap(
        duplicates: [DedupeGroup],
        similars: [DedupeGroup]
    ) -> [String: (isDup: Bool, index: Int)] {
        var membership: [String: (isDup: Bool, index: Int)] = [:]
        membership.reserveCapacity(duplicates.reduce(0) { $0 + $1.items.count } + similars.reduce(0) { $0 + $1.items.count })
        for (index, group) in duplicates.enumerated() {
            for item in group.items { membership[item.id] = (true, index) }
        }
        for (index, group) in similars.enumerated() {
            for item in group.items where membership[item.id] == nil {
                membership[item.id] = (false, index)
            }
        }
        return membership
    }
    
    /// Fingerprints every video that isn't already cached, persists the fingerprints, and returns a
    /// complete ID→fingerprint map including previously cached entries.
    private static func fingerprintAndCacheVideos(
        videos: [PHAsset],
        cache: PhotoManagerCache,
        pause: (@Sendable () async -> Void)?,
        progressHandler: (@Sendable (ScanProgress) -> Void)?
    ) async -> [String: VideoFingerprintRecord] {
        let totalCount = videos.count
        let cachedFingerprints = await cache.getAllVideoFingerprints()
        var resultFingerprints: [String: VideoFingerprintRecord] = [:]
        resultFingerprints.reserveCapacity(totalCount)

        var uncachedVideos: [PHAsset] = []
        uncachedVideos.reserveCapacity(min(totalCount, 2000))

        // Step 1: Check in-memory fingerprint cache (< 2ms). Entries written
        // by the old metadata-fallback path (or zero-hash sentinels) are
        // re-fingerprinted with real pixels below.
        for video in videos {
            guard let cached = cachedFingerprints[video.localIdentifier],
                  cached.keyframeHash != 0,
                  !cached.isLegacyFabricatedHash else {
                uncachedVideos.append(video)
                continue
            }
            resultFingerprints[video.localIdentifier] = cached
        }
        
        let alreadyProcessed = totalCount - uncachedVideos.count
        // Scan is underway (clustering will follow in scanVideoDedupe).
        progressHandler?(
            ScanProgress(
                processed: alreadyProcessed,
                total: totalCount,
                isScanning: true,
                label: "Hashing"
            )
        )
        
        // Step 2: Fingerprint uncached videos
        if !uncachedVideos.isEmpty {
            let imageManager = PHImageManager.default()
            let requestOptions = PHImageRequestOptions()
            requestOptions.isSynchronous = true
            requestOptions.resizeMode = .fast
            requestOptions.deliveryMode = .fastFormat
            requestOptions.isNetworkAccessAllowed = false
            
            var batch: [String: VideoFingerprintRecord] = [:]
            batch.reserveCapacity(100)
            
            var currentProcessed = alreadyProcessed
            let targetSize = CGSize(width: 32, height: 32)

            var sincePauseCheck = 0
            for video in uncachedVideos {
                if Task.isCancelled { break }
                sincePauseCheck += 1
                if sincePauseCheck >= 10 {
                    sincePauseCheck = 0
                    await pause?()
                }

                let fp = await computeVideoFingerprint(for: video, manager: imageManager, options: requestOptions, targetSize: targetSize)
                if fp.keyframeHash != 0 {
                    resultFingerprints[video.localIdentifier] = fp
                    batch[video.localIdentifier] = fp
                }
                currentProcessed += 1
                
                if batch.count >= 50 {
                    await cache.putVideoFingerprints(batch)
                    batch.removeAll(keepingCapacity: true)
                    await Task.yield()
                }
                
                if currentProcessed % 10 == 0 || currentProcessed == totalCount {
                    // Keep isScanning=true: grouping follows immediately after fingerprinting.
                    progressHandler?(
                        ScanProgress(
                            processed: currentProcessed,
                            total: totalCount,
                            isScanning: true,
                            label: "Hashing"
                        )
                    )
                }
            }
            
            if !batch.isEmpty {
                await cache.putVideoFingerprints(batch)
            }
        }
        
        return resultFingerprints
    }
    
    private static func computeVideoFingerprint(
        for asset: PHAsset,
        manager: PHImageManager,
        options: PHImageRequestOptions,
        targetSize: CGSize
    ) async -> VideoFingerprintRecord {
        // See PhotoDedupeEngine.computeHash: keep synchronous PhotoKit decode
        // off the concurrency pool.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = autoreleasepool {
                    manager.requestImage(
                        for: asset,
                        targetSize: targetSize,
                        contentMode: .aspectFill,
                        options: options
                    ) { image, _ in
                        var hash: UInt64 = 0
                        #if canImport(UIKit)
                        if let cgImage = image?.cgImage {
                            hash = PhotoDedupeEngine.computeDHash64(from: cgImage)
                        }
                        #endif
                        // 0 marks "no reliable pixels" (iCloud-only asset whose
                        // bytes are not local, or a uniform first frame). Never
                        // fabricate a hash from metadata: the old
                        // width^height^duration fallback collided for any two
                        // same-resolution videos within 2s of each other and
                        // grouped completely unrelated clips as "similar".
                        // Zero-hash videos stay out of the cache so a later
                        // scan re-fingers them once pixels exist.

                        let fp = VideoFingerprintRecord(
                            duration: asset.duration,
                            keyframeHash: hash,
                            pixelWidth: asset.pixelWidth,
                            pixelHeight: asset.pixelHeight
                        )
                        continuation.resume(returning: fp)
                    }
                }
            }
        }
    }
    
    private struct CompactVideoItem: Sendable {
        let originalIndex: Int
        let duration: TimeInterval
        let keyframeHash: UInt64
        let pixelWidth: Int
        let pixelHeight: Int
        let creationDate: Date
    }

    /// A single 32×32 poster dHash is far weaker evidence than the photo
    /// pipeline's full-res hashes, so the photo preset's 14/20/26-of-64 bit
    /// budget over-merges videos (same template/scene clips land in one
    /// "similar" group). Cap it at a fixed budget instead; distance 0 is
    /// never "similar" — those pairs are duplicates. 14 bits: the old
    /// 12-bit cap starved the Similar Videos card once same-resolution
    /// copies promoted to exact, and 14 is still inside the app's own
    /// "Strict" photo threshold.
    private static let videoSimilarBitBudget = 14

    private static func videoSimilarThreshold(_ preset: SimilarityPreset) -> Int {
        min(preset.hammingThreshold, videoSimilarBitBudget)
    }

    /// Copies exported or re-encoded from the same recording keep identical
    /// dimensions and length, but compression noise gives their posters a
    /// non-zero dHash distance. The old engine filed these as exact
    /// duplicates (the fabricated metadata hash collided); without this
    /// promotion they drift into Similar Videos and users see their
    /// duplicate videos filed as "similar". Promotion therefore matches the
    /// similar cap (`videoSimilarBitBudget`) but keeps the pixel-dimensions
    /// gate the similar bucket lacks: same resolution + ~1s duration + a
    /// near-identical poster is the same recording for practical purposes,
    /// and a same-dimension pair can no longer straddle both cards — a
    /// same-resolution pair either is close enough to be a duplicate or is
    /// not similar at all. Different-resolution copies stay in Similar
    /// Videos.
    private static let exactPromotionDistance = videoSimilarBitBudget

    /// True when two fingerprints are the same recording saved through
    /// different encoders: identical pixel dimensions and a poster distance
    /// inside the similar bit budget. Distance 0 is excluded — the caller's
    /// plain equality check already covers it.
    private static func isPromotedExactMatch(
        _ keyframeHash: UInt64,
        pixelWidth: Int,
        pixelHeight: Int,
        _ otherHash: UInt64,
        otherWidth: Int,
        otherHeight: Int
    ) -> Bool {
        guard pixelWidth == otherWidth, pixelHeight == otherHeight else { return false }
        let dist = (keyframeHash ^ otherHash).nonzeroBitCount
        return dist > 0 && dist <= exactPromotionDistance
    }

    /// Identical poster (distance 0) inside this window is a duplicate.
    /// The old 0.2s gate left the rest of a 1s-apart copy set in Similar
    /// Videos while the closer copies stayed in Duplicate Videos.
    private static let exactVideoDurationWindow: TimeInterval = 1.0

    /// Main's similar pass used a ~4h creation-date window between takes.
    private static let similarVideoCreationWindow: TimeInterval = 4 * 60 * 60

    /// Relative duration slack for similar (main AppConstants.similar tolerance band).
    private static let similarVideoDurationRelativeDelta: Double = 0.30

    /// Absolute duration floor used with the relative gate.
    private static let similarVideoDurationAbsoluteFloor: TimeInterval = 3.0

    /// Near-hash matches only. Distance 0 never qualifies — those are duplicates.
    private static func isSimilarDuration(_ a: TimeInterval, _ b: TimeInterval) -> Bool {
        let diff = abs(a - b)
        let maxDuration = max(1.0, max(a, b))
        return diff <= max(similarVideoDurationAbsoluteFloor, similarVideoDurationRelativeDelta * maxDuration)
    }
    
    private static func clusterVideos(
        _ list: [(asset: PHAsset, fingerprint: VideoFingerprintRecord)],
        sizeRecords: [String: AssetSizeRecord],
        preset: SimilarityPreset = .balanced,
        pause: (@Sendable () async -> Void)? = nil,
        progressHandler: (@Sendable (ScanProgress) -> Void)? = nil
    ) async -> (duplicates: [DedupeGroup], similars: [DedupeGroup]) {
        let totalCount = list.count
        guard totalCount > 1 else { return ([], []) }
        
        func emitGrouping(processed: Int) {
            progressHandler?(
                ScanProgress(
                    processed: min(processed, totalCount),
                    total: totalCount,
                    isScanning: true,
                    label: "Grouping"
                )
            )
        }
        
        // One row per asset. A repeated local identifier used to be clustered
        // twice and show up in both lists.
        var seenIDs = Set<String>()
        var compactList: [CompactVideoItem] = []
        compactList.reserveCapacity(totalCount)
        for (i, entry) in list.enumerated() {
            guard seenIDs.insert(entry.asset.localIdentifier).inserted else { continue }
            compactList.append(
                CompactVideoItem(
                    originalIndex: i,
                    duration: entry.fingerprint.duration,
                    keyframeHash: entry.fingerprint.keyframeHash,
                    pixelWidth: entry.fingerprint.pixelWidth,
                    pixelHeight: entry.fingerprint.pixelHeight,
                    creationDate: entry.asset.creationDate ?? .distantPast
                )
            )
        }
        
        // Exact phase sorts by duration for pruning; similar phase re-sorts by date.
        let sorted = compactList.sorted { $0.duration < $1.duration }
        let sortedCount = sorted.count

        var parent = Array(0..<sortedCount)
        var rank = [Int](repeating: 0, count: sortedCount)

        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            var current = x
            while parent[current] != root {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            guard ra != rb else { return }
            if rank[ra] < rank[rb] {
                parent[ra] = rb
            } else if rank[ra] > rank[rb] {
                parent[rb] = ra
            } else {
                parent[rb] = ra
                rank[ra] += 1
            }
        }

        func assets(for members: [Int]) -> [PHAsset] {
            var ids = Set<String>()
            var videos: [PHAsset] = []
            for member in members {
                let asset = list[sorted[member].originalIndex].asset
                if ids.insert(asset.localIdentifier).inserted {
                    videos.append(asset)
                }
            }
            return videos
        }

        // Phase 1: identical posters within the exact window, including a
        // chain (A~B and B~C) so a shorter similar clip cannot swallow the
        // pair into Similar Videos first. Same-dimension posters within the
        // similar bit budget are the same recording re-encoded — promoted
        // to exact.
        for i in 0..<sortedCount {
            let current = sorted[i]
            guard current.keyframeHash != 0 else { continue }
            var j = i + 1
            while j < sortedCount {
                let durationDiff = sorted[j].duration - current.duration
                if durationDiff > Self.exactVideoDurationWindow { break }
                if sorted[j].keyframeHash == current.keyframeHash ||
                    Self.isPromotedExactMatch(
                        current.keyframeHash,
                        pixelWidth: current.pixelWidth,
                        pixelHeight: current.pixelHeight,
                        sorted[j].keyframeHash,
                        otherWidth: sorted[j].pixelWidth,
                        otherHeight: sorted[j].pixelHeight
                    ) {
                    union(i, j)
                }
                j += 1
            }
            if i % 200 == 0 { await pause?() }
            if i % 500 == 0 { await Task.yield() }
            if i % 250 == 0, sortedCount > 0 {
                emitGrouping(processed: Int((Double(i) / Double(sortedCount)) * Double(totalCount) * 0.5))
            }
        }

        var exactComponents: [Int: [Int]] = [:]
        for i in 0..<sortedCount where sorted[i].keyframeHash != 0 {
            exactComponents[find(i), default: []].append(i)
        }

        var claimed = [Bool](repeating: false, count: totalCount)
        var rawExactGroups: [[PHAsset]] = []
        let exactRoots = exactComponents.keys.sorted {
            (exactComponents[$0]?.first ?? 0) < (exactComponents[$1]?.first ?? 0)
        }
        for root in exactRoots {
            let members = exactComponents[root] ?? []
            let videos = assets(for: members)
            guard videos.count > 1 else { continue }
            for member in members {
                claimed[sorted[member].originalIndex] = true
            }
            rawExactGroups.append(videos)
        }

        // Phase 2: near matches among clips that are not already duplicates.
        // Main's similar pass gated on creation-date proximity (~4h) rather than
        // a tight duration window — re-index by date for the same recall shape.
        parent = Array(0..<sortedCount)
        rank = [Int](repeating: 0, count: sortedCount)
        let similarThreshold = Self.videoSimilarThreshold(preset)
        let byDate = compactList.enumerated().sorted { $0.element.creationDate < $1.element.creationDate }
        // Map originalIndex → union-find index (same indices as `sorted` / phase 1).
        var ufIndexByOriginal = [Int](repeating: -1, count: totalCount)
        for (ufIdx, item) in sorted.enumerated() {
            ufIndexByOriginal[item.originalIndex] = ufIdx
        }

        for left in 0..<byDate.count {
            let current = byDate[left].element
            if claimed[current.originalIndex] || current.keyframeHash == 0 { continue }
            let leftUF = ufIndexByOriginal[current.originalIndex]
            guard leftUF >= 0 else { continue }
            var right = left + 1
            while right < byDate.count {
                let candidate = byDate[right].element
                let timeGap = candidate.creationDate.timeIntervalSince(current.creationDate)
                if timeGap > Self.similarVideoCreationWindow { break }
                if !claimed[candidate.originalIndex],
                   candidate.keyframeHash != 0,
                   Self.isSimilarDuration(current.duration, candidate.duration) {
                    let dist = (current.keyframeHash ^ candidate.keyframeHash).nonzeroBitCount
                    let rightUF = ufIndexByOriginal[candidate.originalIndex]
                    if dist > 0 && dist <= similarThreshold, rightUF >= 0 {
                        union(leftUF, rightUF)
                    }
                }
                right += 1
            }
            if left % 200 == 0 { await pause?() }
            if left % 500 == 0 { await Task.yield() }
            if left % 250 == 0, byDate.count > 0 {
                emitGrouping(processed: Int(Double(totalCount) * 0.5 + (Double(left) / Double(byDate.count)) * Double(totalCount) * 0.5))
            }
        }

        var similarComponents: [Int: [Int]] = [:]
        for i in 0..<sortedCount where !claimed[sorted[i].originalIndex] && sorted[i].keyframeHash != 0 {
            similarComponents[find(i), default: []].append(i)
        }

        var rawSimilarGroups: [[PHAsset]] = []
        let similarRoots = similarComponents.keys.sorted {
            (similarComponents[$0]?.first ?? 0) < (similarComponents[$1]?.first ?? 0)
        }
        for root in similarRoots {
            let members = similarComponents[root] ?? []
            let videos = assets(for: members)
            guard videos.count > 1 else { continue }
            rawSimilarGroups.append(videos)
        }

        // Grouping is purely fingerprint based and must NOT wait on size I/O.
        // Byte totals use whatever sizes are already indexed; the coordinator backfills
        // the remaining totals from the size index once the size fetch completes.
        let duplicates = rawExactGroups.map { makeVideoGroup(from: $0, kind: .exactDuplicate, sizeRecords: sizeRecords) }
        var similars = rawSimilarGroups.map { makeVideoGroup(from: $0, kind: .similar, sizeRecords: sizeRecords) }
        _ = removeDuplicateMembers(from: &similars, duplicates: duplicates)

        return (duplicates, similars)
    }
    
    private static func makeVideoGroup(
        from videos: [PHAsset],
        kind: DedupeMatchKind,
        sizeRecords: [String: AssetSizeRecord]
    ) -> DedupeGroup {
        var seenIDs = Set<String>()
        let uniqueVideos = videos.filter { seenIDs.insert($0.localIdentifier).inserted }
        let sortedByQuality = uniqueVideos.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            let resA = a.pixelWidth * a.pixelHeight
            let resB = b.pixelWidth * b.pixelHeight
            return resA > resB
        }
        let bestID = sortedByQuality.first?.localIdentifier ?? uniqueVideos[0].localIdentifier
        
        let items: [DedupeAssetItem] = uniqueVideos.map { asset in
            let record = sizeRecords[asset.localIdentifier] ?? AssetSizeRecord(
                totalBytes: 0,
                stillBytes: 0,
                videoBytes: 0,
                isLivePhoto: false,
                modificationDate: asset.modificationDate ?? asset.creationDate
            )
            let total = record.totalBytes
            let isBest = asset.localIdentifier == bestID
            
            return DedupeAssetItem(
                id: asset.localIdentifier,
                creationDate: asset.creationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                duration: asset.duration,
                totalBytes: total,
                stillBytes: 0,
                videoBytes: total,
                isLivePhoto: false,
                isVideo: true,
                isFavorite: asset.isFavorite,
                isSelectedForDeletion: !isBest
            )
        }
        
        return DedupeGroup(
            id: UUID().uuidString,
            matchKind: kind,
            items: items,
            bestAssetID: bestID
        )
    }
    
    #endif
}
