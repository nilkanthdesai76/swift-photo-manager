import SwiftUI

#if canImport(Photos)
import Photos
#endif

/// The unified Photo Library Manager dashboard containing storage stats, segments, dedupe progress cards, and smart albums.
/// Uses targeted fine-grained observation via the Observation framework for fluid 120 FPS interaction.
@MainActor
public struct PhotoManagerDashboardView: View {
    @Bindable public var coordinator: PhotoManagerCoordinator
    
    // Sheet Navigation State
    @State private var activeReviewTitle: String?
    @State private var activeReviewGroups: [DedupeGroup] = []
    @State private var activeAlbumDetail: SmartAlbumItem?
    
    public init() {
        self.coordinator = PhotoManagerCoordinator()
    }
    
    public init(coordinator: PhotoManagerCoordinator) {
        self.coordinator = coordinator
    }
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 1. Top Storage Overview Card (Targeted: observes storageOverview only)
                    StorageHeaderCardSection(coordinator: coordinator)
                    
                    // 1b. Phase 0 Size Index Progress (Targeted: observes sizeScanProgress & sizeScanResolvedBytes only)
                    SizeScanProgressSection(coordinator: coordinator)
                    
                    // 2. Segmented Picker: [Photos | Videos]
                    Picker("Category", selection: $coordinator.selectedSegment) {
                        Text("Photos").tag(0)
                        Text("Videos").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 4)
                    
                    // 3. Segment Body
                    if coordinator.selectedSegment == 0 {
                        photosSegmentContent
                    } else {
                        videosSegmentContent
                    }
                }
                .padding(16)
            }
            .background(Color.platformGroupedBackground)
            .navigationTitle("Library Manager")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    PipelineStatusToolbarItem(coordinator: coordinator)
                }
            }
            .task {
                await coordinator.start()
            }
            .sheet(item: Binding<DedupeReviewSheetItem?>(
                get: {
                    guard let title = activeReviewTitle else { return nil }
                    return DedupeReviewSheetItem(title: title, groups: activeReviewGroups)
                },
                set: { item in
                    if item == nil {
                        activeReviewTitle = nil
                        activeReviewGroups = []
                    }
                }
            )) { sheetItem in
                GroupReviewView(
                    title: sheetItem.title,
                    groups: $activeReviewGroups,
                    onDelete: { ids in
                        await coordinator.deleteAssets(withIDs: ids)
                    }
                )
            }
            .sheet(item: $activeAlbumDetail) { album in
                AlbumDetailListView(
                    item: album,
                    sizeRecords: coordinator.sizeRecords,
                    onDelete: { ids in
                        await coordinator.deleteAssets(withIDs: ids)
                    }
                )
            }
        }
    }
    
    // MARK: - Photos Segment
    
    private var photosSegmentContent: some View {
        VStack(spacing: 14) {
            // Dedupe Cards (Targeted: observes photoDuplicates & photoDedupeProgress only)
            PhotosSegmentDedupeCards(
                coordinator: coordinator,
                onReviewDuplicates: { groups in
                    activeReviewTitle = "Duplicate Photos"
                    activeReviewGroups = groups
                },
                onReviewSimilars: { groups in
                    activeReviewTitle = "Similar Photos"
                    activeReviewGroups = groups
                }
            )
            
            // System Smart Albums (Targeted: observes photoSmartAlbums only)
            PhotoSmartAlbumsSection(coordinator: coordinator) { album in
                activeAlbumDetail = album
            }
            
            // Cleanup Suggestions (Targeted: observes largePhotosAlbum, oldPhotosAlbum & blurryPhotosAlbum only)
            PhotoCleanupSuggestionsSection(coordinator: coordinator) { album in
                activeAlbumDetail = album
            }
        }
    }
    
    // MARK: - Videos Segment
    
    private var videosSegmentContent: some View {
        VStack(spacing: 14) {
            // Dedupe Cards (Targeted: observes videoDuplicates & videoDedupeProgress only)
            VideosSegmentDedupeCards(
                coordinator: coordinator,
                onReviewDuplicates: { groups in
                    activeReviewTitle = "Duplicate Videos"
                    activeReviewGroups = groups
                },
                onReviewSimilars: { groups in
                    activeReviewTitle = "Similar Videos"
                    activeReviewGroups = groups
                }
            )
            
            // Video System Groups (Targeted: observes videoSmartAlbums only)
            VideoSmartAlbumsSection(coordinator: coordinator) { album in
                activeAlbumDetail = album
            }
            
            // Large Videos (Targeted: observes largeVideosAlbum only)
            LargeVideosSection(coordinator: coordinator) { album in
                activeAlbumDetail = album
            }
        }
    }
}

