# PhotoManagerKit & Demo App

A high-performance, battery-conscious iOS & macOS Photo Library Manager built with Swift and SwiftUI.

## Features

- ⚡️ **Instant Zero-IPC Storage Footprint (< 50ms)**: Fast resolution using PhotoKit metadata estimation before any disk reads.
- 🎨 **Top Storage Overview Card**: Multi-color proportional storage breakdown bar (Photos, Live Photos split into Still Image vs Motion Playback, and Videos).
- 🔄 **Two Segment Experience**: Segmented switch between `[ Photos | Videos ]`.
- 🔍 **Top Hashing & Dedupe Cards**:
  - **Photos**: Duplicate Photos & Similar Photos cards displayed at the top with live circular progress rings and percent scanning indicators.
  - **Videos**: Duplicate Videos & Similar Videos cards with live progress rings.
- 📁 **Smart System Albums**:
  - Screenshots, Selfies (`smartAlbumSelfPortraits`), Live Photos, Panoramas, Favorites, Bursts.
  - Screen Recordings & All Videos.
- 📏 **Size & Age Filter Cards**:
  - **Large Photos** (> 10 MB)
  - **Old Photos** (> 3 Years Old)
  - **Large Videos** (> 200 MB)
- 💾 **Multi-Tier Persistent Caching**:
  - Saves file sizes, 64-bit dHashes, video perceptual fingerprints, and dedupe clusters to `library_cache.json`.
  - Debounced async persistence ensures no UI hitching or thermal throttling.
- 🛡️ **Zero Thermal Impact**:
  - Max 3 concurrent background workers.
  - Periodic task yielding and autorelease pools.
  - Zero iCloud asset byte downloads (local metadata & thumbnail cached only).
- 🗑️ **Safe PhotoKit Deletion**:
  - Native PhotoKit confirmation dialog.
  - Re-evaluates library stats and updates caches seamlessly.

## Quick Start

### Run Tests
```bash
swift test
```

### Run Demo on Simulator
```bash
./launch-demo.sh
```
Or open `Demo/Demo.xcodeproj` in Xcode and press **Cmd + R**.
