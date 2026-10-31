import Foundation

#if canImport(Photos)
import Photos
#endif

/// Scanner generating chronological year-month timelines, user albums, and AI category groupings.
public enum TimelineAndAIScanner {
    
    #if canImport(Photos)
    // MARK: - 1. Chronological Timeline (Collapsible Years & Months)
    
    public static func buildTimeline(
        photos: [PHAsset],
        sizeRecords: [String: AssetSizeRecord] = [:]
    ) -> [YearSection] {
        let calendar = Calendar.current
        var yearMap: [Int: [Int: [PHAsset]]] = [:]
        
        for asset in photos {
            let date = asset.creationDate ?? Date()
            let comps = calendar.dateComponents([.year, .month], from: date)
            guard let year = comps.year, let month = comps.month else { continue }
            
            if yearMap[year] == nil {
                yearMap[year] = [:]
            }
            if yearMap[year]?[month] == nil {
                yearMap[year]?[month] = []
            }
            yearMap[year]?[month]?.append(asset)
        }
        
        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale.current
        
        var yearSections: [YearSection] = []
        let sortedYears = yearMap.keys.sorted(by: >)
        
        for year in sortedYears {
            guard let monthsInYear = yearMap[year] else { continue }
            let sortedMonths = monthsInYear.keys.sorted(by: >)
            
            var monthGroups: [MonthGroup] = []
            var yearTotalBytes: Int64 = 0
            var yearTotalCount = 0
            
            for m in sortedMonths {
                guard let assets = monthsInYear[m], !assets.isEmpty else { continue }
                
                let monthName = monthFormatter.monthSymbols[m - 1]
                let ids = assets.map(\.localIdentifier)
                let totalBytes = ids.reduce(0) { $0 + (sizeRecords[$1]?.totalBytes ?? 0) }
                
                let group = MonthGroup(
                    id: "\(year)-\(String(format: "%02d", m))",
                    year: year,
                    month: m,
                    monthName: monthName,
                    assetIDs: ids,
                    coverAssetID: ids.first,
                    count: assets.count,
                    totalBytes: totalBytes
                )
                
                monthGroups.append(group)
                yearTotalBytes += totalBytes
                yearTotalCount += assets.count
            }
            
            yearSections.append(
                YearSection(
                    year: year,
                    months: monthGroups,
                    totalCount: yearTotalCount,
                    totalBytes: yearTotalBytes
                )
            )
        }
        
        return yearSections
    }
    
    // MARK: - 2. AI Categorized Photo Albums (Non-blocking & Backgrounded)
    
    /// Fast non-blocking assembly of AI categories from cached classifications and instant metadata.
    /// Takes < 5ms for 50k photos; NEVER executes synchronous Vision requests.
    public static func scanAICategories(
        photos: [PHAsset],
        sizeRecords: [String: AssetSizeRecord] = [:],
        cachedCategories: [String: String] = [:],
        onNewClassifications: (([String: String]) -> Void)? = nil
    ) -> [AICategoryItem] {
        buildAICategories(
            photos: photos,
            sizeRecords: sizeRecords,
            cachedCategories: cachedCategories,
            screenshotAlbumIDs: []
        )
    }
    
