import SwiftUI

#if canImport(Photos)
import Photos
#endif

/// Second tab view presenting AI-categorized photo albums, user albums, and collapsible chronological Year-Month timeline.
public struct GalleryExplorerView: View {
    @ObservedObject public var coordinator: PhotoManagerCoordinator
    
    @State private var expandedYears: Set<Int> = []
    @State private var selectedSmartAlbum: SmartAlbumItem?
    
    public init(coordinator: PhotoManagerCoordinator) {
        self.coordinator = coordinator
    }
    
    private let aiColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // 1. AI Categorized Albums
                    aiCategoriesSection
                    
                    // 2. User Albums (if any)
                    if !coordinator.userAlbums.isEmpty {
                        userAlbumsSection
                    }
                    
                    // 3. Chronological Timeline (Collapsible Years & Months)
                    timelineSection
                }
                .padding(16)
            }
            .background(Color.platformGroupedBackground)
            .navigationTitle("AI & Timeline")
            .sheet(item: $selectedSmartAlbum) { album in
                AlbumDetailListView(item: album) { ids in
                    await coordinator.deleteAssets(withIDs: ids)
                }
            }
            .onAppear {
                // Expand most recent years by default
                if expandedYears.isEmpty, let firstYear = coordinator.yearSections.first?.year {
                    expandedYears.insert(firstYear)
                }
            }
        }
    }
    
    // MARK: - 1. AI Categorized Albums Section
    
    private var aiCategoriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("AI Categorized", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Text("\(coordinator.aiCategories.count) Categories")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            LazyVGrid(columns: aiColumns, spacing: 12) {
                ForEach(coordinator.aiCategories) { cat in
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
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(colorFor(cat.colorName).opacity(0.18))
                        .frame(width: 44, height: 44)
                    
                    Image(systemName: cat.sfSymbol)
                        .font(.title3)
                        .foregroundColor(colorFor(cat.colorName))
                }
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(cat.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    
                    HStack(spacing: 4) {
                        Text("\(cat.count)")
                            .fontWeight(.bold)
                        Text("• \(cat.formattedSize)")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                }
                
                Spacer()
            }
            .padding(12)
            .background(Color.platformSecondaryBackground)
            .cornerRadius(14)
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
                Text("\(coordinator.userAlbums.count) Albums")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(coordinator.userAlbums) { album in
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
                            MonthPhotoListView(month: month) { ids in
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
