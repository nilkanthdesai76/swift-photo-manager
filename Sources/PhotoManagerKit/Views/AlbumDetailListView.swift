import SwiftUI

#if canImport(Photos)
import Photos
#endif

/// Detailed grid and list explorer for smart albums, large media, and old media.
public struct AlbumDetailListView: View {
    public let item: SmartAlbumItem
    public let sizeRecords: [String: AssetSizeRecord]
    public let onDelete: ([String]) async -> Bool
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedIDs: Set<String> = []
    @State private var isSelectionMode = false
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var selectedDetailAssetID: String?
    
    // Sort and Filter States
    @State private var selectedSort: AssetSortOrder = .latest
    @State private var selectedFilter: AssetTimeFilter = .all
    @State private var assetCreationDates: [String: Date] = [:]
    
    public init(
        item: SmartAlbumItem,
        sizeRecords: [String: AssetSizeRecord] = [:],
        onDelete: @escaping ([String]) async -> Bool
    ) {
        self.item = item
        self.sizeRecords = sizeRecords
        self.onDelete = onDelete
    }
    
    /// Checks whether this album represents "Old Photos", where time range filtering is prohibited.
    private var isOldPhotos: Bool {
        item.id == "old_photos" || item.id.contains("old") || item.title.localizedCaseInsensitiveContains("old photos")
    }
    
    private var showsTimeFilter: Bool {
        !isOldPhotos
    }
    
    private var isFilterActive: Bool {
        showsTimeFilter && selectedFilter != .all
    }
    
    private var displayedAssetIDs: [String] {
        // 1. Time range filter
        let filtered: [String]
        if showsTimeFilter && selectedFilter != .all {
            filtered = item.assetIDs.filter { id in
                selectedFilter.matches(date: assetCreationDates[id])
            }
        } else {
            filtered = item.assetIDs
        }
        
        // 2. Sorting
        return filtered.sorted { id1, id2 in
            switch selectedSort {
            case .latest:
                let d1 = assetCreationDates[id1] ?? Date.distantPast
                let d2 = assetCreationDates[id2] ?? Date.distantPast
                if d1 != d2 { return d1 > d2 }
                return id1 < id2
                
            case .oldest:
                let d1 = assetCreationDates[id1] ?? Date.distantFuture
                let d2 = assetCreationDates[id2] ?? Date.distantFuture
                if d1 != d2 { return d1 < d2 }
                return id1 < id2
                
            case .largest:
                let b1 = sizeRecords[id1]?.totalBytes ?? 0
                let b2 = sizeRecords[id2]?.totalBytes ?? 0
                if b1 != b2 { return b1 > b2 }
                let d1 = assetCreationDates[id1] ?? Date.distantPast
                let d2 = assetCreationDates[id2] ?? Date.distantPast
                return d1 > d2
            }
        }
    }
    
    private let columns = [
        GridItem(.adaptive(minimum: 105), spacing: 4)
    ]
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Active Filter Pill Banner
                if isFilterActive {
                    activeFilterBanner
                }
                