    /// Pure in-memory grouping of assets by cached AI category and instant metadata flags.
    ///
    /// Screenshots are **not** built from AI or `.photoScreenshot` here — main seeds
    /// that rail from the system Screenshots album only. Pass `screenshotAlbumIDs`
    /// from `photoSmartAlbums` when publishing.
    public static func buildAICategories(
        photos: [PHAsset],
        sizeRecords: [String: AssetSizeRecord] = [:],
        cachedCategories: [String: String] = [:],
        screenshotAlbumIDs: [String] = []
    ) -> [AICategoryItem] {
        var natureIDs: [String] = []
        var peopleIDs: [String] = []
        var indoorIDs: [String] = []
        var vehicleIDs: [String] = []
        var deviceIDs: [String] = []
        var foodIDs: [String] = []
        var docIDs: [String] = []
        var animalIDs: [String] = []

        for asset in photos {
            let id = asset.localIdentifier

            // 1. Instant check: persistent cache first
            var category = cachedCategories[id]

            // 2. Fast metadata fallback (instant, zero ML inference overhead).
            // Screenshots stay out — system album only.
            if category == nil {
                if asset.mediaSubtypes.contains(.photoDepthEffect) {
                    category = AIPhotoCategory.people.pmkCacheID
                } else if asset.mediaSubtypes.contains(.photoPanorama) {
                    category = AIPhotoCategory.nature.pmkCacheID
                }
            }

            guard let cat = category, let parsed = AIPhotoCategory(pmkCacheID: cat) else { continue }

            switch parsed {
            case .nature: natureIDs.append(id)
            case .people: peopleIDs.append(id)
            case .food: foodIDs.append(id)
            case .animals: animalIDs.append(id)
            case .indoor: indoorIDs.append(id)
            case .vehicle: vehicleIDs.append(id)
            case .device: deviceIDs.append(id)
            case .docs: docIDs.append(id)
            case .screenshots: break // System album only — ignore cached Vision labels.
            case .others: break // Assigned for cache completeness; never shown as an album.
            }
        }

        func makeCategory(
            id: String,
            title: String,
            icon: String,
            color: String,
            ids: [String]
        ) -> AICategoryItem? {
            guard !ids.isEmpty else { return nil }
            let bytes = ids.reduce(0) { $0 + (sizeRecords[$1]?.totalBytes ?? 0) }
            return AICategoryItem(
                id: id,
                title: title,
                sfSymbol: icon,
                colorName: color,
                count: ids.count,
                totalBytes: bytes,
                assetIDs: ids,
                coverAssetID: ids.first
            )
        }

        var categories = [
            makeCategory(id: AIPhotoCategory.nature.pmkCacheID, title: "Nature & Outdoor", icon: "leaf.fill", color: "green", ids: natureIDs),
            makeCategory(id: AIPhotoCategory.people.pmkCacheID, title: "People & Portraits", icon: "person.2.fill", color: "blue", ids: peopleIDs),
            makeCategory(id: AIPhotoCategory.food.pmkCacheID, title: "Food & Drinks", icon: "fork.knife", color: "orange", ids: foodIDs),
            makeCategory(id: AIPhotoCategory.animals.pmkCacheID, title: "Pets & Animals", icon: "pawprint.fill", color: "pink", ids: animalIDs),
            makeCategory(id: AIPhotoCategory.indoor.pmkCacheID, title: "Indoor & Home", icon: "house.fill", color: "indigo", ids: indoorIDs),
            makeCategory(id: AIPhotoCategory.vehicle.pmkCacheID, title: "Vehicles", icon: "car.fill", color: "cyan", ids: vehicleIDs),
            makeCategory(id: AIPhotoCategory.device.pmkCacheID, title: "Screens & Devices", icon: "desktopcomputer", color: "purple", ids: deviceIDs),
            makeCategory(id: AIPhotoCategory.docs.pmkCacheID, title: "Documents & Text", icon: "doc.text.image.fill", color: "yellow", ids: docIDs)
        ].compactMap { $0 }

        if let shots = makeCategory(
            id: AIPhotoCategory.screenshots.pmkCacheID,
            title: "Screenshots",
            icon: "camera.viewfinder",
            color: "red",
            ids: screenshotAlbumIDs
        ) {
            categories.append(shots)
        }
        return categories
    }
    
    /// Classification output for one batch: photo ID → AI category, plus the
    /// IDs flagged blurry (checked on the same decoded thumbnail).
    public struct AIBatchResult: Sendable {
        public var categories: [String: String] = [:]
        public var blurryIDs: [String] = []

        public init(categories: [String: String] = [:], blurryIDs: [String] = []) {
            self.categories = categories
            self.blurryIDs = blurryIDs
        }
    }

