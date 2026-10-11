import XCTest
@testable import PhotoManagerKit

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
}
