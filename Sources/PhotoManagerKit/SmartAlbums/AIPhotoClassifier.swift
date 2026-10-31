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
import CoreImage

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
    /// Classification result for one photo: the AI category plus a blur flag
    /// computed from the same decoded thumbnail. `isBlurry` is nil when the
    /// delivered image is not trustworthy for blur evaluation (iCloud-only
    /// assets can surface a small on-device surrogate that PhotoKit does not
    /// mark degraded under `.fastFormat`) — callers must not flag the asset
    /// in either direction in that case.
    public struct ClassificationResult: Sendable {
        public let category: String
        public let isBlurry: Bool?

        public init(category: String, isBlurry: Bool?) {
            self.category = category
            self.isBlurry = isBlurry
        }
    }

    /// Classifies a PHAsset with the full main-branch pipeline: instant metadata
    /// fast paths, Tier-1 `VNClassifyImageRequest` with screenshot/document
    /// fast exits, then gated Tier-2 face/animal detectors feeding the
    /// evidence-fusion mapper. Every photo resolves to a category —
    /// unclassifiable photos land in `ai_others` (hidden from the rail) so the
    /// AI albums cover the whole library like the Gallery pipeline did.
    ///
    /// Blur uses the main-branch CIEdges score on the same thumbnail AI sort
    /// already decodes — no separate blur scan.
    public static func classify(asset: PHAsset) -> ClassificationResult {
        // 1. Instant metadata classification. Blur still runs on that thumbnail.
        // Screenshots are not AI-classified — the AI rail uses the system album only.
        if asset.mediaSubtypes.contains(.photoDepthEffect) {
            return ClassificationResult(
                category: AIPhotoCategory.people.pmkCacheID,
                isBlurry: edgeBlurFlag(for: asset)
            )
        }
        if asset.mediaSubtypes.contains(.photoPanorama) {
            return ClassificationResult(
                category: AIPhotoCategory.nature.pmkCacheID,
                isBlurry: edgeBlurFlag(for: asset)
            )
        }

        #if canImport(Vision)
        guard let cgImage = loadFastThumbnailCGImage(for: asset) else {
            return ClassificationResult(category: AIPhotoCategory.others.pmkCacheID, isBlurry: false)
        }
        let isBlurry: Bool? = computeBlurFlag(cgImage: cgImage)

        let classifyRequest = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            // Tier-1 scene classifier (~4-5 ms on ANE)
            try handler.perform([classifyRequest])
            guard let observations = classifyRequest.results else {
                return ClassificationResult(category: AIPhotoCategory.others.pmkCacheID, isBlurry: isBlurry)
            }

            let labelResults = observations
                .filter { $0.confidence > 0.01 }
                .map { VisionLabelResult(label: $0.identifier, confidence: $0.confidence) }

            // Fast-exit for clear documents before Tier-2 (screenshots are system-album only).
            var maxDocumentConfidence: Float = 0
            var maxAnimalConfidence: Float = 0
            var maxPeopleConfidence: Float = 0

            for result in labelResults {
                let label = result.label.lowercased()
                if label == "document" || label == "printed_page" {
                    maxDocumentConfidence = max(maxDocumentConfidence, result.confidence)
                }
                if PMKAIPhotoCategoryMapper.animalClueKeywords.contains(label) {
                    maxAnimalConfidence = max(maxAnimalConfidence, result.confidence)
                }
                if PMKAIPhotoCategoryMapper.peopleClueKeywords.contains(label) {
                    maxPeopleConfidence = max(maxPeopleConfidence, result.confidence)
                }
            }

            if maxDocumentConfidence >= 0.40 && maxAnimalConfidence < 0.03 && maxPeopleConfidence < 0.06 {
                return ClassificationResult(
                    category: PMKAIPhotoCategoryMapper.map(
                        labels: labelResults,
                        isScreenshotAsset: false,
                        documentTextCoverage: 0,
                        faceCount: 0,
                        animalDetected: false
                    ).category.pmkCacheID,
                    isBlurry: isBlurry
                )
            }

            // Tier-2 detectors only run when the labels justify them.
            let needsAnimalDetector = maxAnimalConfidence >= 0.03
            let needsFaceDetector = maxPeopleConfidence >= 0.06

            let faceRequest = VNDetectFaceRectanglesRequest()
            let animalRequest = VNRecognizeAnimalsRequest()

            var secondaryRequests: [VNRequest] = []
            if needsFaceDetector {
                secondaryRequests.append(faceRequest)
            }
            if needsAnimalDetector {
                secondaryRequests.append(animalRequest)
            }
            if !secondaryRequests.isEmpty {
                try handler.perform(secondaryRequests)
            }

            let faceCount: Int = needsFaceDetector ? (faceRequest.results?.count ?? 0) : 0
            let animalDetected: Bool
            if needsAnimalDetector, let animalResults = animalRequest.results as? [VNRecognizedObjectObservation] {
                animalDetected = !animalResults.isEmpty
            } else {
                animalDetected = false
            }

            return ClassificationResult(
                category: PMKAIPhotoCategoryMapper.map(
                    labels: labelResults,
                    isScreenshotAsset: false,
                    documentTextCoverage: 0,
                    faceCount: faceCount,
                    animalDetected: animalDetected
                ).category.pmkCacheID,
                isBlurry: isBlurry
            )
        } catch {
            return ClassificationResult(category: AIPhotoCategory.others.pmkCacheID, isBlurry: isBlurry)
        }
        #else
        return ClassificationResult(category: AIPhotoCategory.others.pmkCacheID, isBlurry: false)
        #endif
    }

    /// Main-branch blur: CIEdges at 96px, intensity 10. Lower score = blurrier.
    /// Photos under `blurThreshold` (0.16) are the blur group. Near-black
    /// frames return infinity so they are not flagged.
    private static let blurThreshold: Float = 0.16
    private static let blurCIContext = CIContext(options: [.cacheIntermediates: false])

    /// nil when the thumbnail never arrived — do not treat that as sharp or blurry.
    private static func edgeBlurFlag(for asset: PHAsset) -> Bool? {
        guard let cgImage = loadFastThumbnailCGImage(for: asset) else { return nil }
        return computeBlurFlag(cgImage: cgImage)
    }

    private static func computeBlurFlag(cgImage: CGImage) -> Bool {
        let score = computeBlurScore(for: CIImage(cgImage: cgImage))
        return score < blurThreshold
    }

    /// Same statistic as main .
    private static func computeBlurScore(for fullImage: CIImage) -> Float {
        let maxSide = max(fullImage.extent.width, fullImage.extent.height)
        let targetSide: CGFloat = 96
        let ciImage: CIImage
        if maxSide > targetSide {
            let scale = targetSide / maxSide
            ciImage = fullImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            ciImage = fullImage
        }

        if meanLuminance(of: ciImage) < 0.06 {
            return .infinity
        }

        let edgesFilter = CIFilter(name: "CIEdges")
        edgesFilter?.setValue(ciImage, forKey: kCIInputImageKey)
        edgesFilter?.setValue(10.0, forKey: kCIInputIntensityKey)
        guard let edgesImage = edgesFilter?.outputImage else { return .infinity }

        let avgFilter = CIFilter(name: "CIAreaAverage")
        avgFilter?.setValue(edgesImage, forKey: kCIInputImageKey)
        avgFilter?.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        guard let output = avgFilter?.outputImage else { return .infinity }

        var result: [Float] = [0, 0, 0, 0]
        blurCIContext.render(
            output,
            toBitmap: &result,
            rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )
        return result[0] + result[1] + result[2]
    }

    private static func meanLuminance(of ciImage: CIImage) -> Float {
        let avgFilter = CIFilter(name: "CIAreaAverage")
        avgFilter?.setValue(ciImage, forKey: kCIInputImageKey)
        avgFilter?.setValue(CIVector(cgRect: ciImage.extent), forKey: kCIInputExtentKey)
        guard let output = avgFilter?.outputImage else { return 1 }
        var result: [Float] = [0, 0, 0, 0]
        blurCIContext.render(
            output,
            toBitmap: &result,
            rowBytes: 16,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )
        return 0.2126 * result[0] + 0.7152 * result[1] + 0.0722 * result[2]
    }

    /// Blur-only pass for photos whose AI category is already cached.
    /// nil means the thumbnail was not delivered.
    public static func evaluateBlurOnly(asset: PHAsset) -> Bool? {
        edgeBlurFlag(for: asset)
    }
    
    /// 192px serves both the Vision classifier and the blur-energy check on
    /// the same decoded thumbnail.
    private static let targetSize = CGSize(width: 192, height: 192)
    private static let imageOptions: PHImageRequestOptions = {
        let opt = PHImageRequestOptions()
        opt.deliveryMode = .fastFormat
        opt.resizeMode = .fast
        opt.isNetworkAccessAllowed = false
        opt.isSynchronous = true
        return opt
    }()
    
    /// Some PhotoKit deliveries have no `cgImage` until they are drawn.
    private static func renderedCGImage(from image: PlatformImage) -> CGImage? {
        #if canImport(UIKit)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }.cgImage
        #elseif canImport(AppKit)
        var rect = CGRect(origin: .zero, size: targetSize)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return nil
        #endif
    }

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
                resultCGImage = Self.renderedCGImage(from: img)
            }
        }
        return resultCGImage
    }
    #endif
}
