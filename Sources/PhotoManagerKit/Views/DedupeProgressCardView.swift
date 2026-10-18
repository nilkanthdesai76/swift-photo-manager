import SwiftUI

/// High-priority card for Duplicate and Similar media clusters, featuring real-time in-card hashing progress.
public struct DedupeProgressCardView: View {
    public let title: String
    public let subtitle: String
    public let sfSymbol: String
    public let accentColor: Color
    public let groups: [DedupeGroup]
    public let progress: ScanProgress
    public let action: () -> Void
    
    public init(
        title: String,
        subtitle: String,
        sfSymbol: String,
        accentColor: Color,
        groups: [DedupeGroup],
        progress: ScanProgress,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.sfSymbol = sfSymbol
        self.accentColor = accentColor
        self.groups = groups
        self.progress = progress
        self.action = action
    }
    
    public var totalReclaimableBytes: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }
    
    public var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    // Symbol Icon
                    ZStack {
                        Circle()
                            .fill(accentColor.opacity(0.12))
                            .frame(width: 44, height: 44)
                        Image(systemName: sfSymbol)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(accentColor)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline)
                            .fontWeight(.bold)
                            .foregroundColor(.primary)
                        
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    if progress.isScanning {
                        // Live In-Card Circular Progress Ring
                        ZStack {
                            Circle()
                                .stroke(accentColor.opacity(0.2), lineWidth: 3)
                                .frame(width: 32, height: 32)
                            Circle()
                                .trim(from: 0, to: CGFloat(progress.fraction))
                                .stroke(accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 32, height: 32)
                            Text(progress.percentString)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(accentColor)
                        }
                    } else if !groups.isEmpty {
                        // Reclaimable Badge
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(groups.count) Groups")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.primary)
                            
                            Text(ByteFormatter.format(bytes: totalReclaimableBytes))
                                .font(.system(size: 11, weight: .bold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(accentColor.opacity(0.15))
                                .foregroundColor(accentColor)
                                .cornerRadius(6)
                        }
                        
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else if progress.total == 0 {
                        // Scan not started yet for this card — show an indeterminate waiting state
                        // instead of a misleading "Clean" badge.
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Waiting")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        // Clean state
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("Clean")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                // In-Card Progress Bar if scanning — label reflects the current phase (Hashing / Grouping)
                if progress.isScanning {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress.fraction)
                            .tint(accentColor)
                        HStack {
                            Text(progress.label.map { "\($0)…" } ?? "Hashing library assets…")
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
            }
            .padding(14)
            .background(Color.platformSecondaryBackground)
            .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }
}
