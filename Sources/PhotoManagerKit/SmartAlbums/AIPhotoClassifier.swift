import Foundation

#if canImport(Photos)
import Photos
#endif

#if canImport(Vision)
import Vision
#endif

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Real on-device AI scene & object classifier using Apple's Vision framework (VNClassifyImageRequest).
/// Strictly assigns semantic taxonomies; NEVER uses random modulo hashing.
public enum AIPhotoClassifier {
    
    // MARK: - Taxonomies matching Vision's supportedIdentifiers
    
    public static let vehicleKeywords: Set<String> = [
        "car", "automobile", "motorcycle", "bicycle", "bike", "bus", "truck", "van",
        "suv", "scooter", "train", "airplane", "aircraft", "helicopter", "boat",
        "speedboat", "sailboat", "yacht", "motorhome", "vehicle", "engine_vehicle",
        "formula_one_car", "police_car", "sportscar", "streetcar", "wheel", "tire", "rickshaw"
    ]
    
    public static let animalKeywords: Set<String> = [
        "animal", "dog", "cat", "bird", "fish", "horse", "cow", "pet", "puppy", "kitten",
        "mammal", "reptile", "insect", "bear", "lion", "tiger", "deer", "rabbit", "sheep",
        "goat", "duck", "goose", "chicken", "wildlife", "canine", "feline", "retriever",
        "shepherd", "terrier", "hound", "bulldog", "poodle", "pug", "corgi", "husky", "chihuahua",
        "prairie_dog", "coyote_wolf", "fox", "elephant", "panda", "giraffe", "zebra", "monkey",
        "dolphin", "whale", "penguin", "parrot", "eagle", "tortoise", "lizard", "goldfish"
    ]
    
    public static let foodKeywords: Set<String> = [
        "food", "dish", "meal", "pizza", "burger", "hamburger", "sandwich", "pasta",
        "rice", "bread", "cake", "cookie", "donut", "fruit", "vegetable", "salad",
        "sushi", "curry", "meat", "steak", "chicken", "fries", "dessert", "chocolate",
        "ice_cream", "coffee", "tea_drink", "drink", "cocktail", "beer", "wine",
        "apple", "banana", "citrus_fruit", "berry", "strawberry", "seafood", "pie",
        "pastry", "cheese", "egg", "dining", "tableware", "plate", "bowl"
    ]
    
    public static let natureKeywords: Set<String> = [
        "tree", "forest", "mountain", "hill", "lake", "river", "ocean", "beach",
        "waterfall", "flower", "garden", "grass", "foliage", "plant", "vegetation",
        "landscape", "sky", "blue_sky", "sunset", "sunrise", "snow", "cloud",
        "nature", "wilderness", "scenery", "waterscape", "seascape", "park", "cliff",
        "canyon", "desert", "island", "aurora", "fog", "frost", "rain", "sun"
    ]
    
    public static let peopleKeywords: Set<String> = [
        "people", "person", "adult", "child", "baby", "teen", "face", "portrait",
        "man", "woman", "boy", "girl", "crowd", "family", "selfie", "athlete", "dancer"
    ]
    
    public static let cityKeywords: Set<String> = [
        "building", "architecture", "skyscraper", "tower", "bridge", "house",
        "urban", "city", "street", "monument", "castle", "facade", "downtown",
        "cathedral", "church", "temple", "stadium", "palace", "metropolis"
    ]
    
    public static let docKeywords: Set<String> = [
        "document", "printed_page", "paper", "receipt", "text", "book", "cardboard_box",
        "newspaper", "magazine", "label", "form", "invoice", "ticket", "screenshot"
    ]
    
    public static let indoorKeywords: Set<String> = [
        "indoor", "interior", "room", "bedroom", "living_room", "kitchen", "bathroom",
        "furniture", "sofa", "bed", "chair", "table", "dining_table", "closet", "shelf",
        "lamp", "desk", "wardrobe", "clothing", "clothesline", "iron_clothing", "clothespin",
        "apparel", "textile", "curtain", "carpet", "corridor", "hallway"
    ]
    
