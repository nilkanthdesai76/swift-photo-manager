import SwiftUI

#if canImport(Photos)
import Photos
#endif

/// The unified Photo Library Manager dashboard containing storage stats, segments, dedupe progress cards, and smart albums.
@MainActor
public struct PhotoManagerDashboardView: View {
    @StateObject private var coordinator: PhotoManagerCoordinator
    
    // Sheet Navigation State
    @State private var activeReviewTitle: String?
    @State private var activeReviewGroups: [DedupeGroup] = []
    @State private var activeReviewKind: DedupeMatchKind?
    @State private var activeAlbumDetail: SmartAlbumItem?
    
    public init() {
        self._coordinator = StateObject(wrappedValue: PhotoManagerCoordinator())
    }
    
    public init(coordinator: PhotoManagerCoordinator) {
        self._coordinator = StateObject(wrappedValue: coordinator)
    }
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // 1. Top Storage Card
                    StorageHeaderCardView(overview: coordinator.storageOverview)
                    
                    // 2. Segmented Picker: [Photos | Videos]
                    Picker("Category", selection: $coordinator.selectedSegment) {
                        Text("Photos (\(coordinator.storageOverview.photosCount + coordinator.storageOverview.livePhotosCount))").tag(0)
                        Text("Videos (\(coordinator.storageOverview.videosCount))").tag(1)
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
                    if coordinator.isIndexing {
                        ProgressView()
                            .controlSize(.small)
                    }
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
            // Dedupe Section Header
            sectionHeader(title: "Duplicates & Similar", count: coordinator.photoDuplicates.count + coordinator.photoSimilars.count)
            
            // 1. Duplicate Photos Card (Top)
            DedupeProgressCardView(
                title: "Duplicate Photos",
                subtitle: "Exact duplicate photos",
                sfSymbol: "doc.on.doc.fill",
                accentColor: .blue,
                groups: coordinator.photoDuplicates,
                progress: coordinator.photoDedupeProgress
            ) {
                activeReviewTitle = "Duplicate Photos"
                activeReviewGroups = coordinator.photoDuplicates
                activeReviewKind = .exactDuplicate
            }
            
            // 2. Similar Photos Card (Top)
            DedupeProgressCardView(
                title: "Similar Photos",
                subtitle: "Burst shots & consecutive captures",
                sfSymbol: "sparkles.rectangle.stack.fill",
                accentColor: .purple,
                groups: coordinator.photoSimilars,
                progress: coordinator.photoDedupeProgress
            ) {
                activeReviewTitle = "Similar Photos"
                activeReviewGroups = coordinator.photoSimilars
                activeReviewKind = .similar
            }
            
            // System Smart Albums
            if !coordinator.photoSmartAlbums.isEmpty {
                sectionHeader(title: "System Albums", count: coordinator.photoSmartAlbums.count)
                
                VStack(spacing: 8) {
                    ForEach(coordinator.photoSmartAlbums) { album in
                        SmartAlbumCardView(item: album) {
                            activeAlbumDetail = album
                        }
                    }
                }
            }
            
            // Filter Cards (Large Photos & Old Photos)
            if coordinator.largePhotosAlbum != nil || coordinator.oldPhotosAlbum != nil {
                sectionHeader(title: "Cleanup Suggestions", count: 2)
                
                VStack(spacing: 8) {
                    if let large = coordinator.largePhotosAlbum {
                        SmartAlbumCardView(item: large) {
                            activeAlbumDetail = large
                        }
                    }
                    
                    if let old = coordinator.oldPhotosAlbum {
                        SmartAlbumCardView(item: old) {
                            activeAlbumDetail = old
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Videos Segment
    
    private var videosSegmentContent: some View {
        VStack(spacing: 14) {
            // Dedupe Section Header
            sectionHeader(title: "Video Deduplication", count: coordinator.videoDuplicates.count + coordinator.videoSimilars.count)
            
            // 1. Duplicate Videos Card (Top)
            DedupeProgressCardView(
                title: "Duplicate Videos",
                subtitle: "Exact duplicate recordings",
                sfSymbol: "video.badge.waveform.fill",
                accentColor: .orange,
                groups: coordinator.videoDuplicates,
                progress: coordinator.videoDedupeProgress
            ) {
                activeReviewTitle = "Duplicate Videos"
                activeReviewGroups = coordinator.videoDuplicates
                activeReviewKind = .exactDuplicate
            }
            
            // 2. Similar Videos Card (Top)
            DedupeProgressCardView(
                title: "Similar Videos",
                subtitle: "Similar duration & motion angles",
                sfSymbol: "film.stack.fill",
                accentColor: .pink,
                groups: coordinator.videoSimilars,
                progress: coordinator.videoDedupeProgress
            ) {
                activeReviewTitle = "Similar Videos"
                activeReviewGroups = coordinator.videoSimilars
                activeReviewKind = .similar
            }
            
            // Video System Groups
            if !coordinator.videoSmartAlbums.isEmpty {
                sectionHeader(title: "Video Categories", count: coordinator.videoSmartAlbums.count)
                
                VStack(spacing: 8) {
                    ForEach(coordinator.videoSmartAlbums) { album in
                        SmartAlbumCardView(item: album) {
                            activeAlbumDetail = album
                        }
                    }
                }
            }
            
            // Filter Cards (Large Videos)
            if let largeVideos = coordinator.largeVideosAlbum {
                sectionHeader(title: "Space Hogs", count: 1)
                
                SmartAlbumCardView(item: largeVideos) {
                    activeAlbumDetail = largeVideos
                }
            }
        }
    }
    
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
}

private struct DedupeReviewSheetItem: Identifiable {
    let id = UUID()
    let title: String
    let groups: [DedupeGroup]
}
