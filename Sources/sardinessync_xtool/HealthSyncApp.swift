import SwiftUI

@main
struct HealthSyncApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Register UserDefaults defaults so unset keys return the correct
        // initial value *and* so 0 (midnight) is a legal stored value
        // distinguishable from "never set". Without this, code that reads
        // `UserDefaults.standard.integer(forKey:)` on an unset key gets 0
        // back and can't tell it apart from a real midnight selection.
        UserDefaults.standard.register(defaults: [
            "bedtimeReminderHour": 21,
            "bedtimeReminderMinute": 0,
            "syncHour": 20,
            "syncMinute": 0,
            "userID": 1,
            "notificationsEnabled": true,
            "flareScoreTrendThreshold": 3.0,
        ])

        // BGTaskScheduler.register(...) must be called before
        // application(_:didFinishLaunchingWithOptions:) returns.
        // App.init runs inside that call, so this is the right place.
        BackgroundSyncTask.register()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                // Always have a pending refresh request queued when we leave foreground.
                BackgroundSyncTask.scheduleNext()
            }
        }
    }
}
