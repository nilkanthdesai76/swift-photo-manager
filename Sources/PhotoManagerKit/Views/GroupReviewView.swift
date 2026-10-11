import SwiftUI

#if canImport(Photos)
import Photos
#endif

/// Grid-based duplicate & similarity review sheet with "Keep Best" selector and safe PhotoKit deletion.
public struct GroupReviewView: View {
    public let title: String
    @Binding public var groups: [DedupeGroup]
    public let onDelete: ([String]) async -> Bool
    @Environment(\.dismiss) private var dismiss
    
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    @State private var selectedDetailAssetID: String?
    
    public init(
        title: String,
        groups: Binding<[DedupeGroup]>,
        onDelete: @escaping ([String]) async -> Bool
    ) {
        self.title = title
        self._groups = groups
        self.onDelete = onDelete
    }
    
    private var totalSelectedBytes: Int64 {
        groups.reduce(0) { $0 + $1.selectedForDeletionBytes }
    }
    
    private var totalSelectedCount: Int {
        groups.reduce(0) { $0 + $1.items.filter(\.isSelectedForDeletion).count }
    }
    
    private let gridColumns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if groups.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.green)
                        Text("No Duplicates Found")
                            .font(.headline)
                        Text("Your library is clean and well-organized.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 20) {
                            ForEach($groups) { $group in
                                groupGridCard($group)
                            }
                        }
                        .padding(16)
                    }
                    
                    // Bottom Clean Bar
                    if totalSelectedCount > 0 {
                        cleanBottomBar
                    }
                }
            }
            .background(Color.platformGroupedBackground)
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !groups.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Auto-Select") {
                            autoSelectBest()
                        }
                    }
                }
            }
            .confirmationDialog(
                "Delete \(totalSelectedCount) items?",
                isPresented: $showDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete (\(ByteFormatter.format(bytes: totalSelectedBytes)))", role: .destructive) {
                    performDeletion()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Selected items will be moved to Recently Deleted in your Photos library.")
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
    
    // MARK: - Group Card with Photo Grid
    
    private func groupGridCard(_ group: Binding<DedupeGroup>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Group Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(group.items.count) Similar Items")
                        .font(.subheadline)
                        .fontWeight(.bold)
                    
                    Text("Reclaim \(ByteFormatter.format(bytes: group.wrappedValue.reclaimableBytes))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button {
                    let best = group.wrappedValue.bestAssetID
                    for i in 0..<group.wrappedValue.items.count {
                        group.wrappedValue.items[i].isSelectedForDeletion = (group.wrappedValue.items[i].id != best)
                    }
                } label: {
                    Text("Select Duplicates")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.blue.opacity(0.12))
                        .foregroundColor(.blue)
                        .cornerRadius(8)
                }
            }
            
            // Grid of Photos in Group
            LazyVGrid(columns: gridColumns, spacing: 8) {
                ForEach(group.items) { $item in
                    gridPhotoCell(item: $item, bestID: group.wrappedValue.bestAssetID)
                }
            }
        }
        .padding(14)
        .background(Color.platformSecondaryBackground)
        .cornerRadius(18)
    }
    
    private func gridPhotoCell(item: Binding<DedupeAssetItem>, bestID: String) -> some View {
        let isBest = item.wrappedValue.id == bestID
        let isSelected = item.wrappedValue.isSelectedForDeletion
        
        return ZStack(alignment: .topTrailing) {
            // Photo Thumbnail (Tap to open full photo details)
            AssetThumbnailView(assetID: item.wrappedValue.id)
                .aspectRatio(1, contentMode: .fill)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedDetailAssetID = item.wrappedValue.id
                }
                .overlay(
                    // Bottom Size & Resolution Gradient
                    VStack {
                        Spacer()
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.wrappedValue.formattedTotalSize)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white)
                                Text("\(item.wrappedValue.pixelWidth)×\(item.wrappedValue.pixelHeight)")
                                    .font(.system(size: 8))
                                    .foregroundColor(.white.opacity(0.8))
                            }
                            Spacer()
                        }
                        .padding(6)
                        .background(
                            LinearGradient(
                                colors: [.clear, .black.opacity(0.75)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    }
                )
            
            // Top Badges
            HStack {
                if isBest {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                        Text("Best")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.green)
                    .foregroundColor(.white)
                    .cornerRadius(6)
                    .padding(6)
                }
                
                Spacer()
                
                // Deletion Checkbox
                Button {
                    if !isBest {
                        item.isSelectedForDeletion.wrappedValue.toggle()
                    }
                } label: {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(isSelected ? .red : .white)
                        .shadow(radius: 3)
                        .padding(6)
                }
                .disabled(isBest)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isBest ? Color.green : (isSelected ? Color.red.opacity(0.8) : Color.clear), lineWidth: 2)
        )
    }
    
    private var cleanBottomBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(totalSelectedCount) Selected")
                        .font(.subheadline)
                        .fontWeight(.bold)
                    Text("Reclaim \(ByteFormatter.format(bytes: totalSelectedBytes))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button {
                    showDeleteConfirmation = true
                } label: {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text("Delete Selected")
                    }
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .disabled(isDeleting)
            }
            .padding(16)
            .background(Color.platformSecondaryBackground)
        }
    }
    
    private func autoSelectBest() {
        for i in 0..<groups.count {
            let best = groups[i].bestAssetID
            for j in 0..<groups[i].items.count {
                groups[i].items[j].isSelectedForDeletion = (groups[i].items[j].id != best)
            }
        }
    }
    
    private func performDeletion() {
        isDeleting = true
        var toDelete: [String] = []
        for g in groups {
            for item in g.items where item.isSelectedForDeletion {
                toDelete.append(item.id)
            }
        }
        
        Task {
            let success = await onDelete(toDelete)
            await MainActor.run {
                self.isDeleting = false
                if success {
                    dismiss()
                }
            }
        }
    }
}
