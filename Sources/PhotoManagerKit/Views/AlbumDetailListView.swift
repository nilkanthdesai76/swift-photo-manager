import SwiftUI

#if canImport(Photos)
import Photos
#endif

/// Detailed grid and list explorer for smart albums, large media, and old media.
public struct AlbumDetailListView: View {
    public let item: SmartAlbumItem
    public let onDelete: ([String]) async -> Bool
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedIDs: Set<String> = []
    @State private var isSelectionMode = false
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var selectedDetailAssetID: String?
    
    public init(
        item: SmartAlbumItem,
        onDelete: @escaping ([String]) async -> Bool
    ) {
        self.item = item
        self.onDelete = onDelete
    }
    
    private let columns = [
        GridItem(.adaptive(minimum: 105), spacing: 4)
    ]
    
    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if item.assetIDs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.secondary)
                        Text("No Items")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(item.assetIDs, id: \.self) { assetID in
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
                if !item.assetIDs.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button(isSelectionMode ? "Cancel" : "Select") {
                            isSelectionMode.toggle()
                            if !isSelectionMode { selectedIDs.removeAll() }
                        }
                    }
                }
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
    
    private func assetCell(_ id: String) -> some View {
        let isSelected = selectedIDs.contains(id)
        return ZStack(alignment: .topTrailing) {
            AssetThumbnailView(assetID: id)
                .aspectRatio(1, contentMode: .fill)
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