    // MARK: - Classifier
    
    #if canImport(Vision)
    /// Classifies a CGImage using VNClassifyImageRequest.
    /// Returns the category identifier (e.g. "ai_indoor", "ai_vehicles", etc.) or nil if unrecognized.
    public static func classify(cgImage: CGImage) -> String? {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        
        do {
            try handler.perform([request])
            guard let results = request.results else { return nil }
            
            var scores: [String: Float] = [
                "ai_vehicles": 0,
                "ai_animals": 0,
                "ai_food": 0,
                "ai_nature": 0,
                "ai_people": 0,
                "ai_city": 0,
                "ai_docs": 0,
                "ai_indoor": 0
            ]
            
            for obs in results where obs.confidence >= 0.02 {
                let id = obs.identifier.lowercased()
                let conf = obs.confidence
                
                if vehicleKeywords.contains(id) {
                    scores["ai_vehicles"] = max(scores["ai_vehicles"] ?? 0, conf)
                }
                if animalKeywords.contains(id) {
                    scores["ai_animals"] = max(scores["ai_animals"] ?? 0, conf)
                }
                if foodKeywords.contains(id) {
                    scores["ai_food"] = max(scores["ai_food"] ?? 0, conf)
                }
                if natureKeywords.contains(id) {
                    scores["ai_nature"] = max(scores["ai_nature"] ?? 0, conf)
                }
                if peopleKeywords.contains(id) {
                    scores["ai_people"] = max(scores["ai_people"] ?? 0, conf)
                }
                if cityKeywords.contains(id) {
                    scores["ai_city"] = max(scores["ai_city"] ?? 0, conf)
                }
                if docKeywords.contains(id) {
                    scores["ai_docs"] = max(scores["ai_docs"] ?? 0, conf)
                }
                if indoorKeywords.contains(id) {
                    scores["ai_indoor"] = max(scores["ai_indoor"] ?? 0, conf)
                }
            }
            
            // Prioritize category with the highest confidence >= 0.05
            guard let top = scores.max(by: { $0.value < $1.value }), top.value >= 0.05 else {
                return nil
            }
            return top.key
        } catch {
            return nil
        }
    }
    #endif
    
    #if canImport(Photos)
    /// Classifies a PHAsset by combining system metadata and Vision scene classification.
    public static func classify(asset: PHAsset) -> String? {
        // 1. Instant metadata classification
        if asset.mediaSubtypes.contains(.photoScreenshot) {
            return "ai_docs"
        }
        if asset.mediaSubtypes.contains(.photoDepthEffect) {
            return "ai_people"
        }
        if asset.mediaSubtypes.contains(.photoPanorama) {
            return "ai_nature"
        }
        
        #if canImport(Vision)
        // 2. Fetch fast 128px embedded thumbnail for Vision classification
        guard let cgImage = loadFastThumbnailCGImage(for: asset) else {
            return nil
        }
        return classify(cgImage: cgImage)
        #else
        return nil
        #endif
    }
    
    private static let targetSize = CGSize(width: 128, height: 128)
    private static let imageOptions: PHImageRequestOptions = {
        let opt = PHImageRequestOptions()
        opt.deliveryMode = .fastFormat
        opt.resizeMode = .fast
        opt.isNetworkAccessAllowed = false
        opt.isSynchronous = true
        return opt
    }()
    
    private static func loadFastThumbnailCGImage(for asset: PHAsset) -> CGImage? {
        var resultCGImage: CGImage?
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: imageOptions
        ) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if !isDegraded, let img = image {
                #if canImport(UIKit)
                resultCGImage = img.cgImage
                #elseif canImport(AppKit)
                resultCGImage = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
                #endif
            }
        }
        return resultCGImage
    }
    #endif
}
