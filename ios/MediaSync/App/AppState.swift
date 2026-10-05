import BackgroundTasks
import Network
import Observation
import SwiftData
import SwiftUI

@Observable @MainActor
final class AppState {
    var isSignedIn = false
    var isSyncing = false
    var lastSync: Date?
    var errorMessage: String?
    var isOnline = true

    private let container: ModelContainer
    private let monitor = NWPathMonitor()
    static let refreshTaskID = "com.example.mediasync.refresh"

    init(container: ModelContainer) {
        self.container = container
        Task { self.isSignedIn = await APIClient.shared.hasSession }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = path.status == .satisfied
                if wasOffline && self.isOnline { await self.syncNow() }   // flush queue when back online
            }
        }
        monitor.start(queue: DispatchQueue(label: "net.monitor"))
    }

    func signIn(email: String, password: String, register: Bool) async {
        do {
            if register { try await APIClient.shared.register(email: email, password: password) }
            else { try await APIClient.shared.login(email: email, password: password) }
            isSignedIn = true
            errorMessage = nil
            Haptics.success()
            await syncNow()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func signOut() async {
        await APIClient.shared.logout()
        isSignedIn = false
    }

    func syncNow() async {
        guard isSignedIn, isOnline, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            try await SyncEngine(modelContainer: container).sync()
            lastSync = .now
            errorMessage = nil
        } catch APIError.unauthorized {
            isSignedIn = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func download(_ item: MediaItem) async {
        do { try await SyncEngine(modelContainer: container).ensureLocal(item.id) }
        catch { errorMessage = error.localizedDescription }
    }

    // MARK: Background refresh

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()                                  // chain the next run
        let work = Task { await syncNow(); task.setTaskCompleted(success: errorMessage == nil) }
        task.expirationHandler = { work.cancel() }
    }
}