    /// Background asynchronous classifier for uncached photos.
    /// Runs off the main actor, classifying in small batches with autoreleasepool and Task.yield().
    /// `blurReharvestAll` additionally re-evaluates blur for photos whose category
    /// is already cached (Vision skipped) so a heuristic upgrade clears stale flags.
    public static func classifyUncachedPhotosInBackground(
        photos: [PHAsset],
        cachedCategories: [String: String],
        batchSize: Int = 20,
        blurReharvestAll: Bool = false,
        pause: (@Sendable () async -> Void)? = nil,
        onBatchComplete: @escaping @Sendable (AIBatchResult) async -> Void
    ) async {
        let uncached = photos.filter { cachedCategories[$0.localIdentifier] == nil }
        let blurOnly = blurReharvestAll
            ? photos.filter { cachedCategories[$0.localIdentifier] != nil }
            : []
        guard !uncached.isEmpty || !blurOnly.isEmpty else { return }

        var currentBatch = AIBatchResult()
        currentBatch.categories.reserveCapacity(batchSize)

        for asset in uncached {
            if Task.isCancelled { break }

            let result = await Self.classifyOnUtilityWorker(asset: asset)
            if let cat = result?.category {
                currentBatch.categories[asset.localIdentifier] = cat
            }
            if result?.isBlurry == true {
                currentBatch.blurryIDs.append(asset.localIdentifier)
            }

            if currentBatch.categories.count >= batchSize {
                let batchToEmit = currentBatch
                currentBatch = AIBatchResult()
                currentBatch.categories.reserveCapacity(batchSize)
                await pause?()
                await onBatchComplete(batchToEmit)
                await Task.yield()
            }
        }

        // Re-harvest sweep: cached categories skip Vision classification but
        // still get blur-evaluated so a heuristic upgrade clears stale flags
        // instead of inheriting them from the old pass.
        var sinceYield = 0
        for asset in blurOnly {
            if Task.isCancelled { break }
            if let blurry = AIPhotoClassifier.evaluateBlurOnly(asset: asset), blurry {
                currentBatch.blurryIDs.append(asset.localIdentifier)
            }
            sinceYield += 1
            if sinceYield >= 200 {
                sinceYield = 0
                await pause?()
                await Task.yield()
            }
        }

        if !currentBatch.categories.isEmpty || !currentBatch.blurryIDs.isEmpty {
            await onBatchComplete(currentBatch)
        }
    }

    /// Synchronous thumbnail decode + Vision inference blocks a Swift
    /// concurrency pool thread for tens of milliseconds per photo — at scale
    /// that starves the pool and delays every MainActor hop behind it. Run the
    /// work on a utility GCD worker instead, matching the size resolver.
    /// Internal (not private) so the incremental library sync can classify
    /// just-added photos without a full AI sort pass.
    static func classifyOnUtilityWorker(asset: PHAsset) async -> AIPhotoClassifier.ClassificationResult? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = autoreleasepool {
                    AIPhotoClassifier.classify(asset: asset)
                }
                continuation.resume(returning: result)
            }
        }
    }
    
    // MARK: - 3. User Photo Albums
    
    /// Favorites (system smart album) first, then user albums — same order as
    /// the main Swipe albums rail. Favorites is not a `.album` collection, so
    /// it must be fetched separately or the rail never shows it.
    public static func fetchUserAlbums(
        sizeRecords: [String: AssetSizeRecord] = [:]
    ) -> [UserAlbumItem] {
        var items: [UserAlbumItem] = []

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]

        let favorites = PHAssetCollection.fetchAssetCollections(
            with: .smartAlbum,
            subtype: .smartAlbumFavorites,
            options: nil
        )
        favorites.enumerateObjects { collection, _, _ in
            if let item = userAlbumItem(
                from: collection,
                options: fetchOptions,
                sizeRecords: sizeRecords,
                titleFallback: "Favorites"
            ) {
                items.append(item)
            }
        }
        
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        
        collections.enumerateObjects { collection, _, _ in
            if let item = userAlbumItem(
                from: collection,
                options: fetchOptions,
                sizeRecords: sizeRecords,
                titleFallback: "Untitled Album"
            ) {
                items.append(item)
            }
        }
        
        return items
    }

    private static func userAlbumItem(
        from collection: PHAssetCollection,
        options: PHFetchOptions,
        sizeRecords: [String: AssetSizeRecord],
        titleFallback: String
    ) -> UserAlbumItem? {
        let assets = PHAsset.fetchAssets(in: collection, options: options)
        guard assets.count > 0 else { return nil }

        var ids: [String] = []
        ids.reserveCapacity(assets.count)
        var totalBytes: Int64 = 0

        assets.enumerateObjects { asset, _, _ in
            ids.append(asset.localIdentifier)
            totalBytes += (sizeRecords[asset.localIdentifier]?.totalBytes ?? 0)
        }

        return UserAlbumItem(
            id: collection.localIdentifier,
            title: collection.localizedTitle ?? titleFallback,
            count: assets.count,
            totalBytes: totalBytes,
            assetIDs: ids,
            coverAssetID: ids.first
        )
    }
    #endif
}
