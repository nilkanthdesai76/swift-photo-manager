
#if DEBUG
func DLog(_ message: @autoclosure () -> String) {
    print(message())
}
#else
func DLog(_ message: @autoclosure () -> String) {}
#endif
import Foundation
import CoreGraphics

#if canImport(Photos)
import Photos
#endif

#if canImport(UIKit)
import UIKit
#endif

#if canImport(Vision)
import Vision
#endif

/// High-throughput perceptual hashing & duplicate clustering engine for photos.
/// Emits live progress directly to UI cards and persists hashes to disk cache.
/// Optimized for 50,000+ assets with O(N) exact dedupe and sub-50ms temporal gating.
public enum PhotoDedupeEngine {
    /// Computes Hamming distance between two 64-bit hashes.
    public static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    
    #if canImport(Photos)
    /// Scans an array of photos, checking cache first, hashing uncached photos, and clustering into duplicate/similar groups.
    public static func scanPhotoDedupe(
        assets: [PHAsset],
        cache: PhotoManagerCache = .shared,
        sizeRecords: [String: AssetSizeRecord] = [:],
        preset: SimilarityPreset = .balanced,
        pause: (@Sendable () async -> Void)? = nil,
        progressHandler: (@Sendable (ScanProgress) -> Void)? = nil
    ) async -> (duplicates: [DedupeGroup], similars: [DedupeGroup]) {
        guard !assets.isEmpty else {
            progressHandler?(.done)
            return ([], [])
        }

        let totalCount = assets.count
        let hashMap = await hashAndCachePhotos(assets: assets, cache: cache, pause: pause, progressHandler: progressHandler)
        
        // Build the ordered (asset, hash) list the clusterer expects.
        var assetHashes: [(asset: PHAsset, hash: UInt64)] = []
        assetHashes.reserveCapacity(totalCount)
        for asset in assets {
            if let h = hashMap[asset.localIdentifier] {
                assetHashes.append((asset, h))
            }
        }
        
        // Fast Cluster into Duplicate & Similar Groups
        // Signal the grouping phase immediately so the card switches from "Hashing" to "Grouping".
        progressHandler?(
            ScanProgress(
                processed: totalCount,
                total: totalCount,
                isScanning: true,
                label: "Grouping"
            )
        )
        let clustered = await clusterAssets(
            assetHashes,
            sizeRecords: sizeRecords,
            preset: preset,
            pause: pause,
            progressHandler: progressHandler
        )
        await cache.putPhotoGroups(duplicates: clustered.duplicates, similars: clustered.similars)
        progressHandler?(ScanProgress(processed: totalCount, total: totalCount, isScanning: false))
        return clustered
    }

