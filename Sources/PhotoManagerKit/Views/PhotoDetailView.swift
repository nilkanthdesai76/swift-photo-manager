import SwiftUI

#if canImport(Photos)
import Photos
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Full-screen high-resolution photo detail view with comprehensive metadata inspection and safe deletion.
public struct PhotoDetailView: View {
    public let assetID: String
    public var initialSizeRecord: AssetSizeRecord?
    public var onDelete: ((String) async -> Bool)?
    
    @Environment(\.dismiss) private var dismiss
    @State private var currentSizeRecord: AssetSizeRecord?
    @State private var highResImage: PlatformImage?
    @State private var asset: PHAsset?
    @State private var isLoadingImage = true
    @State private var showDeleteAlert = false
    @State private var isFavorite = false
    @State private var zoomScale: CGFloat = 1.0
    
    public init(
        assetID: String,
        sizeRecord: AssetSizeRecord? = nil,
        onDelete: ((String) async -> Bool)? = nil
    ) {
        self.assetID = assetID
        self.initialSizeRecord = sizeRecord
        self._currentSizeRecord = State(initialValue: sizeRecord)
        self.onDelete = onDelete
    }
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Full-Size Image Display
                    photoDisplayArea
                    
                    // Metadata Cards
                    metadataSection
                }
                .padding(.vertical, 16)
            }
            .background(Color.platformGroupedBackground)
            .navigationTitle("Photo Details")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                
                ToolbarItemGroup(placement: .primaryAction) {
                    #if canImport(UIKit)
                    if let image = highResImage {
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("Photo", image: Image(uiImage: image))) {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                    #endif
                    
                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.red)
                    }
                }
            }
            .confirmationDialog(
                "Delete this photo?",
                isPresented: $showDeleteAlert,
                titleVisibility: .visible
            ) {
                Button("Delete Photo", role: .destructive) {
                    deleteCurrentPhoto()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This item will be moved to Recently Deleted in your Photos library.")
            }
            .onAppear {
                loadFullAsset()
            }
        }
    }
    
    // MARK: - Image Area
    
    private var photoDisplayArea: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.black.opacity(0.85))
                .aspectRatio(4/3, contentMode: .fit)
            
            if let image = highResImage {
                PlatformImageView(image: image, contentMode: .fit)
                    .cornerRadius(14)
                    .padding(4)
                    .scaleEffect(zoomScale)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { val in zoomScale = max(1.0, min(val, 3.0)) }
                            .onEnded { _ in withAnimation(.spring()) { zoomScale = 1.0 } }
                    )
            } else if isLoadingImage {
                ProgressView("Loading full resolution…")
                    .tint(.white)
                    .foregroundColor(.white)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 48))
                    .foregroundColor(.gray)
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 16)
    }
    
    // MARK: - Metadata Section
    
    private var metadataSection: some View {
        VStack(spacing: 16) {
            // Primary Overview Card
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("File Information")
                        .font(.headline)
                    Spacer()
                    if let asset = asset {
                        Text(formatMediaType(asset))
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.blue.opacity(0.12))
                            .foregroundColor(.blue)
                            .cornerRadius(6)
                    }
                }
                
                Divider()
                
                // Size Row
                infoRow(
                    icon: "externaldrive",
                    title: "File Size (KVC)",
                    value: currentSizeRecord != nil ? ByteFormatter.format(bytes: currentSizeRecord!.totalBytes) : "Reading…"
                )
                
                // Live Photo split if applicable
                if let rec = currentSizeRecord, rec.isLivePhoto {
                    infoRow(
                        icon: "livephoto",
                        title: "Live Photo Split",
                        value: "Still \(ByteFormatter.format(bytes: rec.stillBytes)) • Motion \(ByteFormatter.format(bytes: rec.videoBytes))"
                    )
                }
                
                // Resolution Row
                if let asset = asset {
                    let mp = Double(asset.pixelWidth * asset.pixelHeight) / 1_000_000.0
                    infoRow(
                        icon: "aspectratio",
                        title: "Dimensions",
                        value: "\(asset.pixelWidth) × \(asset.pixelHeight) (\(String(format: "%.1f", mp)) MP)"
                    )
                    
                    if asset.mediaType == .video {
                        infoRow(
                            icon: "clock",
                            title: "Duration",
                            value: String(format: "%d seconds", Int(asset.duration))
                        )
                    }
                }
                
                // Date & Time Row
                if let date = asset?.creationDate {
                    infoRow(
                        icon: "calendar",
                        title: "Captured Date",
                        value: date.formatted(date: .complete, time: .shortened)
                    )
                }
            }
            .padding(16)
            .background(Color.platformSecondaryBackground)
            .cornerRadius(16)
            .padding(.horizontal, 16)
            
            // Technical & Identification Card
            VStack(alignment: .leading, spacing: 12) {
                Text("Library Metadata")
                    .font(.headline)
                
                Divider()
                
                if let asset = asset {
                    infoRow(
                        icon: "heart.fill",
                        title: "Favorite",
                        value: asset.isFavorite ? "Yes" : "No"
                    )
                    
                    infoRow(
                        icon: "tag",
                        title: "Subtypes",
                        value: formatSubtypes(asset)
                    )
                }
                
                // Local Identifier with copy action
                HStack(alignment: .top) {
                    Image(systemName: "number")
                        .foregroundColor(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Identifier")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(assetID)
                            .font(.caption2)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = assetID
                        #elseif canImport(AppKit)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(assetID, forType: .string)
                        #endif
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.caption)
                    }
                }
            }
            .padding(16)
            .background(Color.platformSecondaryBackground)
            .cornerRadius(16)
            .padding(.horizontal, 16)
        }
    }
    
    private func infoRow(icon: String, title: String, value: String) -> some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 24)
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.primary)
        }
    }
    
    // MARK: - Asset Loading
    
    private func loadFullAsset() {
        #if canImport(Photos)
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let phAsset = fetchResult.firstObject else {
            self.isLoadingImage = false
            return
        }
        self.asset = phAsset
        self.isFavorite = phAsset.isFavorite
        
        if self.currentSizeRecord == nil {
            self.currentSizeRecord = StorageCalculator.resolveExactSize(for: phAsset)
        }
        
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        
        #if canImport(UIKit)
        let screen = UIScreen.main.bounds
        let targetSize = CGSize(width: screen.width * 2, height: screen.height * 2)
        #else
        let targetSize = CGSize(width: 1600, height: 1600)
        #endif
        
        PHImageManager.default().requestImage(
            for: phAsset,
            targetSize: targetSize,
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            if let img = image {
                self.highResImage = img
                self.isLoadingImage = false
            }
        }
        #endif
    }
    
    private func deleteCurrentPhoto() {
        Task {
            if let onDelete = onDelete {
                let success = await onDelete(assetID)
                if success {
                    await MainActor.run { dismiss() }
                }
            } else {
                #if canImport(Photos)
                let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
                guard fetchResult.count > 0 else { return }
                try? await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.deleteAssets(fetchResult)
                }
                await MainActor.run { dismiss() }
                #endif
            }
        }
    }
    
    private func formatMediaType(_ asset: PHAsset) -> String {
        if asset.mediaSubtypes.contains(.photoLive) { return "Live Photo" }
        if asset.mediaType == .video { return "Video" }
        return "Photo"
    }
    
    private func formatSubtypes(_ asset: PHAsset) -> String {
        var labels: [String] = []
        if asset.mediaSubtypes.contains(.photoPanorama) { labels.append("Panorama") }
        if asset.mediaSubtypes.contains(.photoHDR) { labels.append("HDR") }
        if asset.mediaSubtypes.contains(.photoScreenshot) { labels.append("Screenshot") }
        if asset.mediaSubtypes.contains(.photoLive) { labels.append("Live") }
        if asset.mediaSubtypes.contains(.videoTimelapse) { labels.append("Time-lapse") }
        if asset.mediaSubtypes.contains(.videoHighFrameRate) { labels.append("Slo-mo") }
        return labels.isEmpty ? "Standard" : labels.joined(separator: ", ")
    }
}
