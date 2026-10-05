import BackgroundTasks
import SwiftData
import SwiftUI

@main
struct MediaSyncApp: App {
    private let container: ModelContainer
    @State private var state: AppState
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let container = try! ModelContainer(for: MediaItem.self)
        self.container = container
        let state = AppState(container: container)
        _state = State(initialValue: state)

        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppState.refreshTaskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            Task { @MainActor in state.handleBackgroundRefresh(task) }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(state)
                .modelContainer(container)
                .task { await state.syncNow() }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active: Task { await state.syncNow() }
                    case .background: state.scheduleBackgroundRefresh()
                    default: break
                    }
                }
        }
    }
}
