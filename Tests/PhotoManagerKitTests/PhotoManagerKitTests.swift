import XCTest
@testable import PhotoManagerKit
import PhotoKitManager

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
}

