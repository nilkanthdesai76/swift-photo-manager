import XCTest
@testable import PhotoManagerKit
import PhotoKitManager

import AlgorithmKit

final class PhotoManagerKitTests: XCTestCase {
    
    // MARK: - 1. Byte Formatter Tests
    
    func testByteFormatter() {
        XCTAssertEqual(ByteFormatter.format(bytes: 0), "0 B")
        XCTAssertEqual(ByteFormatter.format(bytes: -10), "0 B")
        XCTAssertTrue(ByteFormatter.format(bytes: 1_048_576).contains("MB"))
        XCTAssertTrue(ByteFormatter.format(bytes: 1_073_741_824).contains("GB"))
    }
    
    // MARK: - 2. Storage Overview Tests
    
    func testLibraryStorageOverview() {
        let overview = LibraryStorageOverview(
            totalBytes: 50_000_000,
            totalCount: 15,
            photosBytes: 20_000_000,
            photosCount: 10,
            livePhotosTotalBytes: 15_000_000,
            livePhotosStillBytes: 5_000_000,
            livePhotosVideoBytes: 10_000_000,
            livePhotosCount: 3,
            videosBytes: 15_000_000,
            videosCount: 2,
            isEstimated: true
        )
        
        XCTAssertEqual(overview.totalBytes, 50_000_000)
        XCTAssertEqual(overview.totalCount, 15)
        XCTAssertEqual(overview.livePhotosStillBytes, 5_000_000)
        XCTAssertEqual(overview.livePhotosVideoBytes, 10_000_000)
        XCTAssertTrue(overview.isEstimated)
    }
    
    // MARK: - 3. Dedupe Group Reclaimable Math
    
    func testDedupeGroupReclaimableCalculation() {
        let item1 = DedupeAssetItem(id: "P1", totalBytes: 5_000_000)
        let item2 = DedupeAssetItem(id: "P2", totalBytes: 5_000_000, isSelectedForDeletion: true)
        let item3 = DedupeAssetItem(id: "P3", totalBytes: 5_000_000, isSelectedForDeletion: true)
        
        let group = DedupeGroup(
            id: "G1",
            matchKind: .exactDuplicate,
            items: [item1, item2, item3],
            bestAssetID: "P1"
        )
        
        XCTAssertEqual(group.totalGroupBytes, 15_000_000)
        XCTAssertEqual(group.reclaimableBytes, 10_000_000)
        XCTAssertEqual(group.selectedForDeletionBytes, 10_000_000)
    }
    
    // MARK: - 4. Perceptual Difference Hash Math
    
    func testDHashHammingDistance() {
        let hashA: UInt64 = 0b1111000011110000
        let hashB: UInt64 = 0b1111000011110000
        let hashC: UInt64 = 0b1111000011110001 // 1 bit diff
        
        XCTAssertEqual(PhotoDedupeEngine.hammingDistance(hashA, hashB), 0)
        XCTAssertEqual(PhotoDedupeEngine.hammingDistance(hashA, hashC), 1)
    }
    
    // MARK: - 5. Persistent Cache Tests
    
    func testPhotoManagerCache() async {
        let cache = PhotoManagerCache()
        await cache.bootstrap()
        
        let record = AssetSizeRecord(
            totalBytes: 7_500_000,
            stillBytes: 2_500_000,
            videoBytes: 5_000_000,
            isLivePhoto: true,
            modificationDate: Date()
        )
        
        await cache.putSizeBatch(["TEST_ASSET_1": record])
        let fetched = await cache.getSize(for: "TEST_ASSET_1")
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.totalBytes, 7_500_000)
        XCTAssertEqual(fetched?.stillBytes, 2_500_000)
        XCTAssertEqual(fetched?.videoBytes, 5_000_000)
        
        await cache.putPhotoHashes(["TEST_ASSET_1": 123456789])
        let hash = await cache.getPhotoHash(for: "TEST_ASSET_1")
        XCTAssertEqual(hash, 123456789)
        
