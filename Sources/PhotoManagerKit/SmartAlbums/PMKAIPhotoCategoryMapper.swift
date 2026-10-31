import Foundation

#if canImport(Vision)
import Vision
#endif

/// Shared Vision-label → `AIPhotoCategory` mapper.
///
/// Ported from the legacy gallery pipeline (main branch) so the PhotoManagerKit
/// AI sort matches its accuracy: exact taxonomy sets, Bayesian evidence fusion,
/// universal cluster compounding, and gated detection refinement. The big
/// difference vs the kit's original simple classifier: every photo resolves to
/// a category — unclassifiable photos land in `.others` (hidden from the rail)
/// instead of being dropped, which is what made the AI albums look empty.
enum PMKAIPhotoCategoryMapper: Sendable {
    nonisolated static let minimumConfidence: Float = 0.03
    nonisolated static let strongDocumentConfidence: Float = 0.40
    nonisolated static let documentTextCoverageThreshold: Float = 0.18
    nonisolated static let tieBreakEpsilon: Float = 0.15

    nonisolated static let categoryThresholds: [AIPhotoCategory: Float] = [
        .people: 0.62,
        .animals: 0.45,
        .vehicle: 0.55,
        .device: 0.45,
        .indoor: 0.55,
        .food: 0.48,
        .nature: 0.50
    ]

    nonisolated static let priorityOrder: [AIPhotoCategory] = [
        .people, .animals, .food, .vehicle, .device, .indoor, .nature
    ]

    struct Result: Sendable {
        let category: AIPhotoCategory
        let confidence: Double
        let isAmbiguous: Bool
    }

    // MARK: - Primary Mapper

    nonisolated static func map(
        labels: [VisionLabelResult],
        isScreenshotAsset: Bool = false,
        documentTextCoverage: Float = 0,
        faceCount: Int = 0,
        animalDetected: Bool = false
    ) -> Result {
        // Screenshots are seeded from the system Screenshots album only (main
        // parity). Ignore metadata / Vision "screenshot" labels here.
        _ = isScreenshotAsset

        let allNormalized = labels.map {
            VisionLabelResult(
                label: $0.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                confidence: $0.confidence
            )
        }

        // 1. Document Detection:
        // Guard: If an animal or person was explicitly detected, background books/paper
        // must NOT hijack the category into Documents unless text coverage is overwhelmingly high.
        let documentLabelConfidence = strongestConfidence(for: ["document", "printed_page"], in: allNormalized)
        let hasSubject = animalDetected || faceCount > 0
        if documentTextCoverage >= (hasSubject ? 0.40 : documentTextCoverageThreshold)
            || (!hasSubject && documentLabelConfidence >= strongDocumentConfidence) {
            let conf = max(documentTextCoverage, documentLabelConfidence)
            return Result(category: .docs, confidence: Double(conf), isAmbiguous: false)
        }

        let meaningfulResults = allNormalized.filter { $0.confidence >= minimumConfidence }

        var evidence: [AIPhotoCategory: [Float]] = [:]

        for result in meaningfulResults {
            let label = result.label
            let confidence = result.confidence

            if isNature(label)   { addEvidence(.nature, confidence, &evidence) }
            if isVehicle(label)  { addEvidence(.vehicle, confidence, &evidence) }
            if isAnimal(label)   { addEvidence(.animals, confidence, &evidence) }
            if isFood(label)     { addEvidence(.food, confidence, &evidence) }
            if isPerson(label)   { addEvidence(.people, confidence, &evidence) }
            if isIndoor(label)   { addEvidence(.indoor, confidence, &evidence) }
            if isDevice(label)   { addEvidence(.device, confidence, &evidence) }
        }

        // Animal detection booster: if the dedicated animal detector found a cat or dog,
        // inject strong animal evidence (0.95).
        if animalDetected {
            addEvidence(.animals, 0.95, &evidence)
        }

        // Face-detection gate: if Vision's scene classifier says "people" but no actual
        // human faces were detected, discard the people evidence entirely (prevents statues/paintings).
        if faceCount == 0 {
            evidence.removeValue(forKey: .people)
        }

        guard !evidence.isEmpty else {
            return Result(category: .others, confidence: 0, isAmbiguous: false)
        }

        var scores = evidence.mapValues(combinedConfidence)

        // Universal Cluster Compounding:
        // Boost any category with 3+ distinct signals (>= 0.03) and combined score >= 0.20
        // to its threshold so it can qualify.
        let clusterMinScore: Float = 0.20
        let clusterMinCount = 3

        for category in priorityOrder {
            guard let categoryEvidence = evidence[category],
                  categoryEvidence.count >= clusterMinCount else { continue }
            let currentScore = scores[category] ?? 0
            if currentScore >= clusterMinScore {
                let threshold = categoryThresholds[category] ?? minimumConfidence
                scores[category] = max(currentScore, threshold)
            }
        }

        let validScores = scores.filter { category, value in
            value >= (categoryThresholds[category] ?? minimumConfidence)
        }

        guard let topEntry = validScores.max(by: { $0.value < $1.value }) else {
            let topAny = scores.max(by: { $0.value < $1.value })
            return Result(category: .others, confidence: Double(topAny?.value ?? 0), isAmbiguous: true)
        }

        let contenders = validScores.filter { $0.value >= topEntry.value - tieBreakEpsilon }
        if contenders.count > 1 {
            for category in priorityOrder where contenders[category] != nil {
                let isAmb = contenders.count > 1
                return Result(category: category, confidence: Double(contenders[category] ?? topEntry.value), isAmbiguous: isAmb)
            }
        }

        return Result(category: topEntry.key, confidence: Double(topEntry.value), isAmbiguous: false)
    }