                if item.assetIDs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No Items")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayedAssetIDs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text("No Items in \(selectedFilter.rawValue)")
                            .font(.headline)
                        Text("Try selecting a different time period or show all photos.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Button("Show All") {
                            selectedFilter = .all
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                        .padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(displayedAssetIDs, id: \.self) { assetID in
                                assetCell(assetID)
                            }
                        }
                        .padding(4)
                    }
                    
                    if isSelectionMode && !selectedIDs.isEmpty {
                        bottomDeleteBar
                    }
                }
            }
            .background(Color.platformGroupedBackground)
            .navigationTitle(item.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    HStack(spacing: 14) {
                        // Sort & Filter Menu
                        sortAndFilterMenu
                        
                        // Select Mode Toggle
                        if !item.assetIDs.isEmpty {
                            Button(isSelectionMode ? "Cancel" : "Select") {
                                isSelectionMode.toggle()
                                if !isSelectionMode { selectedIDs.removeAll() }
                            }
                        }
                    }
                }
            }
            .onAppear {
                loadAssetDates()
            }
            .confirmationDialog(
                "Delete \(selectedIDs.count) items?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Selected", role: .destructive) {
                    performDelete()
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: Binding(
                get: { selectedDetailAssetID.map { IdentifiableString(id: $0) } },
                set: { selectedDetailAssetID = $0?.id }
            )) { wrapper in
                PhotoDetailView(assetID: wrapper.id, onDelete: { singleID in
                    let success = await onDelete([singleID])
                    if success {
                        dismiss()
                    }
                    return success
                })
            }
        }
    }
    
    // MARK: - Sort & Filter Menu
    
    private var sortAndFilterMenu: some View {
        Menu {
            Section("Sort By") {
                ForEach(AssetSortOrder.allCases) { sort in
                    Button {
                        selectedSort = sort
                    } label: {
                        if selectedSort == sort {
                            Label(sort.rawValue, systemImage: "checkmark")
                        } else {
                            Text(sort.rawValue)
                        }
                    }
                }
            }
            
            if showsTimeFilter {
                Section("Time Period") {
                    ForEach(AssetTimeFilter.allCases) { filter in
                        Button {
                            selectedFilter = filter
                        } label: {
                            if selectedFilter == filter {
                                Label(filter.rawValue, systemImage: "checkmark")
                            } else {
                                Text(filter.rawValue)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: isFilterActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.title3)
                .foregroundColor(isFilterActive ? .blue : .primary)
        }
    }
    
    // MARK: - Active Filter Banner
    
    private var activeFilterBanner: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .foregroundColor(.blue)
                    .font(.caption)
                Text("Filter: \(selectedFilter.rawValue)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.primary)
                Text("(\(displayedAssetIDs.count))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button {
                selectedFilter = .all
            } label: {
                HStack(spacing: 3) {
                    Text("Clear")
                    Image(systemName: "xmark.circle.fill")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.platformSecondaryBackground)
        .overlay(
            Rectangle()
                .fill(Color.gray.opacity(0.15))
                .frame(height: 1),
            alignment: .bottom
        )
    }
    
    private func loadAssetDates() {
        #if canImport(Photos)
        guard !item.assetIDs.isEmpty else { return }
        let ids = item.assetIDs
        
        Task.detached(priority: .userInitiated) {
            let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
            var dates: [String: Date] = [:]
            dates.reserveCapacity(fetch.count)
            fetch.enumerateObjects { asset, _, _ in
                if let d = asset.creationDate {
                    dates[asset.localIdentifier] = d
                }
            }
            let finalDates = dates
            await MainActor.run {
                self.assetCreationDates = finalDates
            }
        }
        #endif
    }
    
    private func assetCell(_ id: String) -> some View {
        let isSelected = selectedIDs.contains(id)
        return ZStack(alignment: .topTrailing) {
            AssetThumbnailView(assetID: id)
                .contentShape(Rectangle())
                .onTapGesture {
                    if isSelectionMode {
                        if isSelected { selectedIDs.remove(id) }
                        else { selectedIDs.insert(id) }
                    } else {
                        selectedDetailAssetID = id
                    }
                }
            
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .blue : .white)
                    .shadow(radius: 2)
                    .padding(6)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
    
    private var bottomDeleteBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("\(selectedIDs.count) Selected")
                    .font(.subheadline)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text("Delete")
                    }
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .disabled(isDeleting)
            }
            .padding(16)
            .background(Color.platformSecondaryBackground)
        }
    }
    
    private func performDelete() {
        isDeleting = true
        let ids = Array(selectedIDs)
        Task {
            let success = await onDelete(ids)
            await MainActor.run {
                self.isDeleting = false
                if success {
                    dismiss()
                }
            }
        }
    }
}

/// Helper for sheet presentation
public struct IdentifiableString: Identifiable {
    public let id: String
    public init(id: String) { self.id = id }
}
