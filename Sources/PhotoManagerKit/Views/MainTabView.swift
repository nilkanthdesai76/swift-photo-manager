import SwiftUI

/// Bottom tab controller uniting Storage/Clean and AI/Timeline Explorer.
@MainActor
public struct MainTabView: View {
    @StateObject private var coordinator: PhotoManagerCoordinator
    @State private var selectedTab: Int = 0
    
    public init(initialTab: Int = 0) {
        self._coordinator = StateObject(wrappedValue: PhotoManagerCoordinator())
        self._selectedTab = State(initialValue: initialTab)
    }
    
    public init(coordinator: PhotoManagerCoordinator, initialTab: Int = 0) {
        self._coordinator = StateObject(wrappedValue: coordinator)
        self._selectedTab = State(initialValue: initialTab)
    }
    
    public var body: some View {
        TabView(selection: $selectedTab) {
            // Tab 1: Storage & Deduplication Manager
            PhotoManagerDashboardView(coordinator: coordinator)
                .tabItem {
                    Label("Storage", systemImage: "internaldrive.fill")
                }
                .tag(0)
            
            // Tab 2: AI Categories, Albums & Year-Month Timeline
            GalleryExplorerView(coordinator: coordinator)
                .tabItem {
                    Label("AI & Timeline", systemImage: "sparkles.rectangle.stack.fill")
                }
                .tag(1)
        }
        .task {
            await coordinator.start()
        }
    }
}
