import SwiftUI

#if canImport(Photos)
import Photos
#endif

/// Group-by-group duplicate & similarity review sheet with "Keep Best" selector and safe PhotoKit deletion.
public struct GroupReviewView: View {
    public let title: String
    @Binding public var groups: [DedupeGroup]
    public let onDelete: ([String]) async -> Bool
    @Environment(\.dismiss) private var dismiss
    
    @State private var isDeleting = false
    @State private var showDeleteConfirmation = false
    
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
                        LazyVStack(spacing: 16) {
                            ForEach($groups) { $group in
                                groupSection($group)
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
        }
    }
    
    private func groupSection(_ group: Binding<DedupeGroup>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(group.items.count) Items")
                    .font(.caption)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                Text("Reclaim \(ByteFormatter.format(bytes: group.wrappedValue.reclaimableBytes))")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.12))
                    .foregroundColor(.blue)
                    .cornerRadius(6)
            }
            
            // Asset Items
            ForEach(group.items) { $item in
                let isBest = item.id == group.wrappedValue.bestAssetID
                HStack(spacing: 12) {
                    // Checkbox
                    Button {
                        if !isBest {
                            item.isSelectedForDeletion.toggle()
                        }
                    } label: {
                        Image(systemName: item.isSelectedForDeletion ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundColor(item.isSelectedForDeletion ? .red : .secondary)
                    }
                    .disabled(isBest)
                    
                    // Asset Thumbnail / Icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 50, height: 50)
                        
                        Image(systemName: item.isVideo ? "video" : (item.isLivePhoto ? "livephoto" : "photo"))
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                    
                    // Metadata
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.formattedTotalSize)
                                .font(.subheadline)
                                .fontWeight(.bold)
                            
                            if isBest {
                                Text("Best Quality")
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green.opacity(0.15))
                                    .foregroundColor(.green)
                                    .cornerRadius(6)
                            }
                        }
                        
                        if item.isLivePhoto {
                            Text("Still: \(item.formattedStillSize) • Mov: \(item.formattedVideoSize)")
                                .font(.system(size: 10))
                                .foregroundColor(.purple)
                        } else if item.isVideo {
                            Text("\(Int(item.duration))s • \(item.pixelWidth)×\(item.pixelHeight)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        } else {
                            Text("\(item.pixelWidth)×\(item.pixelHeight)")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    Spacer()
                }
                .padding(8)
                .background(isBest ? Color.green.opacity(0.06) : Color.platformTertiaryBackground)
                .cornerRadius(10)
            }
        }
        .padding(14)
        .background(Color.platformSecondaryBackground)
        .cornerRadius(16)
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