    /// Incrementally folds newly-added photos into existing dedupe groups.
    ///
    /// Hashes only the new assets (cached hashes are reused), matches each
    /// against the full cached hash set — exact hash equality regardless of
    /// date, or hamming distance within the preset threshold and time window —
    /// then appends the newcomer to the group a match already belongs to, or
    /// forms a new cluster. This mirrors the full scan's matching rules
    /// without re-clustering the library.
    ///
    /// Returns the fully merged group arrays plus whether anything changed;
    /// the caller publishes and persists them only when `merged` is true.
    public static func mergeNewPhotos(
        _ assets: [PHAsset],
        intoDuplicates existingDuplicates: [DedupeGroup],
        similars existingSimilars: [DedupeGroup],
        cache: PhotoManagerCache = .shared,
        sizeRecords: [String: AssetSizeRecord] = [:],
        preset: SimilarityPreset = .balanced
    ) async -> (duplicates: [DedupeGroup], similars: [DedupeGroup], merged: Bool) {
        guard !assets.isEmpty else { return (existingDuplicates, existingSimilars, false) }

        // 1. Hash only uncached new assets; returns the complete ID→hash map.
        let allHashes = await hashAndCachePhotos(assets: assets, cache: cache, pause: nil, progressHandler: nil)
        guard allHashes.count > 1 else { return (existingDuplicates, existingSimilars, false) }

        var newByID: [String: PHAsset] = [:]
        newByID.reserveCapacity(assets.count)
        for asset in assets { newByID[asset.localIdentifier] = asset }

        // 2. Candidate search per new asset vs the whole library (new-new
        //    matches included — both hashes are in the map).
        let hammingThreshold = preset.hammingThreshold
        var exactMatchesByID: [String: [String]] = [:]
        var similarMatchesByID: [String: [String]] = [:]

        for asset in assets {
            if Task.isCancelled { return (existingDuplicates, existingSimilars, false) }
            let id = asset.localIdentifier
            guard let hash = allHashes[id], hash != 0 else { continue }
            var exact: [String] = []
            var similar: [String] = []
            for (otherID, otherHash) in allHashes where otherID != id && otherHash != 0 {
                let dist = (hash ^ otherHash).nonzeroBitCount
                if dist == 0 {
                    exact.append(otherID)
                } else if dist <= hammingThreshold {
                    similar.append(otherID)
                }
            }
            if !exact.isEmpty { exactMatchesByID[id] = exact }
            if !similar.isEmpty { similarMatchesByID[id] = similar }
        }

        var candidateIDs = Set(exactMatchesByID.values.joined())
        candidateIDs.formUnion(similarMatchesByID.values.joined())
        guard !candidateIDs.isEmpty else { return (existingDuplicates, existingSimilars, false) }

        // 3. Resolve candidate metadata: timestamps for the temporal windows,
        //    PHAssets so ungrouped matches can join newly formed groups.
        var candidateAssets = newByID
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

        for asset in assets {
            if Task.isCancelled { break }
            let id = asset.localIdentifier
            let newTimestamp = asset.creationDate?.timeIntervalSince1970 ?? 0

            // EXACT phase — identical hashes always share one group no matter
            // how far apart the copies were saved, and an exact match wins so
            // the asset never enters similar clustering.
            if let exacts = exactMatchesByID[id] {
                mergeNewAsset(
                    asset,
                    matches: exacts,
                    candidateAssets: candidateAssets,
                    into: &duplicates,
                    similars: &similars,
                    membership: &membership,
                    isExact: true,
                    sizeRecords: sizeRecords
                )
                didMerge = true
                continue
            }

            // SIMILAR phase — the full scan only applies the window when both
            // timestamps are known; same here.
            if let sims = similarMatchesByID[id] {
                let withinWindow = sims.filter { candidateID in
                    let candidate = candidateAssets[candidateID]?.creationDate?.timeIntervalSince1970 ?? 0
                    guard newTimestamp > 0, candidate > 0 else { return true }
                    return abs(candidate - newTimestamp) <= preset.timeWindow
                }
                if !withinWindow.isEmpty {
                    mergeNewAsset(
                        asset,
                        matches: withinWindow,
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

        return (duplicates, similars, didMerge)
    }

    /// Shared merge step: absorb the newcomer into the first group containing
    /// one of its matches (folding ungrouped matches in as full members), or
    /// create a new cluster from the newcomer + ungrouped matches.
    private static func mergeNewAsset(
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
            let group = ref.isDup ? duplicates[ref.index] : similars[ref.index]
            if group.items.contains(where: { $0.id == id }) { return }
            target = ref
            break
        }

        if let target {
            // Ungrouped matches join the same group so identical bursts stay together.
            for matchID in matches where membership[matchID] == nil {
                guard let member = candidateAssets[matchID] else { continue }
                if target.isDup {
                    appendPhotoAsset(member, to: &duplicates[target.index], sizeRecords: sizeRecords)
                } else {
                    appendPhotoAsset(member, to: &similars[target.index], sizeRecords: sizeRecords)
                }
                membership[matchID] = target
            }
            if target.isDup {
                appendPhotoAsset(asset, to: &duplicates[target.index], sizeRecords: sizeRecords)
            } else {
                appendPhotoAsset(asset, to: &similars[target.index], sizeRecords: sizeRecords)
            }
            membership[id] = target
            return
        }

        // Brand-new cluster: newcomer + every ungrouped match.
        var members: [PHAsset] = [asset]
        for matchID in matches {
            if membership[matchID] == nil, let member = candidateAssets[matchID] {
                members.append(member)
            }
        }
        guard members.count > 1 else { return }
        let group = makeGroup(from: members, kind: isExact ? .exactDuplicate : .similar, sizeRecords: sizeRecords)
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

    /// Appends one photo to an existing group and recomputes the keeper
    /// (favorite first, then largest pixel area — identical to `makeGroup`).
    private static func appendPhotoAsset(
        _ asset: PHAsset,
        to group: inout DedupeGroup,
        sizeRecords: [String: AssetSizeRecord]
    ) {
        let isLive = asset.mediaSubtypes.contains(.photoLive)
        let record = sizeRecords[asset.localIdentifier] ?? AssetSizeRecord(
            totalBytes: 0,
            stillBytes: 0,
            videoBytes: 0,
            isLivePhoto: isLive,
            modificationDate: asset.modificationDate ?? asset.creationDate
        )
        group.items.append(
            DedupeAssetItem(
                id: asset.localIdentifier,
                creationDate: asset.creationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                duration: asset.duration,
                totalBytes: record.totalBytes,
                stillBytes: record.stillBytes,
                videoBytes: record.videoBytes,
                isLivePhoto: isLive,
                isVideo: false,
                isFavorite: asset.isFavorite,
                isSelectedForDeletion: false // recomputed below
            )
        )
        recomputeBestAsset(in: &group)
    }

    private static func recomputeBestAsset(in group: inout DedupeGroup) {
        guard let best = group.items.max(by: {
            ($0.isFavorite ? 1 : 0, $0.pixelWidth * $0.pixelHeight)
                < ($1.isFavorite ? 1 : 0, $1.pixelWidth * $1.pixelHeight)
        }) else { return }
        group.bestAssetID = best.id
        for index in group.items.indices {
            group.items[index].isSelectedForDeletion = group.items[index].id != best.id
        }
    }

    /// Hashes every photo that isn't already cached, persists the hashes (and blur flags), and
    /// returns a complete ID→hash map including previously cached entries.
    private static func hashAndCachePhotos(
        assets: [PHAsset],
        cache: PhotoManagerCache,
        pause: (@Sendable () async -> Void)?,
        progressHandler: (@Sendable (ScanProgress) -> Void)?
    ) async -> [String: UInt64] {
        let totalCount = assets.count
        let cachedHashes = await cache.getAllPhotoHashes()
        var resultHashes = cachedHashes
        resultHashes.reserveCapacity(totalCount)
        
        var uncachedAssets: [PHAsset] = []
        uncachedAssets.reserveCapacity(min(totalCount, 5000))
        
        // Step 1: Check in-memory hash cache (< 2ms)
        for asset in assets {
            if cachedHashes[asset.localIdentifier] == nil {
                uncachedAssets.append(asset)
            }
        }
        
        let alreadyProcessed = totalCount - uncachedAssets.count
        // Scan is underway even when every hash was cached (clustering will follow in scanPhotoDedupe).
        progressHandler?(
            ScanProgress(
                processed: alreadyProcessed,
                total: totalCount,
                isScanning: true,
                label: "Hashing"
            )
        )
        
        // Step 2: Compute hashes for uncached assets using memory-bounded autorelease pools
        if !uncachedAssets.isEmpty {
            let imageManager = PHImageManager.default()
            let requestOptions = PHImageRequestOptions()
            requestOptions.isSynchronous = true
            requestOptions.resizeMode = .fast
            requestOptions.deliveryMode = .fastFormat
            requestOptions.isNetworkAccessAllowed = false
            
            var batchHashes: [String: UInt64] = [:]
            batchHashes.reserveCapacity(250)

            var currentProcessed = alreadyProcessed
            // Ultra-fast 32px thumbnail — blur analysis moved to the dedicated
            // blur-scan process (192px) so hashing stays at full speed.
            let targetSize = CGSize(width: 32, height: 32)

            var sincePauseCheck = 0
            for asset in uncachedAssets {
                if Task.isCancelled { break }
                sincePauseCheck += 1
                if sincePauseCheck >= 10 {
                    sincePauseCheck = 0
                    await pause?()
                }

                let hash = await computeHash(for: asset, manager: imageManager, options: requestOptions, targetSize: targetSize)
                resultHashes[asset.localIdentifier] = hash
                batchHashes[asset.localIdentifier] = hash
                currentProcessed += 1

                if batchHashes.count >= 200 {
                    await cache.putPhotoHashes(batchHashes)
                    batchHashes.removeAll(keepingCapacity: true)
                    await Task.yield()
                }

                if currentProcessed % 50 == 0 || currentProcessed == totalCount {
                    // Keep isScanning=true: grouping follows immediately after hashing, and the card
                    // must not flip to "Clean" in between.
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

            if !batchHashes.isEmpty {
                await cache.putPhotoHashes(batchHashes)
            }
        }

        return resultHashes
    }

    // MARK: - Perceptual Difference Hashing (dHash)

    private static func computeHash(
        for asset: PHAsset,
        manager: PHImageManager,
        options: PHImageRequestOptions,
        targetSize: CGSize
    ) async -> UInt64 {
        // Synchronous PhotoKit decode blocks a concurrency-pool thread per
        // photo — hop to GCD so MainActor hops never queue behind hashing.
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                _ = autoreleasepool {
                    manager.requestImage(
                        for: asset,
                        targetSize: targetSize,
                        contentMode: .aspectFill,
                        options: options
                    ) { image, _ in
                        #if canImport(UIKit)
                        if let cgImage = image?.cgImage, let raw = sampleGrayBytes(from: cgImage, width: 9, height: 8) {
                            continuation.resume(returning: dHash(fromRaw: raw, width: 9, height: 8))
                            return
                        }
                        #endif
                        // Fallback deterministic hash if the image is unavailable
                        // (iCloud-only assets with network access off). Mixed with a
                        // stable per-asset string hash so distinct assets can never
                        // collide into one exact bucket once the exact phase stops
                        // gating on time.
                        let fallback = UInt64(asset.pixelWidth ^ asset.pixelHeight ^ Int(asset.creationDate?.timeIntervalSince1970 ?? 0))
                            ^ fnv1a64(asset.localIdentifier)
                        continuation.resume(returning: fallback)
                    }
                }
            }
        }
    }

    /// Computes 64-bit gradient difference hash (dHash) from a CGImage.
    public static func computeDHash64(from image: CGImage) -> UInt64 {
        guard let rawData = sampleGrayBytes(from: image, width: 9, height: 8) else { return 0 }
        return dHash(fromRaw: rawData, width: 9, height: 8)
    }
    
    /// Renders an image into a grayscale byte buffer (device gray, no alpha).
    /// Backed by a stable manual allocation: passing `&array` to `CGContext`
    /// only guarantees the pointer for the initializer call, leaving the
    /// subsequent `draw` reading a dangling buffer.
    static func sampleGrayBytes(from image: CGImage, width: Int, height: Int) -> [UInt8]? {
        let count = width * height
        let ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: count)
        defer { ptr.deallocate() }
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: ptr,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return nil
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }
    
    private static func dHash(fromRaw rawData: [UInt8], width: Int, height: Int) -> UInt64 {
        var hash: UInt64 = 0
        for y in 0..<height {
            let rowOffset = y * width
            for x in 0..<(width - 1) {
                let left = rawData[rowOffset + x]
                let right = rawData[rowOffset + x + 1]
                if left > right {
                    hash |= (1 << (y * (width - 1) + x))
                }
            }
        }
        return hash
    }

    /// FNV-1a 64-bit over the asset's localIdentifier — keeps decode-failure
    /// fallback hashes unique per asset; otherwise two different photos with
    /// the same dimensions and creation second would share an exact bucket.
    private static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
    
    // MARK: - Blur Detection

    /// Minimum tonal spread required before a photo can be called blurry.
    /// Excludes flat scenes (solid walls, monochrome UI) that have no edges
    /// simply because there is nothing to focus on.
    private static let blurDetailStdDev = 8.0
    /// Contrast-normalized Laplacian energy. Phone thumbnails stay sharp-looking
    /// after downscale and sharpening, so a cutoff of 0.8 left real soft photos
    /// above the line and the blur album at 0. Crisp detail still lands higher.
    private static let blurNormalizedEnergyThreshold = 1.6

    /// Contrast-normalized blur heuristic on a grayscale sample: real tonal
    /// detail present (std dev), but weak high-frequency energy relative to
    /// the scene's own contrast. Shared by the AI classifier, which harvests
    /// the flag from its own 192px thumbnail.
    static func isBlurryPhoto(_ rawData: [UInt8], width: Int, height: Int) -> Bool {
        let count = rawData.count
        guard width > 2, height > 2, count >= width * height else { return false }

        var sum = 0
        for b in rawData { sum += Int(b) }
        let mean = Double(sum) / Double(count)

        var variance = 0.0
        for b in rawData {
            let d = Double(b) - mean
            variance += d * d
        }
        let varianceOfIntensity = variance / Double(count)
        let stdDev = varianceOfIntensity.squareRoot()
        guard stdDev > blurDetailStdDev else { return false }

        var lapSum = 0.0
        var lapSqSum = 0.0
        var lapCount = 0
        for y in 1..<(height - 1) {
            let row = y * width
            for x in 1..<(width - 1) {
                let i = row + x
                let lap = 4.0 * Double(rawData[i])
                    - Double(rawData[i - 1])
                    - Double(rawData[i + 1])
                    - Double(rawData[i - width])
                    - Double(rawData[i + width])
                lapSum += lap
                lapSqSum += lap * lap
                lapCount += 1
            }
        }
        guard lapCount > 0 else { return false }
        let lapMean = lapSum / Double(lapCount)
        let lapVariance = lapSqSum / Double(lapCount) - lapMean * lapMean

        let normalizedEnergy = lapVariance / max(varianceOfIntensity, 1.0)
        return normalizedEnergy < blurNormalizedEnergyThreshold
    }

    // MARK: - Memory-Safe & O(N) High-Throughput Clustering
    
    private struct CompactPhotoItem: Sendable {
        let originalIndex: Int
        let id: String
        let hash: UInt64
        let timestamp: TimeInterval
        let isFavorite: Bool
        let pixelArea: Int
    }
    
    private static func clusterAssets(
        _ list: [(asset: PHAsset, hash: UInt64)],
        sizeRecords: [String: AssetSizeRecord],
        preset: SimilarityPreset = .strict,
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
        
        // 1. Flatten into contiguous, cache-friendly primitive structs (Zero Obj-C calls in comparison loop)
        var compactItems: [CompactPhotoItem] = []
        compactItems.reserveCapacity(totalCount)
        
        for (i, entry) in list.enumerated() {
            let asset = entry.asset
            let ts = asset.creationDate?.timeIntervalSince1970 ?? 0
            compactItems.append(
                CompactPhotoItem(
                    originalIndex: i,
                    id: asset.localIdentifier,
                    hash: entry.hash,
                    timestamp: ts,
                    isFavorite: asset.isFavorite,
                    pixelArea: asset.pixelWidth * asset.pixelHeight
                )
            )
        }
        
        var visited = [Bool](repeating: false, count: totalCount)
        // Raw group member lists collected during the hot loops; groups are built afterwards.
        var rawExactGroups: [[PHAsset]] = []
        var rawSimilarGroups: [[PHAsset]] = []
        
        // =========================================================================
        // PHASE 1: O(N) Exact Duplicates via Hash Table (Instantaneous for 50,000 items)
        // =========================================================================
        var exactBuckets: [UInt64: [Int]] = [:]
        exactBuckets.reserveCapacity(totalCount / 2)
        
        for (compactIndex, item) in compactItems.enumerated() {
            // Ignore fallback zero hash to prevent false collisions
            if item.hash != 0 {
                exactBuckets[item.hash, default: []].append(compactIndex)
            }
        }
        
        for (_, bucketIndices) in exactBuckets where bucketIndices.count > 1 {
            // Identical 64-bit dHash means identical content — copies re-saved
            // months apart are exactly the duplicates users expect in one tile,
            // so the whole bucket becomes a single chronological group. The old
            // anchored 30-day window split long-span sets into 2-by-2 tiles.
            let sortedIndices = bucketIndices.sorted { compactItems[$0].timestamp < compactItems[$1].timestamp }
            for cIdx in sortedIndices { visited[cIdx] = true }
            rawExactGroups.append(sortedIndices.map { list[compactItems[$0].originalIndex].asset })
        }

        // =========================================================================
        // PHASE 2: Similar Photos — union-find over chronologically local pairs
        // =========================================================================
        // Per-pair gates (time window + hamming) apply to every nearby pair and
        // union-find takes the transitive closure: copies strung across a long
        // span still land in one group when each link matches. The old anchored
        // scan compared only against the first item and broke at the window
        // edge, splitting exactly those sets into same-sized tiles.
        let unvisitedItems = compactItems.filter { !visited[$0.originalIndex] }
            .sorted { $0.timestamp < $1.timestamp }

        let similarTimeWindow: TimeInterval = preset.timeWindow
        let maxLookahead = preset.maxLookahead
        let hammingThreshold = preset.hammingThreshold
        let clusterTotal = unvisitedItems.count

        var ufParent = [Int](0..<clusterTotal)
        var ufRank = [Int](repeating: 0, count: clusterTotal)

        func findSet(_ x: Int) -> Int {
            var root = x
            while ufParent[root] != root { root = ufParent[root] }
            var cur = x
            while ufParent[cur] != root {
                let next = ufParent[cur]
                ufParent[cur] = root
                cur = next
            }
            return root
        }

        func unionSets(_ a: Int, _ b: Int) {
            let ra = findSet(a)
            let rb = findSet(b)
            guard ra != rb else { return }
            if ufRank[ra] < ufRank[rb] {
                ufParent[ra] = rb
            } else if ufRank[ra] > ufRank[rb] {
                ufParent[rb] = ra
            } else {
                ufParent[rb] = ra
                ufRank[ra] += 1
            }
        }

        for i in 0..<clusterTotal {
            let current = unvisitedItems[i]
            var comparisons = 0
            var j = i + 1
            while j < clusterTotal && comparisons < maxLookahead {
                let candidate = unvisitedItems[j]
                let timeDiff = candidate.timestamp - current.timestamp
                if timeDiff > similarTimeWindow && current.timestamp > 0 && candidate.timestamp > 0 {
                    break // Sorted order — every later candidate is even farther away.
                }
                comparisons += 1
                if (current.hash ^ candidate.hash).nonzeroBitCount <= hammingThreshold {
                    unionSets(i, j)
                }
                j += 1
            }

            if i % 200 == 0 {
                await pause?()
            }
            if i % 1000 == 0 {
                await Task.yield()
            }

            // Emit a real fraction during grouping so the ring moves with a visible percentage.
            if i % 500 == 0, clusterTotal > 0 {
                emitGrouping(processed: Int((Double(i) / Double(clusterTotal)) * Double(totalCount)))
            }
        }

        // Flatten union-find components into groups, chronological by first member.
        var components: [Int: [Int]] = [:]
        components.reserveCapacity(clusterTotal / 2)
        for i in 0..<clusterTotal {
            components[findSet(i), default: []].append(i)
        }
        let orderedRoots = components.keys.sorted { components[$0]?[0] ?? 0 < components[$1]?[0] ?? 0 }
        for root in orderedRoots {
            let members = components[root] ?? []
            guard members.count > 1 else { continue }
            for m in members {
                visited[unvisitedItems[m].originalIndex] = true
            }
            rawSimilarGroups.append(members.map { list[unvisitedItems[$0].originalIndex].asset })
        }

        // Rotation variants of one burst (4:3 vs 3:4 captures) land in
        // separate clusters above — gradient hashes are orientation-sensitive
        // and the aspect-fill crops genuinely differ. The Vision bridge below
        // merges those siblings and re-attaches dHash strays, calibrated to
        // the main-branch pipeline's similar threshold.
        #if canImport(Vision)
        var bridgeCandidates = rawSimilarGroups
        for i in 0..<clusterTotal where !visited[unvisitedItems[i].originalIndex] {
            bridgeCandidates.append([list[unvisitedItems[i].originalIndex].asset])
        }
        var hashByID: [String: UInt64] = [:]
        hashByID.reserveCapacity(list.count)
        for entry in list {
            hashByID[entry.asset.localIdentifier] = entry.hash
        }
        let bridged = await mergeRotationSiblingGroups(
            bridgeCandidates,
            hashByID: hashByID,
            fallbackHamming: preset.hammingThreshold,
            pause: pause
        )
        let finalSimilarGroups = bridged.filter { $0.count > 1 }
        #else
        let finalSimilarGroups = rawSimilarGroups
        #endif
        
        // Grouping is purely hash/dimension based and must NOT wait on size I/O.
        // Byte totals use whatever sizes are already indexed; the coordinator backfills
        // the remaining totals from the size index once the size fetch completes.
        let duplicates = rawExactGroups.map { makeGroup(from: $0, kind: .exactDuplicate, sizeRecords: sizeRecords) }
        let similars = finalSimilarGroups.map { makeGroup(from: $0, kind: .similar, sizeRecords: sizeRecords) }

        return (duplicates, similars)
    }

    // MARK: - Vision Bridge

    #if canImport(Vision)
    /// Two clusters shot within this window are burst siblings — one subject
    /// photographed in a single session. Only sibling pairs pay for a
    /// feature-print comparison.
    private static let rotationBridgeSpan: TimeInterval = 3 * 60 * 60
    /// Merge distance for feature prints, ported from the main-branch
    /// pipeline's similar threshold and validated against a real 13-photo
    /// burst (same-scene pairs ≤ ~0.36, different scenes ≥ ~0.45). Published
    /// dedupe apps calibrate the same way (0.35 default). Note that
    /// `computeDistance` magnitudes shift with the OS's request revision, so
    /// this is a calibration point to re-check after major iOS upgrades, not
    /// a physical constant.
    private static let rotationBridgeMaxDistance: Float = 0.4
    /// Backstop for pathological bursts: at most this many ATTEMPTED pairs
    /// per scan (counted before evaluation). 8k-photo libraries with ~1k
    /// similar items legitimately need a few thousand candidates; prints are
    /// cached per asset so the cost is decodes, not comparisons.
    private static let rotationBridgeMaxPairChecks = 2_000
    /// Windowed dHash fallback for candidates whose photos are iCloud-only
    /// and too small for a trustworthy feature print. Compared against the
    /// ACTIVE preset's threshold (passed in), so Strict runs stay strict.
    /// The 3-hour shoot window is what makes a looser-than-global cutoff safe.

    /// Decode-failure counters surfaced in the summary log — the bridge is
    /// useless when every print silently fails, so the reasons must be visible.
    private struct BridgeDecodeStats {
        var requested = 0
        var rejectedDegraded = 0
        var rejectedSmall = 0
        var rejectedNoImage = 0
        var recoveredCIImage = 0
        var printFailed = 0
        var sampleRejects: [String] = []
    }

    /// Merges dHash sibling clusters and re-attaches dHash strays. dHash
    /// splits what a human reads as one shoot (rotation variants, reframes
    /// past the hamming threshold), so for time-overlapping candidates this
    /// compares Vision feature prints of ALL members (single linkage — a
    /// group's outlier head can no longer block a merge) and merges within
    /// `rotationBridgeMaxDistance`. Feature prints are not rotation-invariant,
    /// so mixed-aspect pairs also compare 90°-rotated variants and take the
    /// min. Candidates whose photos cannot produce a print (iCloud-only
    /// surrogates) fall back to the windowed hamming threshold instead.
    /// Cost is bounded by suspicious pairs, per-asset print caching, and the
    /// pair-check cap.
    private static func mergeRotationSiblingGroups(
        _ groups: [[PHAsset]],
        hashByID: [String: UInt64],
        fallbackHamming: Int,
        pause: (@Sendable () async -> Void)?
    ) async -> [[PHAsset]] {
        guard groups.count > 1 else { return groups }

        struct Span {
            var min: TimeInterval
            var max: TimeInterval
            var isGroup: Bool
        }
        var spans: [Span] = []
        spans.reserveCapacity(groups.count)
        for group in groups {
            let dates = group.compactMap { $0.creationDate?.timeIntervalSince1970 }
            guard let maxDate = dates.max() else { continue }
            spans.append(Span(min: dates.min() ?? maxDate, max: maxDate, isGroup: group.count > 1))
        }
        guard spans.count > 1 else { return groups }

        var thumbnailByID: [String: CGImage] = [:]
        var printByID: [String: VNFeaturePrintObservation] = [:]
        var rotatedPrintByID: [String: VNFeaturePrintObservation] = [:]
        var stats = BridgeDecodeStats()

        func thumbnail(for asset: PHAsset) async -> CGImage? {
            let id = asset.localIdentifier
            if let cached = thumbnailByID[id] { return cached }
            let decoded = await rotationBridgeThumbnail(for: asset)
            stats.requested += 1
            if decoded.recoveredCIImage { stats.recoveredCIImage += 1 }
            if let reject = decoded.reject {
                switch reject {
                case "degraded": stats.rejectedDegraded += 1
                case "nilImage": stats.rejectedNoImage += 1
                default:
                    stats.rejectedSmall += 1
                    if stats.sampleRejects.count < 8 { stats.sampleRejects.append(reject) }
                }
            }
            guard let image = decoded.image else { return nil }
            thumbnailByID[id] = image
            return image
        }

        func nativePrint(for asset: PHAsset) async -> VNFeaturePrintObservation? {
            let id = asset.localIdentifier
            if let cached = printByID[id] { return cached }
            guard let image = await thumbnail(for: asset) else { return nil }
            guard let observation = featurePrint(of: image) else {
                stats.printFailed += 1
                return nil
            }
            printByID[id] = observation
            return observation
        }

        func rotatedPrint(for asset: PHAsset) async -> VNFeaturePrintObservation? {
            let id = asset.localIdentifier
            if let cached = rotatedPrintByID[id] { return cached }
            guard let image = await thumbnail(for: asset),
                  let rotated = rotate90(image) else { return nil }
            guard let observation = featurePrint(of: rotated) else {
                stats.printFailed += 1
                return nil
            }
            rotatedPrintByID[id] = observation
            return observation
        }

        func computeDistance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
            var d: Float = .infinity
            guard (try? a.computeDistance(&d, to: b)) != nil else { return .infinity }
            return d
        }

        func distance(_ a: PHAsset, _ b: PHAsset) async -> Float? {
            guard let pa = await nativePrint(for: a),
                  let pb = await nativePrint(for: b) else { return nil }
            var best = computeDistance(pa, pb)
            // Rotation twins only align when one side is viewed rotated — the
            // print itself has no rotation tolerance to lean on.
            let mixedAspect = (a.pixelHeight > a.pixelWidth) != (b.pixelHeight > b.pixelWidth)
            if mixedAspect {
                if let ra = await rotatedPrint(for: a) {
                    best = min(best, computeDistance(ra, pb))
                }
                if let rb = await rotatedPrint(for: b) {
                    best = min(best, computeDistance(pa, rb))
                }
            }
            return best
        }

        var ufParent = Array(0..<spans.count)
        func find(_ x: Int) -> Int {
            var root = x
            while ufParent[root] != root { root = ufParent[root] }
            var cur = x
            while ufParent[cur] != root {
                let next = ufParent[cur]
                ufParent[cur] = root
                cur = next
            }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            ufParent[rb] = ra
        }

        var pairChecks = 0
        var mergedPairs = 0
        var printlessPairs = 0
        outer: for i in 0..<spans.count {
            if Task.isCancelled { return groups }
            for j in (i + 1)..<spans.count where find(i) != find(j) {
                // At least one side must already be a group — merging two
                // dHash singletons is dHash's job, not the bridge's.
                guard spans[i].isGroup || spans[j].isGroup else { continue }
                let overlap = min(spans[i].max, spans[j].max) - max(spans[i].min, spans[j].min)
                guard overlap >= -Self.rotationBridgeSpan else { continue }
                // Count attempts before evaluation so printless pairs cannot
                // bypass the backstop and spam PhotoKit.
                pairChecks += 1
                if pairChecks > Self.rotationBridgeMaxPairChecks { break outer }

                var pairDistance = Float.infinity
                var evaluated = false
                var minHamming = Int.max
                for memberA in groups[i] {
                    if Task.isCancelled { return groups }
                    let hashA = hashByID[memberA.localIdentifier]
                    for memberB in groups[j] {
                        if let hashA, let hashB = hashByID[memberB.localIdentifier] {
                            minHamming = min(minHamming, (hashA ^ hashB).nonzeroBitCount)
                        }
                        if let d = await distance(memberA, memberB) {
                            pairDistance = min(pairDistance, d)
                            evaluated = true
                        }
                    }
                }
                // Prints win when they exist; the windowed hamming fallback
                // only decides pairs that produced no print at all.
                let mergedByPrint = evaluated && pairDistance <= Self.rotationBridgeMaxDistance
                let mergedByHamming = !evaluated && minHamming <= fallbackHamming
                guard evaluated || mergedByHamming else {
                    printlessPairs += 1
                    continue
                }
                if mergedByPrint || mergedByHamming {
                    union(i, j)
                    mergedPairs += 1
                    DLog("[Dedupe] Vision bridge merged clusters (\(mergedByPrint ? "print d=\(pairDistance)" : "windowed hamming=\(minHamming)"))")
                }
                if pairChecks % 10 == 0 {
                    if Task.isCancelled { return groups }
                    await pause?()
                }
            }
        }
        DLog("[Dedupe] Vision bridge: \(pairChecks) pairs attempted, \(mergedPairs) merged, \(printlessPairs) printless | thumbs requested=\(stats.requested) rejected degraded=\(stats.rejectedDegraded) small=\(stats.rejectedSmall) noImage=\(stats.rejectedNoImage) ciRecovered=\(stats.recoveredCIImage) printFailed=\(stats.printFailed) samples=\(stats.sampleRejects.prefix(5).joined(separator: "; "))")

        var mergedIndices: [Int: [Int]] = [:]
        for i in 0..<spans.count {
            mergedIndices[find(i), default: []].append(i)
        }
        var result: [[PHAsset]] = []
        result.reserveCapacity(mergedIndices.count)
        for (_, indices) in mergedIndices {
            guard indices.count > 1 else {
                result.append(groups[indices[0]])
                continue
            }
            let members = indices.flatMap { groups[$0] }.sorted {
                ($0.creationDate ?? .distantPast) < ($1.creationDate ?? .distantPast)
            }
            result.append(members)
        }
        return result
    }

    /// Plain feature print — rotation handling lives in the caller's variant
    /// comparison, not here.
    private static func featurePrint(of image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }

    /// In-memory 90° clockwise rotation of a decoded thumbnail.
    private static func rotate90(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(
            data: nil,
            width: h,
            height: w,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.translateBy(x: CGFloat(h) / 2, y: CGFloat(w) / 2)
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    private static func rotationBridgeThumbnail(for asset: PHAsset) async -> (image: CGImage?, reject: String?, recoveredCIImage: Bool) {
        // Synchronous request on a GCD worker — the same decode shape as the
        // classifier and hashing paths, which both deliver reliably on device.
        // The async-callback variant this replaced produced zero usable
        // images on a real library (34k printless pairs).
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let options = PHImageRequestOptions()
                options.isSynchronous = true
                // .fastFormat demonstrably returns the 90x120 embedded thumb
                // for every asset on device (logged) — highQualityFormat +
                // .exact performs a real decode at the requested size. iCloud-
                // only assets still fail the gate (no local copy, no network)
                // and fall to the windowed-hamming path.
                options.resizeMode = .exact
                options.deliveryMode = .highQualityFormat
                options.isNetworkAccessAllowed = false
                var result: CGImage?
                var reject: String?
                var recoveredCIImage = false
                PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: 512, height: 512),
                    contentMode: .aspectFill,
                    options: options
                ) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    var finalCGImage: CGImage?
                    #if canImport(UIKit)
                    finalCGImage = image?.cgImage
                    if finalCGImage == nil, let ciImage = image?.ciImage {
                        finalCGImage = CIContext(options: nil).createCGImage(ciImage, from: ciImage.extent)
                        recoveredCIImage = finalCGImage != nil
                    }
                    #elseif canImport(AppKit)
                    if let img = image {
                        var rect = CGRect(origin: .zero, size: CGSize(width: 512, height: 512))
                        finalCGImage = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
                        recoveredCIImage = finalCGImage != nil
                    }
                    #endif
                    if degraded {
                        reject = "degraded"
                    } else if let finalCGImage, min(finalCGImage.width, finalCGImage.height) >= 256 {
                        result = finalCGImage
                    } else if let finalCGImage {
                        reject = "small:\(finalCGImage.width)x\(finalCGImage.height)"
                    } else {
                        reject = "nilImage"
                    }
                }
                continuation.resume(returning: (result, reject, recoveredCIImage))
            }
        }
    }
    #endif
    
    private static func makeGroup(
        from assets: [PHAsset],
        kind: DedupeMatchKind,
        sizeRecords: [String: AssetSizeRecord]
    ) -> DedupeGroup {
        // Determine "Best" asset (favorites first, then largest pixel resolution)
        let sortedByQuality = assets.sorted { a, b in
            if a.isFavorite != b.isFavorite { return a.isFavorite }
            let resA = a.pixelWidth * a.pixelHeight
            let resB = b.pixelWidth * b.pixelHeight
            return resA > resB
        }
        let bestID = sortedByQuality.first?.localIdentifier ?? assets[0].localIdentifier
        
        let items: [DedupeAssetItem] = assets.map { asset in
            let record = sizeRecords[asset.localIdentifier] ?? AssetSizeRecord(
                totalBytes: 0,
                stillBytes: 0,
                videoBytes: 0,
                isLivePhoto: false,
                modificationDate: asset.modificationDate ?? asset.creationDate
            )
            let isBest = asset.localIdentifier == bestID
            
            return DedupeAssetItem(
                id: asset.localIdentifier,
                creationDate: asset.creationDate,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                duration: asset.duration,
                totalBytes: record.totalBytes,
                stillBytes: record.stillBytes,
                videoBytes: record.videoBytes,
                isLivePhoto: asset.mediaSubtypes.contains(.photoLive),
                isVideo: false,
                isFavorite: asset.isFavorite,
                isSelectedForDeletion: !isBest // Auto-select redundant copies for deletion
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
