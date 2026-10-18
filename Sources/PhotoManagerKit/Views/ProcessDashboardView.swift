import SwiftUI

/// Process control dashboard: shows cache contents and provides controls to clear caches
/// (current + previous sessions), tune similarity strictness, re-run individual pipeline
/// processes, re-group without re-hashing, and cancel running processes.
public struct ProcessDashboardView: View {
    @Bindable public var coordinator: PhotoManagerCoordinator
    
    @State private var stats: (
        sizes: Int,
        photoHashes: Int,
        videoFingerprints: Int,
        aiCategories: Int,
        blurryPhotos: Int,
        groups: Int
    ) = (0, 0, 0, 0, 0, 0)
    @State private var runningTask: String?
    @State private var showClearAllConfirmation = false
    @State private var statusMessage: String?
    
    public init(coordinator: PhotoManagerCoordinator) {
        self.coordinator = coordinator
    }
    
    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // MARK: Cache Contents
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("Cache Contents")
                        
                        VStack(spacing: 0) {
                            statRow(label: "Size records", count: stats.sizes)
                            Divider().padding(.leading, 16)
                            statRow(label: "Photo hashes", count: stats.photoHashes)
                            Divider().padding(.leading, 16)
                            statRow(label: "Video fingerprints", count: stats.videoFingerprints)
                            Divider().padding(.leading, 16)
                            statRow(label: "AI categories", count: stats.aiCategories)
                            Divider().padding(.leading, 16)
                            statRow(label: "Blurry photos", count: stats.blurryPhotos)
                            Divider().padding(.leading, 16)
                            statRow(label: "Dedupe groups", count: stats.groups)
                        }
                        .background(Color.platformSecondaryBackground)
                        .cornerRadius(12)
                    }
                    
                    // MARK: Similarity Settings
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("Similarity Strictness")
                        
                        VStack(spacing: 8) {
                            Picker("Similarity", selection: $coordinator.similarityPreset) {
                                ForEach(SimilarityPreset.allCases) { preset in
                                    Text(preset.rawValue).tag(preset)
                                }
                            }
                            .pickerStyle(.segmented)
                            
                            Text(strictnessDescription(coordinator.similarityPreset))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(12)
                        .background(Color.platformSecondaryBackground)
                        .cornerRadius(12)
                    }
                    
                    // MARK: Re-run Processes
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("Re-run Process")
                        
                        VStack(spacing: 0) {
                            actionRow(
                                icon: "photo.stack",
                                color: .blue,
                                title: "Photo Hashing & Duplicates",
                                subtitle: "Clears photo hash + blur caches, re-scans",
                                taskKey: "photo"
                            ) {
                                coordinator.rerunPhotoDedupe()
                            }
                            Divider().padding(.leading, 54)
                            actionRow(
                                icon: "video.stack",
                                color: .orange,
                                title: "Video Duplicates",
                                subtitle: "Clears video fingerprints, re-scans",
                                taskKey: "video"
                            ) {
                                coordinator.rerunVideoDedupe()
                            }
                            Divider().padding(.leading, 54)
                            actionRow(
                                icon: "arrow.triangle.merge",
                                color: .green,
                                title: "Re-group Only (keeps hashes)",
                                subtitle: "Fast: skips hashing, re-clusters both photos & videos",
                                taskKey: "regroup"
                            ) {
                                coordinator.regroupDuplicates()
                            }
                            Divider().padding(.leading, 54)
                            actionRow(
                                icon: "externaldrive.fill.badge.checkmark",
                                color: .indigo,
                                title: "Size Fetch",
                                subtitle: "Clears size index, re-resolves all sizes",
                                taskKey: "sizes"
                            ) {
                                coordinator.rerunSizeFetch()
                            }
                            Divider().padding(.leading, 54)
                            actionRow(
                                icon: "sparkles",
                                color: .purple,
                                title: "AI Categories",
                                subtitle: "Clears AI cache, re-classifies photos",
                                taskKey: "ai"
                            ) {
                                coordinator.rerunAICategories()
                            }
                        }
                        .background(Color.platformSecondaryBackground)
                        .cornerRadius(12)
                        
                        if runningTask != nil {
                            Button {
                                if let key = runningTask {
                                    coordinator.cancelProcess(key)
                                    runningTask = nil
                                    flash("Process cancelled")
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "xmark.octagon.fill")
                                    Text("Cancel Running Process")
                                }
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.red)
                                .frame(maxWidth: .infinity)
                                .padding(10)
                                .background(Color.red.opacity(0.1))
                                .cornerRadius(10)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    
                    // MARK: Danger Zone
                    VStack(alignment: .leading, spacing: 10) {
                        sectionHeader("Danger Zone")
                        
                        Button {
                            showClearAllConfirmation = true
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 18))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color.red)
                                    .cornerRadius(8)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Clear All Caches")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.red)
                                    Text("Removes this session and all previous session data")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(12)
                            .background(Color.platformSecondaryBackground)
                            .cornerRadius(12)
                        }
                        .buttonStyle(.plain)
                        .disabled(runningTask != nil)
                    }
                    
                    if let statusMessage = statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                }
                .padding(16)
            }
            .background(Color.platformGroupedBackground)
            .navigationTitle("Processes")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .task {
                await refreshStats()
            }
            .refreshable {
                await refreshStats()
            }
            .onChange(of: coordinator.similarityPreset) {
                flash("Strictness updated — applies to the next scan")
            }
            .alert("Clear All Caches?", isPresented: $showClearAllConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear Everything", role: .destructive) {
                    Task {
                        await coordinator.clearAllCaches()
                        await refreshStats()
                        flash("All caches cleared")
                    }
                }
            } message: {
                Text("This deletes size records, hashes, fingerprints, dedupe groups, blur flags, and AI categories from this device.")
            }
        }
    }
    
    private func strictnessDescription(_ preset: SimilarityPreset) -> String {
        let hours = String(format: "%.0f", preset.timeWindow / 3600)
        switch preset {
        case .strict:
            return "Fewer, more accurate matches (max \(preset.hammingThreshold) hash bits, \(hours)h window)."
        case .balanced:
            return "Default matching (max \(preset.hammingThreshold) hash bits, \(hours)h window)."
        case .relaxed:
            return "More matches, including loosely similar shots (max \(preset.hammingThreshold) hash bits, \(hours)h window)."
        }
    }
    
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote)
            .fontWeight(.bold)
            .foregroundColor(.secondary)
            .textCase(.uppercase)
            .padding(.horizontal, 4)
    }
    
    private func statRow(label: String, count: Int) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.primary)
            Spacer()
            Text("\(count)")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
    
    private func actionRow(
        icon: String,
        color: Color,
        title: String,
        subtitle: String,
        taskKey: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            guard runningTask == nil else { return }
            runningTask = taskKey
            action()
            // The coordinator unregisters the task when done; poll briefly to clear the spinner.
            Task {
                while coordinator.isProcessRunning(taskKey) {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                if runningTask == taskKey {
                    runningTask = nil
                    await refreshStats()
                    flash("\(title) complete")
                }
            }
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(color.opacity(0.15))
                        .frame(width: 36, height: 36)
                    if runningTask == taskKey {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(color)
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.clockwise")
                    .font(.caption)
                    .foregroundColor(color)
            }
            .padding(12)
        }
        .buttonStyle(.plain)
        .disabled(runningTask != nil)
    }
    
    private func refreshStats() async {
        stats = await coordinator.cacheStats()
    }
    
    private func flash(_ message: String) {
        statusMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if statusMessage == message { statusMessage = nil }
        }
    }
}