    // MARK: - Score Handling

    nonisolated private static func addEvidence(
        _ category: AIPhotoCategory,
        _ confidence: Float,
        _ evidence: inout [AIPhotoCategory: [Float]]
    ) {
        evidence[category, default: []].append(confidence)
    }

    nonisolated private static func combinedConfidence(_ confidences: [Float]) -> Float {
        let combined = confidences.reduce(Float(1.0)) { acc, c in
            acc * (1.0 - c)
        }
        return 1.0 - combined
    }

    nonisolated private static func strongestConfidence(
        for labels: Set<String>,
        in results: [VisionLabelResult]
    ) -> Float {
        results
            .filter { labels.contains($0.label) }
            .map(\.confidence)
            .max() ?? 0
    }

    // MARK: - Smart Gate Clues

    nonisolated static let animalClueKeywords: Set<String> = [
        "animal", "animals", "dog", "cat", "bird", "fish", "horse", "cow",
        "elephant", "lion", "tiger", "bear", "deer", "rabbit",
        "monkey", "panda", "giraffe", "zebra", "snake", "turtle",
        "frog", "butterfly", "spider", "insect", "dolphin",
        "whale", "penguin", "parrot", "eagle", "pet", "puppy",
        "kitten", "livestock", "wildlife", "reptile", "aquatic_animal",
        "mammal", "poultry", "canine", "feline",
        "retriever", "golden_retriever", "labrador_retriever",
        "shepherd", "german_shepherd", "australian_shepherd", "sheepdog",
        "terrier", "jack_russell_terrier",
        "hound", "greyhound", "irish_wolfhound",
        "bulldog", "poodle", "pug", "corgi", "husky", "chihuahua", "spaniel",
        "coyote_wolf", "fox", "prairie_dog",
        "adult_cat", "bobcat", "cheetah", "leopard", "pig", "goat", "camel",
        "kangaroo", "otter", "raccoon", "skunk", "squirrel", "hedgehog",
        "rodent", "pigeon", "hummingbird", "clownfish", "goldfish", "angelfish",
        "lionfish", "puffer_fish", "sunfish", "swordfish", "shark", "seahorse",
        "seal", "sealion", "jellyfish", "starfish", "crab", "lobster", "shellfish",
        "lizard", "monitor_lizard", "alligator_crocodile", "rattlesnake", "snake_other",
        "toad", "tortoise", "caterpillar", "dragonfly", "ladybug", "moth", "ant",
        "bee", "worm",
        "pitbull", "basset", "mastiff", "beagle", "dalmatian", "ridgeback",
        "doberman", "rottweiler", "dachshund", "marsupial"
    ]

    nonisolated static let peopleClueKeywords: Set<String> = [
        "people", "person", "adult", "child", "baby", "teen", "face", "portrait"
    ]

    // MARK: - Taxonomies

    nonisolated static func isNature(_ label: String) -> Bool {
        let labels: Set<String> = [
            "tree", "forest", "mountain", "hill", "lake", "river",
            "ocean", "beach", "waterfall", "flower", "garden", "grass",
            "foliage", "plant", "vegetation", "desert", "island",
            "glacier", "volcano", "sunset_sunrise", "blue_sky", "sky",
            "land", "cloudy", "shrub",
            "waterscape", "seascape", "landscape", "cliff", "canyon",
            "rainforest", "jungle", "swamp", "wetland", "tundra",
            "aurora", "fireworks", "sunrise", "sunset", "sunrise_sunset",
            "storm", "fog", "mist", "snow", "ice", "frost",
            "dew", "rain", "lightning", "cave", "trail", "path",
            "nature", "wilderness", "scenery", "panorama",
            "night_sky", "moon", "celestial_body", "sun", "daytime",
            "haze", "branch", "park", "fire", "flame", "pyrotechnics"
        ]
        return labels.contains(label)
    }

