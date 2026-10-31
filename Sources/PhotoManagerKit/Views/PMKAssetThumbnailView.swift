import SwiftUI

#if canImport(Photos)
import Photos
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Thread-safe cached media badges for a thumbnail cell (video / Live Photo / duration).
final class CachedThumbnailBadges {
    let isVideo: Bool
    let isLivePhoto: Bool
    let durationString: String?

    init(isVideo: Bool, isLivePhoto: Bool, durationString: String?) {
        self.isVideo = isVideo
        self.isLivePhoto = isLivePhoto
        self.durationString = durationString
    }
}

/// Thread-safe in-memory cache of per-asset media badges.
///
/// Images stay in `AssetThumbnailImageLoader`, keyed by request size and content
/// revision; this cache answers only "which badges does this asset render", so it
/// is keyed by asset ID alone.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, CachedThumbnailBadges>()

    private init() {
        cache.countLimit = 600
        cache.totalCostLimit = 64 * 1024 * 1024 // 64 MB
    }

    func item(for id: String) -> CachedThumbnailBadges? {
        cache.object(forKey: id as NSString)
    }

    func insert(_ item: CachedThumbnailBadges, for id: String) {
        cache.setObject(item, forKey: id as NSString)
    }

    /// Purges entries so changed/deleted assets stop serving stale badges.
    func remove(ids: Set<String>) {
        for id in ids {
            cache.removeObject(forKey: id as NSString)
        }
    }
}

/// High-performance PhotoKit thumbnail view with in-memory caching and strict 1:1 clipping.
/// Loads through the shared thumbnail machinery (`PhotoKitImageRequester` +
/// `AssetThumbnailImageLoader`) so grid prefetch windows warm exactly what cells request.
public struct PMKAssetThumbnailView: View {
    public let assetID: String
    public var targetSize: CGSize
    public var contentMode: ContentMode

    /// Canonical grid request size. Grids with a `ThumbnailGridPrefetchState` warm
    /// exactly this size so scrolled-in cells are served from the manager cache.
    public static let gridRequestSize = CGSize(width: 250, height: 250)

    /// Requests at or below this size use the grid warm profile (`.opportunistic`
    /// + network access) that `ThumbnailGridPrefetchState` pre-warms. The fast
    /// frame paints first, then a high-quality delivery replaces it — the old
    /// `.fastFormat` profile capped cells at the tiny embedded thumb, which read
    /// as blurry on 3x grids. Larger covers keep the same opportunistic
    /// local-only profile so they are never capped at grid quality.
    private static let gridProfileMaxSide: CGFloat = 250

    @Environment(PhotoManagerCoordinator.self) private var photoCoordinator

    @State private var platformImage: PlatformImage?
    @State private var isVideo: Bool = false
    @State private var isLivePhoto: Bool = false
    @State private var durationString: String?
    @State private var loadTask: Task<Void, Never>?
    @State private var loadGeneration = 0

    public init(
        assetID: String,
        targetSize: CGSize = PMKAssetThumbnailView.gridRequestSize,
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
            .onChange(of: photoCoordinator.assetContentRevision) {
                // A sync observed content edits and purged those entries from
                // the caches; re-request so edited assets show fresh renditions.
                // Unedited cells re-hit the cache instantly.
                loadThumbnail()
            }
            .onDisappear {
                cancelLoad()
            }
    }

    private func loadThumbnail() {
        #if canImport(Photos) && canImport(UIKit)
        let id = assetID
        // Point size, not pixels — PhotoKit multiplies by the screen scale
        // internally, and the prefetch windows warm this same value.
        let requestSize = targetSize
        let phContentMode: PHImageContentMode = contentMode == .fill ? .aspectFill : .aspectFit
        let useGridProfile = max(requestSize.width, requestSize.height) <= Self.gridProfileMaxSide

        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration

        loadTask = Task { @MainActor in
            await loadBadges(assetID: id, generation: generation)
            guard generation == loadGeneration, !Task.isCancelled else { return }

            await AssetThumbnailImageLoader.shared.loadThumbnail(
                for: id,
                targetSize: requestSize,
                contentMode: phContentMode,
                allowsNetworkAccess: useGridProfile,
                deliveryMode: .opportunistic,
                releaseGateAfterFirstFrame: useGridProfile
            ) { image in
                Task { @MainActor in
                    guard generation == loadGeneration else { return }
                    self.platformImage = image
                }
            }
        }
        #endif
    }

    /// Badge metadata comes from the PHAsset, resolved through the shared
    /// prefetch-warmed asset cache; property reads stay on the metadata queue.
    @MainActor
    private func loadBadges(assetID: String, generation: Int) async {
        if let cached = ThumbnailCache.shared.item(for: assetID) {
            guard generation == loadGeneration else { return }
            isVideo = cached.isVideo
            isLivePhoto = cached.isLivePhoto
            durationString = cached.durationString
            return
        }
        guard let asset = await PhotoKitImageRequester.fetchAsset(identifier: assetID) else { return }
        let badges = await PhotoKitImageRequester.onPhotoKitQueue { () -> CachedThumbnailBadges in
            let isVideo = asset.mediaType == .video
            let isLive = asset.mediaSubtypes.contains(.photoLive)
            let duration: String?
            if isVideo {
                let seconds = Int(asset.duration)
                duration = String(format: "%d:%02d", seconds / 60, seconds % 60)
            } else {
                duration = nil
            }
            return CachedThumbnailBadges(isVideo: isVideo, isLivePhoto: isLive, durationString: duration)
        }
        ThumbnailCache.shared.insert(badges, for: assetID)
        guard generation == loadGeneration else { return }
        isVideo = badges.isVideo
        isLivePhoto = badges.isLivePhoto
        durationString = badges.durationString
    }

    private func cancelLoad() {
        loadTask?.cancel()
        loadTask = nil
    }
}
