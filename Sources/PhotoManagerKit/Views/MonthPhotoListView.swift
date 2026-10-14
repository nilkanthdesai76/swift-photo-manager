import SwiftUI

#if canImport(Photos)
import Photos
#endif

/// Grid view of photos taken within a specific calendar month.
public struct MonthPhotoListView: View {
    public let month: MonthGroup
    public let sizeRecords: [String: AssetSizeRecord]
    public let onDelete: ([String]) async -> Bool
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedDetailAssetID: String?
    @State private var isSelectionMode = false
    @State private var selectedIDs: Set<String> = []
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    
    // Sort State
    @State private var selectedSort: AssetSortOrder = .latest
    @State private var assetCreationDates: [String: Date] = [:]
    
    public init(
        month: MonthGroup,
        sizeRecords: [String: AssetSizeRecord] = [:],
        onDelete: @escaping ([String]) async -> Bool
    ) {
        self.month = month
        self.sizeRecords = sizeRecords
        self.onDelete = onDelete
    }
    
    private var displayedAssetIDs: [String] {
        month.assetIDs.sorted { id1, id2 in
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
        VStack(spacing: 0) {
            // Subtitle Header
            HStack {
                Text("\(month.count) Photos • \(month.formattedSize)")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.platformSecondaryBackground)
            
            // Photo Grid
            ScrollView {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(displayedAssetIDs, id: \.self) { assetID in
                        monthAssetCell(assetID)
                    }
                }
                .padding(4)
            }
            
            if isSelectionMode && !selectedIDs.isEmpty {
                bottomDeleteBar
            }
        }
        .background(Color.platformGroupedBackground)
        .navigationTitle("\(month.monthName) \(String(month.year))")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 14) {
                    // Sort Menu
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
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                            .font(.title3)
                    }
                    
                    if !month.assetIDs.isEmpty {
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
    
    private func monthAssetCell(_ id: String) -> some View {
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
    
    private func loadAssetDates() {
        #if canImport(Photos)
        guard !month.assetIDs.isEmpty else { return }
        let ids = month.assetIDs
        
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
}
