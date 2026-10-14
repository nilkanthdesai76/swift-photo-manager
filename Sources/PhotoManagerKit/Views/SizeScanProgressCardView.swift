import SwiftUI

/// Phase 0 size-indexing card with a live percentage ring.
/// Tap opens a detailed popover with per-asset progress and resolved byte totals.
/// Observes only `progress` and `resolvedBytes`, so number updates re-render just this card.
public struct SizeScanProgressCardView: View {
    public let progress: ScanProgress
    public let resolvedBytes: Int64
    
    @State private var showDetails = false
    
    public init(progress: ScanProgress, resolvedBytes: Int64) {
        self.progress = progress
        self.resolvedBytes = resolvedBytes
    }
    
    public var body: some View {
        Button {
            showDetails = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.indigo.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: "externaldrive.fill.badge.checkmark")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.indigo)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Indexing Library")
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        Text("Resolving exact file sizes…")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    // Live circular progress ring
                    ZStack {
                        Circle()
                            .stroke(Color.indigo.opacity(0.2), lineWidth: 3)
                            .frame(width: 32, height: 32)
                        Circle()
                            .trim(from: 0, to: CGFloat(progress.fraction))
                            .stroke(Color.indigo, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 32, height: 32)
                        Text(progress.percentString)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(.indigo)
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress.fraction)
                        .tint(.indigo)
                    HStack {
                        Text("Tap for details")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(progress.processed) / \(progress.total)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 2)
            }
            .padding(14)
            .background(Color.platformSecondaryBackground)
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDetails, attachmentAnchor: .point(.top)) {
            SizeScanDetailView(progress: progress, resolvedBytes: resolvedBytes)
        }
    }
}

/// Detailed popover content for the size-index scan.
public struct SizeScanDetailView: View {
    public let progress: ScanProgress
    public let resolvedBytes: Int64
    
    public init(progress: ScanProgress, resolvedBytes: Int64) {
        self.progress = progress
        self.resolvedBytes = resolvedBytes
    }
    
    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(.indigo)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Size Indexing")
                        .font(.headline)
                    Text("Building the reusable asset size index")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            ProgressView(value: progress.fraction)
                .tint(.indigo)
            
            VStack(spacing: 8) {
                detailRow(label: "Progress", value: progress.percentString)
                detailRow(label: "Assets processed", value: "\(progress.processed) of \(progress.total)")
                detailRow(label: "Remaining", value: "\(max(0, progress.total - progress.processed))")
                Divider()
                detailRow(label: "Size resolved so far", value: ByteFormatter.format(bytes: resolvedBytes))
            }
        }
        .padding(16)
        #if os(iOS)
        .frame(width: 300)
        #else
        .frame(width: 320)
        #endif
    }
    
    private func detailRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.primary)
        }
    }
}