    nonisolated static func isVehicle(_ label: String) -> Bool {
        let labels: Set<String> = [
            "car", "automobile", "motorcycle", "bicycle", "bus",
            "truck", "van", "suv", "scooter", "train", "train_real",
            "airplane", "aircraft", "helicopter", "boat", "speedboat",
            "sailboat", "yacht", "motorhome", "rickshaw",
            "vehicle", "wheel", "tire", "rim",
            "road", "highway", "street", "parking", "parking_lot",
            "bridge", "dock", "port", "runway", "station",
            "cockpit", "engine", "propeller", "exhaust", "bumper",
            "windshield", "traffic"
        ]
        return labels.contains(label)
    }

    nonisolated static func isAnimal(_ label: String) -> Bool {
        return animalClueKeywords.contains(label)
    }

    nonisolated static func isFood(_ label: String) -> Bool {
        let labels: Set<String> = [
            "food", "pizza", "burger", "hamburger", "sandwich", "pasta",
            "rice", "bread", "cake", "cookie", "donut", "fruit",
            "vegetable", "salad", "sushi", "curry", "biryani", "naan",
            "samosa", "fries", "chocolate", "ice_cream", "coffee",
            "tea_drink",
            "baked_goods", "white_bread", "croissant", "pastry", "pie", "tart",
            "pancake", "waffle", "cupcake", "cheesecake", "birthday_cake",
            "wedding_cake", "fruitcake", "cake_regular", "gingerbread",
            "chocolate_chip", "dessert", "frozen_dessert", "candy", "candy_cane",
            "candy_other", "sweet", "sugar_cube",
            "meat", "steak", "beef", "pork", "meatball", "hotdog", "taco",
            "stir_fry", "soup", "pierogi", "antipasti", "pepperoni",
            "grilled_chicken", "fried_chicken", "poultry", "seafood", "shellfish_prepared",
            "cheese", "egg", "fried_egg", "scrambled_eggs", "butter", "cereal", "oatmeal",
            "apple", "banana", "oranges", "citrus_fruit", "grape", "grapefruit",
            "berry", "blackberry", "blueberry", "raspberry", "strawberry",
            "cranberry", "watermelon", "melon", "cantaloupe", "passionfruit",
            "pineapple", "starfruit", "coconut", "potato", "tomato", "onion",
            "garlic", "bell_pepper", "pepper_veggie", "jalapeno", "eggplant",
            "radish", "green_beans", "bean", "grain", "nut", "peanut", "chestnut",
            "seed", "sunflower_seeds", "herb", "spice",
            "coffee_bean", "bubble_tea", "milkshake", "smoothie", "juice",
            "soda", "cocktail", "beer", "wine", "red_wine", "white_wine",
            "sparkling_wine", "wine_bottle", "liquor",
            "dish", "meal", "snack", "dining", "tableware", "plate", "bowl", "cup"
        ]
        return labels.contains(label)
    }

    nonisolated static func isPerson(_ label: String) -> Bool {
        return peopleClueKeywords.contains(label)
    }

    nonisolated static func isIndoor(_ label: String) -> Bool {
        let labels: Set<String> = [
            "indoor", "interior", "room", "bedroom", "living_room",
            "kitchen", "bathroom", "office_indoor", "hallway",
            "staircase_indoor", "furniture", "sofa", "dining_table",
            "restaurant_indoor", "library_indoor", "classroom",
            "gym_indoor", "warehouse_indoor",
            "mall", "supermarket", "hospital", "museum",
            "theater", "office", "workspace",
            "basement", "attic", "corridor",
            "church", "cathedral", "temple", "mosque", "airport_indoor",
            "interior_room", "nightclub", "bar"
        ]
        return labels.contains(label)
    }

    nonisolated static func isDevice(_ label: String) -> Bool {
        let labels: Set<String> = [
            "laptop", "computer", "desktop_computer",
            "television", "smartphone", "mobile_phone", "tablet",
            "camera_device", "camera", "computer_mouse", "mouse",
            "headphones", "earbuds", "smartwatch", "game_console",
            "speaker_device", "speakers_music", "printer", "router", "webcam",
            "smart_speaker", "drone", "drone_machine",
            "computer_monitor", "computer_keyboard", "computer_tower",
            "consumer_electronics", "machine", "appliance", "circuit_board",
            "diskette", "phone", "payphone", "microphone", "megaphone",
            "watch", "stopwatch",
            "cord", "cable", "wire", "charger", "adapter", "usb"
        ]
        return labels.contains(label)
    }
}

extension AIPhotoCategory {
    /// Persistent category identifier stored in the PhotoManagerKit AI cache.
    var pmkCacheID: String { "ai_\(rawValue)" }

    init?(pmkCacheID: String) {
        guard pmkCacheID.hasPrefix("ai_") else { return nil }
        self.init(rawValue: String(pmkCacheID.dropFirst(3)))
    }
}
