import SwiftUI

#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

extension Color {
    public static var platformSecondaryBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .secondarySystemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color.gray.opacity(0.12)
        #endif
    }
    
    public static var platformGroupedBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemGroupedBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.gray.opacity(0.08)
        #endif
    }
    
    public static var platformTertiaryBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .tertiarySystemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .underPageBackgroundColor)
        #else
        return Color.gray.opacity(0.18)
        #endif
    }
}

public struct PlatformImageView: View {
    public let image: PlatformImage
    public var contentMode: ContentMode
    
    public init(image: PlatformImage, contentMode: ContentMode = .fill) {
        self.image = image
        self.contentMode = contentMode
    }
    
    public var body: some View {
        #if canImport(UIKit)
        Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .clipped()
        #elseif canImport(AppKit)
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .clipped()
        #endif
    }
}
