import Foundation

public struct VisionLabelResult: Sendable {
    public let label: String
    public let confidence: Float
    
    public init(label: String, confidence: Float) {
        self.label = label
        self.confidence = confidence
    }
}

public enum AIPhotoCategory: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case people
    case nature
    case animals
    case indoor
    case vehicle
    case device
    case food
    case docs
    case screenshots
    case others

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .people: return "People"
        case .nature: return "Nature"
        case .animals: return "Animals"
        case .indoor: return "Indoor"
        case .vehicle: return "Vehicle"
        case .device: return "Device"
        case .food: return "Food"
        case .docs: return "Docs"
        case .screenshots: return "Screenshots"
        case .others: return "Others"
        }
    }

    public var displayOrder: Int {
        switch self {
        case .nature: return 0
        case .animals: return 1
        case .indoor: return 2
        case .vehicle: return 3
        case .device: return 4
        case .food: return 5
        case .docs: return 6
        case .screenshots: return 79
        case .others: return 8
        case .people: return 9
        }
    }

    public static var visibleCategories: [AIPhotoCategory] {
        [.nature, .animals, .indoor, .vehicle, .device, .food, .docs, .screenshots]
    }
}
