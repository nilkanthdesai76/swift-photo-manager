import SwiftUI

#if canImport(Photos)
import Photos
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Thread-safe in-memory cache for rendered thumbnails.
private final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, PlatformImage>()
    
    private init() {
        cache.countLimit = 600
        cache.totalCostLimit = 64 * 1024 * 1024 // 64 MB
    }
    
    func image(for id: String) -> PlatformImage? {
        cache.object(forKey: id as NSString)
    }
    
    func insert(_ image: PlatformImage, for id: String) {
        cache.setObject(image, forKey: id as NSString)
    }
}

/// High-performance PhotoKit thumbnail view with in-memory caching and strict 1:1 clipping.
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
        if let cached = ThumbnailCache.shared.image(for: assetID) {
            self.platformImage = cached
            return
        }
        
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = fetchResult.firstObject else { return }
        
        self.isVideo = asset.mediaType == .video
        self.isLivePhoto = asset.mediaSubtypes.contains(.photoLive)
        if self.isVideo {
            let dur = Int(asset.duration)
            self.durationString = String(format: "%d:%02d", dur / 60, dur % 60)
        }
        
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.resizeMode = .fast
        options.deliveryMode = .opportunistic
        options.isSynchronous = false
        
        #if canImport(UIKit)
        let scale = UIScreen.main.scale
        #else
        let scale: CGFloat = 2.0
        #endif
        let pixelSize = CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
        
        self.requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: pixelSize,
            contentMode: .aspectFill,
            options: options
        ) { image, info in
            if let img = image {
                ThumbnailCache.shared.insert(img, for: assetID)
                self.platformImage = img
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
