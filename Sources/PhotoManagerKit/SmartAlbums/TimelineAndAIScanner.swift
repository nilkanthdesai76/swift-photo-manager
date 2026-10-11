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
            cachedCategories: cachedCategories
        )
    }
    
    /// Pure in-memory grouping of assets by cached AI category and instant metadata flags.
    public static func buildAICategories(
        photos: [PHAsset],
        sizeRecords: [String: AssetSizeRecord] = [:],
        cachedCategories: [String: String] = [:]
    ) -> [AICategoryItem] {
        var natureIDs: [String] = []
        var peopleIDs: [String] = []
        var indoorIDs: [String] = []
        var vehicleIDs: [String] = []
        var foodIDs: [String] = []
        var docIDs: [String] = []
        var animalIDs: [String] = []
        var cityIDs: [String] = []
        
        for asset in photos {
            let id = asset.localIdentifier
            
            // 1. Instant check: persistent cache first
            var category = cachedCategories[id]
            
            // 2. Fast metadata fallback (instant, zero ML inference overhead)
            if category == nil {
                if asset.mediaSubtypes.contains(.photoScreenshot) {
                    category = "ai_docs"
                } else if asset.mediaSubtypes.contains(.photoDepthEffect) {
                    category = "ai_people"
                } else if asset.mediaSubtypes.contains(.photoPanorama) {
                    category = "ai_nature"
                }
            }
            
            guard let cat = category else { continue }
            
            switch cat {
            case "ai_nature": natureIDs.append(id)
            case "ai_people": peopleIDs.append(id)
            case "ai_food": foodIDs.append(id)
            case "ai_animals": animalIDs.append(id)
            case "ai_indoor": indoorIDs.append(id)
            case "ai_vehicles": vehicleIDs.append(id)
            case "ai_city": cityIDs.append(id)
            case "ai_docs": docIDs.append(id)
            default: break
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
        
        return [
            makeCategory(id: "ai_nature", title: "Nature & Outdoor", icon: "leaf.fill", color: "green", ids: natureIDs),
            makeCategory(id: "ai_people", title: "People & Portraits", icon: "person.2.fill", color: "blue", ids: peopleIDs),
            makeCategory(id: "ai_food", title: "Food & Drinks", icon: "fork.knife", color: "orange", ids: foodIDs),
            makeCategory(id: "ai_animals", title: "Pets & Animals", icon: "pawprint.fill", color: "pink", ids: animalIDs),
            makeCategory(id: "ai_indoor", title: "Indoor & Home", icon: "house.fill", color: "indigo", ids: indoorIDs),
            makeCategory(id: "ai_vehicles", title: "Vehicles", icon: "car.fill", color: "cyan", ids: vehicleIDs),
            makeCategory(id: "ai_city", title: "City & Architecture", icon: "building.2.fill", color: "purple", ids: cityIDs),
            makeCategory(id: "ai_docs", title: "Documents & Text", icon: "doc.text.image.fill", color: "yellow", ids: docIDs)
        ].compactMap { $0 }
    }
    
    /// Background asynchronous classifier for uncached photos.
    /// Runs off the main actor, classifying in small batches with autoreleasepool and Task.yield().
    public static func classifyUncachedPhotosInBackground(
        photos: [PHAsset],
        cachedCategories: [String: String],
        batchSize: Int = 20,
        onBatchComplete: @escaping @Sendable ([String: String]) async -> Void
    ) async {
        let uncached = photos.filter { cachedCategories[$0.localIdentifier] == nil }
        guard !uncached.isEmpty else { return }
        
        var currentBatch: [String: String] = [:]
        currentBatch.reserveCapacity(batchSize)
        
        for asset in uncached {
            if Task.isCancelled { break }
            
            let detected = autoreleasepool {
                AIPhotoClassifier.classify(asset: asset)
            }
            if let cat = detected {
                currentBatch[asset.localIdentifier] = cat
            }
            
            if currentBatch.count >= batchSize {
                let batchToEmit = currentBatch
                currentBatch.removeAll(keepingCapacity: true)
                await onBatchComplete(batchToEmit)
                await Task.yield()
            }
        }
        
        if !currentBatch.isEmpty {
            await onBatchComplete(currentBatch)
        }
    }
    
    // MARK: - 3. User Photo Albums
    
    public static func fetchUserAlbums(
        sizeRecords: [String: AssetSizeRecord] = [:]
    ) -> [UserAlbumItem] {
        var items: [UserAlbumItem] = []
        
        let collections = PHAssetCollection.fetchAssetCollections(
            with: .album,
            subtype: .any,
            options: nil
        )
        
        collections.enumerateObjects { collection, _, _ in
            let assets = PHAsset.fetchAssets(in: collection, options: nil)
            guard assets.count > 0 else { return }
            
            var ids: [String] = []
            ids.reserveCapacity(assets.count)
            var totalBytes: Int64 = 0
            
            assets.enumerateObjects { asset, _, _ in
                ids.append(asset.localIdentifier)
                totalBytes += (sizeRecords[asset.localIdentifier]?.totalBytes ?? 0)
            }
            
            items.append(
                UserAlbumItem(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "Untitled Album",
                    count: assets.count,
                    totalBytes: totalBytes,
                    assetIDs: ids,
                    coverAssetID: ids.first
                )
            )
        }
        
        return items
    }
    #endif
}
