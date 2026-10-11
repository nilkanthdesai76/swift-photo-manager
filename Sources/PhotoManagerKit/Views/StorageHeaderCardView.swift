import SwiftUI

/// Top storage overview card with visual multi-color usage bar and breakdown chips.
public struct StorageHeaderCardView: View {
    public let overview: LibraryStorageOverview
    
    public init(overview: LibraryStorageOverview) {
        self.overview = overview
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header Title & Total
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("Photo Library Storage")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                        
                        if overview.isEstimated {
                            Text("⚡️ Instant")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green.opacity(0.15))
                                .foregroundColor(.green)
                                .cornerRadius(6)
                        }
                    }
                    
                    Text(overview.formattedTotalSize)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                }
                
                Spacer()
                
                Text("\(overview.totalCount.formatted()) Items")
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
            }
            
            // Multi-Color Storage Distribution Bar
            storageDistributionBar
            
            // Category Legend Pills
            categoryLegendGrid
        }
        .padding(16)
        .background(Color.platformSecondaryBackground)
        .cornerRadius(18)
    }
    
    private var storageDistributionBar: some View {
        GeometryReader { proxy in
            let total = max(1, overview.totalBytes)
            let photoFrac = Double(overview.photosBytes) / Double(total)
            let liveFrac = Double(overview.livePhotosTotalBytes) / Double(total)
            let videoFrac = Double(overview.videosBytes) / Double(total)
            
            HStack(spacing: 2) {
                if photoFrac > 0.01 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.blue)
                        .frame(width: max(4, proxy.size.width * photoFrac))
                }
                if liveFrac > 0.01 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.purple)
                        .frame(width: max(4, proxy.size.width * liveFrac))
                }
                if videoFrac > 0.01 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.orange)
                        .frame(width: max(4, proxy.size.width * videoFrac))
                }
            }
        }
        .frame(height: 10)
        .background(Color.gray.opacity(0.15))
        .clipShape(Capsule())
    }
    
    private var categoryLegendGrid: some View {
        HStack(spacing: 12) {
            legendChip(
                color: .blue,
                title: "Photos",
                value: overview.formattedPhotosSize,
                count: overview.photosCount
            )
            
            legendChip(
                color: .purple,
                title: "Live Photos",
                value: overview.formattedLivePhotosSize,
                count: overview.livePhotosCount,
                subtitle: "Still \(overview.formattedLivePhotosStillSize) • Mov \(overview.formattedLivePhotosVideoSize)"
            )
            
            legendChip(
                color: .orange,
                title: "Videos",
                value: overview.formattedVideosSize,
                count: overview.videosCount
            )
        }
    }
    
    private func legendChip(color: Color, title: String, value: String, count: Int, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.primary)
            
            if let sub = subtitle {
                Text(sub)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
