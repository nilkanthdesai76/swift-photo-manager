# PhotoKitManager (PhotoManagerKit)

A high-performance, battery-conscious Apple PhotoKit library manager, storage calculator, duplicate cleaner, and AI categorization engine built for iOS 17+ and macOS 14+ using Swift and SwiftUI.

[![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2017%2B%20%7C%20macOS%2014%2B-blue.svg)](https://developer.apple.com)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

---

## Key Highlights

- ⚡️ **Zero-IPC & Zero-Download Storage Sizing**: Uses fast PhotoKit Key-Value Coding (KVC) `fileSize` queries to determine exact asset sizes without downloading iCloud bytes or hitting thermal limits.
- 🧩 **Fine-Grained Swift Observation (`@Observable`)**: Powered by the modern Swift `@Observable` macro to ensure UI components only re-render when their specific slice of state changes—zero hitching or frame drops.
- 🔁 **Strictly Sequential Background Pipelines**: Background jobs run sequentially in detached utility tasks (`Size Fetching` ➔ `Photo Dedupe` ➔ `Video Dedupe` ➔ `AI Categorization`), keeping main thread interactions 100% fluid at 120 FPS.
- 🔍 **Perceptual Deduplication**:
  - **Photos**: 64-bit difference hashing (`dHash`) with Hamming distance clustering into Exact Duplicates and Similars.
  - **Videos**: Perceptual duration, aspect ratio, and multi-frame sample hashing.
- 🧠 **On-Device Vision AI Categorization**: Fast taxonomy classifier recognizing Vehicles, Animals, Nature, Food, Documents, Screenshots, and Indoor items via Apple Vision.
- 📁 **Smart System Collections & Timeline**:
  - Pre-scanned system collections: Screenshots, Selfies, Live Photos, Panoramas, Favorites, Bursts, Screen Recordings.
  - Size & age filters: Large Photos (> 10 MB), Old Photos (> 3 Years), Large Videos (> 200 MB).
  - Collapsible Year-Month archive timeline.
- 💾 **Multi-Tier Thread-Safe Actor Cache**: Caches sizes, hashes, and AI taxonomies to disk with debounced asynchronous persistence.
- 🗑️ **Safe PhotoKit Deletion**: Native deletion confirmation flow with automatic cache and UI recalculation.

---

## Installation

### Swift Package Manager (Xcode)

1. In Xcode, select **File > Add Package Dependencies...**
2. Enter the repository URL:
   ```
   https://github.com/nilkanthdesai76/swift-photo-manager.git
   ```
3. Select version rule (e.g. `Up to Next Major Version` from `1.0.0`).
4. Link `PhotoManagerKit` (or `PhotoKitManager`).

### `Package.swift` Dependency

Add the package dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/nilkanthdesai76/swift-photo-manager.git", from: "1.0.0")
]
```

Then add `PhotoKitManager` or `PhotoManagerKit` to your target dependencies:

```swift
.target(
    name: "MyApp",
    dependencies: [
        .product(name: "PhotoKitManager", package: "swift-photo-manager")
    ]
)
```

---

## Quick Start

### 1. Ready-Made Two-Tab Experience (`MainTabView`)

The library includes an all-in-one root tab interface combining the **Storage/Dedupe Dashboard** and the **AI & Timeline Explorer**:

```swift
import SwiftUI
import PhotoKitManager

@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
    }
}
```

### 2. Standalone Dashboard (`PhotoManagerDashboardView`)

```swift
import SwiftUI
import PhotoKitManager

struct StorageCleanerView: View {
    @State private var coordinator = PhotoManagerCoordinator()

    var body: some View {
        PhotoManagerDashboardView(coordinator: coordinator)
            .task {
                await coordinator.start()
            }
    }
}
```

### 3. Programmatic PhotoKit Deduplication & Sizing

```swift
import Photos
import PhotoKitManager

// Compute storage overview using PhotoKit KVC
let assets = PHAsset.fetchAssets(with: nil)
let overview = await StorageCalculator.computeOverview(from: assets)
print("Total storage used: \(overview.formattedTotalSize)")

// Run photo dedupe engine
let dedupeResult = await PhotoDedupeEngine.scanPhotoDedupe(
    assets: photoAssets,
    onProgress: { progress in
        print("Progress: \(progress.percentString)")
    }
)
print("Found \(dedupeResult.duplicates.count) duplicate groups and \(dedupeResult.similars.count) similar groups.")
```

---

## Requirements

- **iOS 17.0+** / **macOS 14.0+**
- **Swift 5.9+** / **Xcode 15+**
- App Info.plist Permissions:
  - `NSPhotoLibraryUsageDescription`
  - `NSPhotoLibraryAddUsageDescription`

---

## Local Development & Demo App

For local development and testing in the Simulator:
- Open `Demo/Demo.xcodeproj` in Xcode (points to the local Swift Package dependency).
- Or run `./launch-demo.sh` in Terminal to build, install, and launch on a booted iOS Simulator.
*(Note: `Demo/` is kept locally for development and is excluded from the published SPM package).*

---

## License

This package is released under the [MIT License](LICENSE).