// MARK: - Targeted Subviews (Fine-Grained Observation)

/// Target 1: Storage header card re-evaluates ONLY when storageOverview changes.
private struct StorageHeaderCardSection: View {
    var coordinator: PhotoManagerCoordinator
    
    var body: some View {
        StorageHeaderCardView(overview: coordinator.storageOverview)
    }
}

/// Target 1b: Size scan card re-evaluates ONLY when sizeScanProgress or sizeScanResolvedBytes changes.
private struct SizeScanProgressSection: View {
    var coordinator: PhotoManagerCoordinator
    
    var body: some View {
        if coordinator.sizeScanProgress.isScanning {
            SizeScanProgressCardView(
                progress: coordinator.sizeScanProgress,
                resolvedBytes: coordinator.sizeScanResolvedBytes
            )
        }
    }
}

/// Target 2: Photo dedupe cards re-evaluate ONLY when photoDuplicates, photoSimilars, or photoDedupeProgress changes.
private struct PhotosSegmentDedupeCards: View {
    var coordinator: PhotoManagerCoordinator
    let onReviewDuplicates: ([DedupeGroup]) -> Void
    let onReviewSimilars: ([DedupeGroup]) -> Void
    
    var body: some View {
        VStack(spacing: 14) {
            sectionHeader(title: "Duplicates & Similar", count: coordinator.photoDuplicates.count + coordinator.photoSimilars.count)
            
            // 1. Duplicate Photos Card
            DedupeProgressCardView(
                title: "Duplicate Photos",
                subtitle: "Exact duplicate photos",
                sfSymbol: "doc.on.doc.fill",
                accentColor: .blue,
                groups: coordinator.photoDuplicates,
                progress: coordinator.photoDedupeProgress
            ) {
                onReviewDuplicates(coordinator.photoDuplicates)
            }
            
            // 2. Similar Photos Card
            DedupeProgressCardView(
                title: "Similar Photos",
                subtitle: "Burst shots & consecutive captures",
                sfSymbol: "sparkles.rectangle.stack.fill",
                accentColor: .purple,
                groups: coordinator.photoSimilars,
                progress: coordinator.photoDedupeProgress
            ) {
                onReviewSimilars(coordinator.photoSimilars)
            }
        }
    }
}

/// Target 3: Photo smart albums re-evaluate ONLY when photoSmartAlbums changes.
private struct PhotoSmartAlbumsSection: View {
    var coordinator: PhotoManagerCoordinator
    let onSelectAlbum: (SmartAlbumItem) -> Void
    
    var body: some View {
        if !coordinator.photoSmartAlbums.isEmpty {
            VStack(spacing: 8) {
                sectionHeader(title: "System Albums", count: coordinator.photoSmartAlbums.count)
                ForEach(coordinator.photoSmartAlbums) { album in
                    SmartAlbumCardView(item: album) {
                        onSelectAlbum(album)
                    }
                }
            }
        }
    }
}

/// Target 4: Cleanup suggestions re-evaluate ONLY when largePhotosAlbum, oldPhotosAlbum, or blurryPhotosAlbum changes.
private struct PhotoCleanupSuggestionsSection: View {
    var coordinator: PhotoManagerCoordinator
    let onSelectAlbum: (SmartAlbumItem) -> Void
    
