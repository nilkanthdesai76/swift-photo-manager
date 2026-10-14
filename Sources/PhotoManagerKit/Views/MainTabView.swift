import SwiftUI

/// Bottom tab controller uniting Storage/Clean and AI/Timeline Explorer.
@MainActor
public struct MainTabView: View {
    @State private var coordinator: PhotoManagerCoordinator
    @State private var selectedTab: Int = 0
    
    public init(initialTab: Int = 0) {
        self._coordinator = State(initialValue: PhotoManagerCoordinator())
        self._selectedTab = State(initialValue: initialTab)
    }
    
    public init(coordinator: PhotoManagerCoordinator, initialTab: Int = 0) {
        self._coordinator = State(initialValue: coordinator)
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
            
            // Tab 3: Process Dashboard — cache stats, clear all, re-run individual processes
            ProcessDashboardView(coordinator: coordinator)
                .tabItem {
                    Label("Processes", systemImage: "gearshape.arrow.triangle.2.circlepath")
                }
                .tag(2)
        }
        .task {
            await coordinator.start()
        }
    }
}
