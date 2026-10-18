import SwiftUI
import AlgorithmKit

#if canImport(Photos)
import Photos
#endif

/// Second tab view presenting AI-categorized photo albums, user albums, and collapsible chronological Year-Month timeline.
public struct GalleryExplorerView: View {
    public var coordinator: PhotoManagerCoordinator
    
    @State private var expandedYears: Set<Int> = []
    @State private var selectedSmartAlbum: SmartAlbumItem?
    @State private var searchText: String = ""
    
    public init(coordinator: PhotoManagerCoordinator) {
        self.coordinator = coordinator
    }
    
    private let aiColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    
    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    
    private var displayedAICategories: [AICategoryItem] {
        if isSearching {
            return coordinator.aiCategories.fuzzySearch(searchText, on: \.title).map(\.item)
        } else {
            return coordinator.aiCategories
        }
    }
    
    private var displayedUserAlbums: [UserAlbumItem] {
        if isSearching {
            return coordinator.userAlbums.fuzzySearch(searchText, on: \.title).map(\.item)
        } else {
            return coordinator.userAlbums
        }
    }
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    if isSearching && displayedAICategories.isEmpty && displayedUserAlbums.isEmpty {
                        searchEmptyState
                    } else {
                        // 1. AI Categorized Albums
                        if !displayedAICategories.isEmpty {
                            aiCategoriesSection
                        }
                        
                        // 2. User Albums (if any)
                        if !displayedUserAlbums.isEmpty {
                            userAlbumsSection
                        }
                        
                        // 3. Chronological Timeline (Collapsible Years & Months)
                        if !isSearching {
                            timelineSection
                        }
                    }
                }
                .padding(16)
            }
            .background(Color.platformGroupedBackground)
            .navigationTitle("AI & Timeline")
            .searchable(text: $searchText, prompt: "Search categories & albums…")
            .sheet(item: $selectedSmartAlbum) { album in
                AlbumDetailListView(
                    item: album,
                    sizeRecords: coordinator.sizeRecords,
                    onDelete: { ids in
                        await coordinator.deleteAssets(withIDs: ids)
                    }
                )
            }
            .onAppear {
                // Expand most recent years by default
                if expandedYears.isEmpty, let firstYear = coordinator.yearSections.first?.year {
                    expandedYears.insert(firstYear)
                }
            }
        }
    }
    
    private var searchEmptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("No Results for \"\(searchText)\"")
                .font(.headline)
            Text("Try searching for categories like Nature, Animals, Vehicles, Food, or user albums.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }
    
    // MARK: - 1. AI Categorized Albums Section
    
    private var aiCategoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI Categorized", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Text("\(displayedAICategories.count) Categories")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            LazyVGrid(columns: aiColumns, spacing: 12) {
                ForEach(displayedAICategories) { cat in
                    aiCategoryCard(cat)
                }
            }
        }
    }
    
    private func aiCategoryCard(_ cat: AICategoryItem) -> some View {
        Button {
            selectedSmartAlbum = SmartAlbumItem(
                id: cat.id,
                title: cat.title,
                count: cat.count,
                totalBytes: cat.totalBytes,
                sfSymbol: cat.sfSymbol,
                accentColorName: cat.colorName,
                assetIDs: cat.assetIDs,
                newestAssetID: cat.coverAssetID
            )
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                // 1:1 Album Cover Preview
                ZStack(alignment: .topTrailing) {
                    if let coverID = cat.coverAssetID {
                        AssetThumbnailView(assetID: coverID)
                            .aspectRatio(1, contentMode: .fit)
                            .clipped()
                    } else {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [colorFor(cat.colorName).opacity(0.35), colorFor(cat.colorName).opacity(0.12)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .aspectRatio(1, contentMode: .fit)
                            .overlay(
                                Image(systemName: cat.sfSymbol)
                                    .font(.system(size: 36))
                                    .foregroundColor(colorFor(cat.colorName))
                            )
                    }
                    
                    // Floating Category SF Symbol Badge
                    Image(systemName: cat.sfSymbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(colorFor(cat.colorName))
                        .padding(6)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                        .shadow(color: Color.black.opacity(0.12), radius: 3, x: 0, y: 1)
                        .padding(6)
                }
                .aspectRatio(1, contentMode: .fit)
                .cornerRadius(12)
                .clipped()
                
                // Full wrap-safe album title & stats
                VStack(alignment: .leading, spacing: 2) {
                    Text(cat.title)
                        .font(.subheadline)
                        .fontWeight(.bold)
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    Text("\(cat.count) items • \(cat.formattedSize)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
            }
            .padding(8)
            .background(Color.platformSecondaryBackground)
            .cornerRadius(16)
            .clipped()
        }
        .buttonStyle(.plain)
    }

    
    // MARK: - 2. User Albums Section
    
    private var userAlbumsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("My Albums", systemImage: "rectangle.stack.fill")
                    .font(.headline)
                Spacer()
                Text("\(displayedUserAlbums.count) Albums")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(displayedUserAlbums) { album in
                        Button {
                            selectedSmartAlbum = SmartAlbumItem(
                                id: album.id,
                                title: album.title,
                                count: album.count,
                                totalBytes: album.totalBytes,
                                sfSymbol: "rectangle.stack",
                                accentColorName: "blue",
                                assetIDs: album.assetIDs,
                                newestAssetID: album.coverAssetID
                            )
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                if let cover = album.coverAssetID {
                                    AssetThumbnailView(assetID: cover)
                                        .frame(width: 120, height: 120)
                                        .cornerRadius(12)
                                } else {
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(Color.gray.opacity(0.2))
                                        .frame(width: 120, height: 120)
                                }
                                
                                Text(album.title)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                
                                Text("\(album.count) items • \(album.formattedSize)")
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                            }
                            .frame(width: 120)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
    
    // MARK: - 3. Collapsible Timeline Section
    
    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Photo Timeline", systemImage: "calendar")
                    .font(.headline)
                Spacer()
                Text("\(coordinator.yearSections.count) Years")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            VStack(spacing: 12) {
                ForEach(coordinator.yearSections) { yearSection in
                    yearDisclosureCard(yearSection)
                }
            }
        }
    }
    
    private func yearDisclosureCard(_ yearSection: YearSection) -> some View {
        let isExpanded = expandedYears.contains(yearSection.year)
        
        return VStack(spacing: 0) {
            // Header Toggle
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    if isExpanded {
                        expandedYears.remove(yearSection.year)
                    } else {
                        expandedYears.insert(yearSection.year)
                    }
                }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(String(yearSection.year))
                            .font(.title3)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        Text("\(yearSection.totalCount) Photos • \(yearSection.formattedSize)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up.circle.fill" : "chevron.down.circle")
                        .font(.title3)
                        .foregroundColor(isExpanded ? .blue : .secondary)
                }
                .padding(14)
                .background(Color.platformSecondaryBackground)
            }
            .buttonStyle(.plain)
            
            // Collapsible Months
            if isExpanded {
                Divider()
                VStack(spacing: 0) {
                    ForEach(yearSection.months) { month in
                        NavigationLink {
                            MonthPhotoListView(
                                month: month,
                                sizeRecords: coordinator.sizeRecords
                            ) { ids in
                                await coordinator.deleteAssets(withIDs: ids)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                if let cover = month.coverAssetID {
                                    AssetThumbnailView(assetID: cover)
                                        .frame(width: 48, height: 48)
                                        .cornerRadius(8)
                                } else {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.gray.opacity(0.2))
                                        .frame(width: 48, height: 48)
                                }
                                
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(month.monthName)
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.primary)
                                    
                                    Text("\(month.count) Photos • \(month.formattedSize)")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(Color.platformSecondaryBackground)
                        }
                        .buttonStyle(.plain)
                        
                        if month.id != yearSection.months.last?.id {
                            Divider()
                                .padding(.leading, 74)
                        }
                    }
                }
            }
        }
        .cornerRadius(16)
    }
    
    private func colorFor(_ name: String) -> Color {
        switch name {
        case "green": return .green
        case "blue": return .blue
        case "orange": return .orange
        case "pink": return .pink
        case "indigo": return .indigo
        case "cyan": return .cyan
        case "purple": return .purple
        case "yellow": return .yellow
        default: return .blue
        }
    }
}