    var body: some View {
        if coordinator.largePhotosAlbum != nil || coordinator.oldPhotosAlbum != nil || coordinator.blurryPhotosAlbum != nil {
            VStack(spacing: 8) {
                let itemCount = [coordinator.largePhotosAlbum, coordinator.oldPhotosAlbum, coordinator.blurryPhotosAlbum].compactMap { $0 }.count
                sectionHeader(title: "Cleanup Suggestions", count: itemCount)
                if let large = coordinator.largePhotosAlbum {
                    SmartAlbumCardView(item: large) {
                        onSelectAlbum(large)
                    }
                }
                if let old = coordinator.oldPhotosAlbum {
                    SmartAlbumCardView(item: old) {
                        onSelectAlbum(old)
                    }
                }
                if let blurry = coordinator.blurryPhotosAlbum {
                    SmartAlbumCardView(item: blurry) {
                        onSelectAlbum(blurry)
                    }
                }
            }
        }
    }
}

/// Target 5: Video dedupe cards re-evaluate ONLY when videoDuplicates, videoSimilars, or videoDedupeProgress changes.
private struct VideosSegmentDedupeCards: View {
    var coordinator: PhotoManagerCoordinator
    let onReviewDuplicates: ([DedupeGroup]) -> Void
    let onReviewSimilars: ([DedupeGroup]) -> Void
    
    var body: some View {
        VStack(spacing: 14) {
            sectionHeader(title: "Video Deduplication", count: coordinator.videoDuplicates.count + coordinator.videoSimilars.count)
            
            // 1. Duplicate Videos Card
            DedupeProgressCardView(
                title: "Duplicate Videos",
                subtitle: "Exact duplicate recordings",
                sfSymbol: "video.badge.waveform.fill",
                accentColor: .orange,
                groups: coordinator.videoDuplicates,
                progress: coordinator.videoDedupeProgress
            ) {
                onReviewDuplicates(coordinator.videoDuplicates)
            }
            
            // 2. Similar Videos Card
            DedupeProgressCardView(
                title: "Similar Videos",
                subtitle: "Similar duration & motion angles",
                sfSymbol: "film.stack.fill",
                accentColor: .pink,
                groups: coordinator.videoSimilars,
                progress: coordinator.videoDedupeProgress
            ) {
                onReviewSimilars(coordinator.videoSimilars)
            }
        }
    }
}

/// Target 6: Video system groups re-evaluate ONLY when videoSmartAlbums changes.
private struct VideoSmartAlbumsSection: View {
    var coordinator: PhotoManagerCoordinator
    let onSelectAlbum: (SmartAlbumItem) -> Void
    
    var body: some View {
        if !coordinator.videoSmartAlbums.isEmpty {
            VStack(spacing: 8) {
                sectionHeader(title: "Video Categories", count: coordinator.videoSmartAlbums.count)
                ForEach(coordinator.videoSmartAlbums) { album in
                    SmartAlbumCardView(item: album) {
                        onSelectAlbum(album)
                    }
                }
            }
        }
    }
}

/// Target 7: Large videos re-evaluate ONLY when largeVideosAlbum changes.
private struct LargeVideosSection: View {
    var coordinator: PhotoManagerCoordinator
    let onSelectAlbum: (SmartAlbumItem) -> Void
    
    var body: some View {
        if let largeVideos = coordinator.largeVideosAlbum {
            VStack(spacing: 8) {
                sectionHeader(title: "Space Hogs", count: 1)
                SmartAlbumCardView(item: largeVideos) {
                    onSelectAlbum(largeVideos)
                }
            }
        }
    }
}

/// Target 8: Toolbar indicator re-evaluates ONLY when isIndexing or currentStep changes.
private struct PipelineStatusToolbarItem: View {
    var coordinator: PhotoManagerCoordinator
    
    var body: some View {
        if coordinator.isIndexing {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(coordinator.currentStep.rawValue)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Helpers

private func sectionHeader(title: String, count: Int) -> some View {
    HStack {
        Text(title)
            .font(.footnote)
            .fontWeight(.bold)
            .foregroundColor(.secondary)
            .textCase(.uppercase)
        Spacer()
    }
    .padding(.horizontal, 4)
    .padding(.top, 6)
}

private struct DedupeReviewSheetItem: Identifiable {
    let id = UUID()
    let title: String
    let groups: [DedupeGroup]
}
