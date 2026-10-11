import SwiftUI

/// Reusable card component for smart albums and threshold filters.
public struct SmartAlbumCardView: View {
    public let item: SmartAlbumItem
    public let action: () -> Void
    
    public init(item: SmartAlbumItem, action: @escaping () -> Void) {
        self.item = item
        self.action = action
    }
    
    private var accentColor: Color {
        switch item.accentColorName {
        case "indigo": return .indigo
        case "teal": return .teal
        case "purple": return .purple
        case "blue": return .blue
        case "pink": return .pink
        case "orange": return .orange
        case "red": return .red
        default: return .blue
        }
    }
    
    public var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // Icon
                ZStack {
                    Circle()
                        .fill(accentColor.opacity(0.12))
                        .frame(width: 40, height: 40)
                    Image(systemName: item.sfSymbol)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(accentColor)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    
                    Text("\(item.count) items")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Text(item.formattedSize)
                    .font(.footnote)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .background(Color.platformSecondaryBackground)
            .cornerRadius(14)
        }
        .buttonStyle(.plain)
    }
}
