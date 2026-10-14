import SwiftUI

#if canImport(Photos)
import Photos
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Thread-safe cached thumbnail item holding rendered image and media metadata.
private final class CachedThumbnailItem {
    let image: PlatformImage
    let isVideo: Bool
    let isLivePhoto: Bool
    let durationString: String?
    
    init(image: PlatformImage, isVideo: Bool, isLivePhoto: Bool, durationString: String?) {
        self.image = image
        self.isVideo = isVideo
        self.isLivePhoto = isLivePhoto
        self.durationString = durationString
    }
}

/// Thread-safe in-memory cache for rendered thumbnails and badges.
private final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, CachedThumbnailItem>()
    
    private init() {
        cache.countLimit = 600
        cache.totalCostLimit = 64 * 1024 * 1024 // 64 MB
    }
    
    func item(for id: String) -> CachedThumbnailItem? {
        cache.object(forKey: id as NSString)
    }
    
    func insert(_ item: CachedThumbnailItem, for id: String) {
        cache.setObject(item, forKey: id as NSString)
    }
}

/// High-performance PhotoKit thumbnail view with in-memory caching and strict 1:1 clipping.
/// Executes all PhotoKit fetches and property accesses off the main thread to prevent main queue stalls.
public struct AssetThumbnailView: View {
    public let assetID: String
    public var targetSize: CGSize
    public var contentMode: ContentMode
    
    @State private var platformImage: PlatformImage?
    @State private var isVideo: Bool = false
    @State private var isLivePhoto: Bool = false
    @State private var durationString: String?
    @State private var requestID: PHImageRequestID?
    
    public init(
        assetID: String,
        targetSize: CGSize = CGSize(width: 250, height: 250),
        contentMode: ContentMode = .fill
    ) {
        self.assetID = assetID
        self.targetSize = targetSize
        self.contentMode = contentMode
    }
    
    public var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                ZStack {
                    if let image = platformImage {
                        PlatformImageView(image: image, contentMode: contentMode)
                    } else {
                        Rectangle()
                            .fill(Color.gray.opacity(0.2))
                            .overlay(
                                ProgressView()
                                    .scaleEffect(0.6)
                            )
                    }
                    
                    // Live Photo Badge
                    if isLivePhoto {
                        VStack {
                            HStack {
                                Image(systemName: "livephoto")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(4)
                                    .background(Color.black.opacity(0.55))
                                    .clipShape(Circle())
                                    .padding(4)
                                Spacer()
                            }
                            Spacer()
                        }
                    }
                    
                    // Video Duration Badge
                    if isVideo, let duration = durationString {
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Text(duration)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(Color.black.opacity(0.65))
                                    .cornerRadius(4)
                                    .padding(4)
                            }
                        }
                    }
                }
            )
            .clipped()
            .contentShape(Rectangle())
            .onAppear {
                loadThumbnail()
            }
            .onDisappear {
                cancelRequest()
            }
    }
    
    private func loadThumbnail() {
        #if canImport(Photos)
        // 1. Instant cache hit on MainActor (< 0.001ms)
        if let cached = ThumbnailCache.shared.item(for: assetID) {
            self.platformImage = cached.image
            self.isVideo = cached.isVideo
            self.isLivePhoto = cached.isLivePhoto
            self.durationString = cached.durationString
            return
        }
        
        #if canImport(UIKit)
        let scale = UIScreen.main.scale
        #else
        let scale: CGFloat = 2.0
        #endif
        
        let id = self.assetID
        let target = self.targetSize
        
        // 2. Offload PHAsset fetch and requestImage completely to background queue.
        // Eliminates "Missing prefetched properties for PHAssetOriginalMetadataProperties on main queue" warnings.
        DispatchQueue.global(qos: .userInteractive).async {
            autoreleasepool {
                let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil)
                guard let asset = fetchResult.firstObject else { return }
                
                let isVid = asset.mediaType == .video
                let isLive = asset.mediaSubtypes.contains(.photoLive)
                var durStr: String? = nil
                if isVid {
                    let dur = Int(asset.duration)
                    durStr = String(format: "%d:%02d", dur / 60, dur % 60)
                }
                
                let options = PHImageRequestOptions()
                options.isNetworkAccessAllowed = false
                options.resizeMode = .fast
                options.deliveryMode = .opportunistic
                options.isSynchronous = false
                
                let pixelSize = CGSize(width: target.width * scale, height: target.height * scale)
                
                let reqID = PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: pixelSize,
                    contentMode: .aspectFill,
                    options: options
                ) { image, _ in
                    if let img = image {
                        let item = CachedThumbnailItem(
                            image: img,
                            isVideo: isVid,
                            isLivePhoto: isLive,
                            durationString: durStr
                        )
                        ThumbnailCache.shared.insert(item, for: id)
                        
                        DispatchQueue.main.async {
                            self.platformImage = img
                            self.isVideo = isVid
                            self.isLivePhoto = isLive
                            self.durationString = durStr
                        }
                    }
                }
                
                DispatchQueue.main.async {
                    self.requestID = reqID
                }
            }
        }
        #endif
    }
    
    private func cancelRequest() {
        #if canImport(Photos)
        if let req = requestID {
            PHImageManager.default().cancelImageRequest(req)
            self.requestID = nil
        }
        #endif
    }
}