        await cache.clear()
        let cleared = await cache.getSize(for: "TEST_ASSET_1")
        XCTAssertNil(cleared)
    }
    
    // MARK: - 6. AI Classifier Taxonomy Verification Tests
    
    func testAIClassifierTaxonomies() {
        // Verify clothing/shirt is NEVER categorized as a vehicle
        XCTAssertTrue(AIPhotoClassifier.indoorKeywords.contains("clothing"))
        XCTAssertTrue(AIPhotoClassifier.indoorKeywords.contains("iron_clothing"))
        XCTAssertFalse(AIPhotoClassifier.vehicleKeywords.contains("clothing"))
        XCTAssertFalse(AIPhotoClassifier.vehicleKeywords.contains("shirt"))
        XCTAssertFalse(AIPhotoClassifier.vehicleKeywords.contains("apparel"))
        
        // Verify vehicles contains actual vehicles
        XCTAssertTrue(AIPhotoClassifier.vehicleKeywords.contains("car"))
        XCTAssertTrue(AIPhotoClassifier.vehicleKeywords.contains("truck"))
        XCTAssertTrue(AIPhotoClassifier.vehicleKeywords.contains("motorcycle"))
        
        // Verify animals
        XCTAssertTrue(AIPhotoClassifier.animalKeywords.contains("dog"))
        XCTAssertTrue(AIPhotoClassifier.animalKeywords.contains("cat"))
        
        // Verify food
        XCTAssertTrue(AIPhotoClassifier.foodKeywords.contains("food"))
        XCTAssertTrue(AIPhotoClassifier.foodKeywords.contains("pizza"))
    }
    
    // MARK: - 7. Sort & Time Filter Logic Tests
    
    func testSortAndFilterLogic() {
        let now = Date()
        let cal = Calendar.current
        
        let twoDaysAgo = cal.date(byAdding: .day, value: -2, to: now)!
        let twentyDaysAgo = cal.date(byAdding: .day, value: -20, to: now)!
        let twoMonthsAgo = cal.date(byAdding: .day, value: -60, to: now)!
        
        // Filter .all
        XCTAssertTrue(AssetTimeFilter.all.matches(date: twoDaysAgo))
        XCTAssertTrue(AssetTimeFilter.all.matches(date: nil))
        
        // Filter .last7Days
        XCTAssertTrue(AssetTimeFilter.last7Days.matches(date: twoDaysAgo))
        XCTAssertFalse(AssetTimeFilter.last7Days.matches(date: twentyDaysAgo))
        
        // Filter .last30Days
        XCTAssertTrue(AssetTimeFilter.last30Days.matches(date: twoDaysAgo))
        XCTAssertTrue(AssetTimeFilter.last30Days.matches(date: twentyDaysAgo))
        XCTAssertFalse(AssetTimeFilter.last30Days.matches(date: twoMonthsAgo))
        
        // Filter .thisYear
        let currentYear = cal.component(.year, from: now)
        let midThisYear = cal.date(from: DateComponents(year: currentYear, month: 6, day: 15))!
        let midLastYear = cal.date(from: DateComponents(year: currentYear - 1, month: 6, day: 15))!
        let threeYearsAgo = cal.date(from: DateComponents(year: currentYear - 3, month: 6, day: 15))!
        
        XCTAssertTrue(AssetTimeFilter.thisYear.matches(date: midThisYear))
        XCTAssertFalse(AssetTimeFilter.thisYear.matches(date: midLastYear))
        
        // Filter .lastYear
        XCTAssertTrue(AssetTimeFilter.lastYear.matches(date: midLastYear))
        XCTAssertFalse(AssetTimeFilter.lastYear.matches(date: midThisYear))
        XCTAssertFalse(AssetTimeFilter.lastYear.matches(date: threeYearsAgo))
    }
    
    // MARK: - 8. Persistent AI Categories Cache Tests
    
    func testPhotoManagerCacheAICategories() async {
        let cache = PhotoManagerCache()
        await cache.bootstrap()
        
        await cache.setAICategories([
            "PHOTO_SHIRT": "ai_indoor",
            "PHOTO_CAR": "ai_vehicles",
            "PHOTO_CAT": "ai_animals"
        ])
        
        let cat1 = await cache.getAICategory(for: "PHOTO_SHIRT")
        let cat2 = await cache.getAICategory(for: "PHOTO_CAR")
        let cat3 = await cache.getAICategory(for: "PHOTO_CAT")
        
        XCTAssertEqual(cat1, "ai_indoor")
        XCTAssertEqual(cat2, "ai_vehicles")
        XCTAssertEqual(cat3, "ai_animals")
        
        await cache.clear()
        let clearedCat = await cache.getAICategory(for: "PHOTO_SHIRT")
        XCTAssertNil(clearedCat)
    }
    
    // MARK: - 9. PhotoKitManager Umbrella Import Test
    
    func testPhotoKitManagerUmbrellaModule() {
        let overview = PhotoKitManager.LibraryStorageOverview.empty
        XCTAssertEqual(overview.totalBytes, 0)
        XCTAssertEqual(PhotoKitManager.ByteFormatter.format(bytes: 1024), "1 KB")
    }
    
    // MARK: - 10. High-Throughput Hash Clustering Benchmark Test
    
    func testHighThroughputHashDistanceMath() {
        // Verify Hamming distance bitwise math for exact and similar thresholds
        let hashA: UInt64 = 0b1010101010101010
        let hashExact: UInt64 = 0b1010101010101010
        let hashSimilar: UInt64 = 0b1010101010101011 // 1 bit different
        let hashFar: UInt64 = 0b0101010101010101 // all bits different
        
        XCTAssertEqual(PhotoDedupeEngine.hammingDistance(hashA, hashExact), 0)
        XCTAssertEqual(PhotoDedupeEngine.hammingDistance(hashA, hashSimilar), 1)
        XCTAssertTrue(PhotoDedupeEngine.hammingDistance(hashA, hashSimilar) <= 8)
        XCTAssertFalse(PhotoDedupeEngine.hammingDistance(hashA, hashFar) <= 8)
    }
    
    // MARK: - 11. AssetSortOrder Smallest Option Tests
    
    func testAssetSortOrderSmallest() {
        let smallest = AssetSortOrder.smallest
        XCTAssertEqual(smallest.rawValue, "Smallest")
        XCTAssertEqual(smallest.title, "Smallest")
        XCTAssertEqual(smallest.sfSymbol, "arrow.up.circle")
    }
    
    // MARK: - 12. Declarative MultiSort Tests
    
    func testDeclarativeMultiSortWithAlgorithmKit() {
        struct MockAsset: Equatable {
            let id: String
            let bytes: Int64
            let date: Date
        }
        
        let d1 = Date(timeIntervalSince1970: 1000)
        let d2 = Date(timeIntervalSince1970: 2000)
        let d3 = Date(timeIntervalSince1970: 3000)
        
        let assets = [
            MockAsset(id: "A", bytes: 500, date: d1),
            MockAsset(id: "B", bytes: 1000, date: d2),
            MockAsset(id: "C", bytes: 500, date: d3),
            MockAsset(id: "D", bytes: 200, date: d1)
        ]
        
        // Multi-sort: bytes ascending (smallest), then date descending (latest)
        let sorted: [MockAsset] = assets.sorted(by: [
            SortDescriptor<MockAsset>.ascending(\MockAsset.bytes),
            SortDescriptor<MockAsset>.descending(\MockAsset.date)
        ])
        
        // 200 bytes (D), then 500 bytes with later date (C), then 500 bytes with earlier date (A), then 1000 bytes (B)
        XCTAssertEqual(sorted.map(\.id), ["D", "C", "A", "B"])
    }
    
    // MARK: - 13. Top-K Heaviest Media Selection Tests
    
    func testTopKHeaviestMediaSelection() {
        struct FileItem {
            let id: String
            let size: Int64
        }
        
        let files = [
            FileItem(id: "f1", size: 10),
            FileItem(id: "f2", size: 500),
            FileItem(id: "f3", size: 250),
            FileItem(id: "f4", size: 900),
            FileItem(id: "f5", size: 5),
            FileItem(id: "f6", size: 750)
        ]
        
        // Find top 3 heaviest in O(N log 3)
        let top3 = files.top(3) { a, b in
            a.size < b.size
        }
        
        XCTAssertEqual(top3.count, 3)
        XCTAssertEqual(top3.map(\.id), ["f4", "f6", "f2"])
        XCTAssertEqual(top3.map(\.size), [900, 750, 500])
    }
    
    // MARK: - 14. Fuzzy Search on Category and Album Titles
    
    func testFuzzySearchOnCategoriesAndAlbums() {
        struct SearchableItem {
            let id: String
            let title: String
        }
        
        let categories = [
            SearchableItem(id: "1", title: "Screenshots"),
            SearchableItem(id: "2", title: "Screen Recordings"),
            SearchableItem(id: "3", title: "Receipts & Documents"),
            SearchableItem(id: "4", title: "Architecture & Buildings"),
            SearchableItem(id: "5", title: "Vehicles & Transport")
        ]
        
        // Fuzzy search for "screen"
        let screenResults = categories.fuzzySearch("screen", on: \.title).map(\.item)
        XCTAssertEqual(screenResults.count, 2)
        XCTAssertTrue(screenResults.contains(where: { $0.id == "1" }))
        XCTAssertTrue(screenResults.contains(where: { $0.id == "2" }))
        
        // Fuzzy search for "rcpt" (non-contiguous characters in Receipts)
        let fuzzyResults = categories.fuzzySearch("rcpt", on: \.title).map(\.item)
        XCTAssertEqual(fuzzyResults.first?.id, "3")
        
        // Empty query returns all
        let allResults = categories.fuzzySearch("", on: \.title).map(\.item)
        XCTAssertEqual(allResults.count, 5)
    }
    
    // MARK: - 15. Functional Bucketing & Order-Preserving Deduplication
    
    func testFunctionalBucketingAndUniqued() {
        struct PhotoRef {
            let id: String
            let year: Int
        }
        
        let photos = [
            PhotoRef(id: "p1", year: 2024),
            PhotoRef(id: "p2", year: 2023),
            PhotoRef(id: "p3", year: 2024),
            PhotoRef(id: "p4", year: 2022),
            PhotoRef(id: "p5", year: 2023)
        ]
        
        // Group by year via AlgorithmKit
        let grouped = photos.grouped(by: \.year)
        XCTAssertEqual(grouped[2024]?.map(\.id), ["p1", "p3"])
        XCTAssertEqual(grouped[2023]?.map(\.id), ["p2", "p5"])
        XCTAssertEqual(grouped[2022]?.map(\.id), ["p4"])
        
        // Order-preserving deduplication via uniqued()
        let duplicateIDs = ["p1", "p2", "p1", "p3", "p2", "p4", "p1"]
        let uniqueIDs = duplicateIDs.uniqued()
        XCTAssertEqual(uniqueIDs, ["p1", "p2", "p3", "p4"])
    }
}


