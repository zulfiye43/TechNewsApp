import SwiftUI
import UserNotifications

// MARK: - Benachrichtigungs-Scheduler

enum NotificationScheduler {
    static func requestAndSchedule(pushMinutes: Int) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            schedule(pushMinutes: pushMinutes)
        }
    }

    static func schedule(pushMinutes: Int) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["daily-digest"])

        let content = UNMutableNotificationContent()
        content.title = "Dein TechDigest ist da 🎙️"
        content.body = "Neue Folge + frische News warten auf dich."
        content.sound = .default

        var components = DateComponents()
        components.hour = pushMinutes / 60
        components.minute = pushMinutes % 60

        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: "daily-digest", content: content, trigger: trigger)
        center.add(request)
    }
}

// MARK: - App Entry Point

@main
struct TechDigestApp: App {
    @StateObject private var store = DigestStore()
    @StateObject private var savedStore = SavedStore()
    @StateObject private var readStore = ReadStore()
    @StateObject private var speech = SpeechManager()

    // Standard: 12:00 Uhr (720 Minuten)
    @AppStorage("pushMinutes") private var pushMinutes = 720

    var body: some Scene {
        WindowGroup {
            DigestView()
                .environmentObject(store)
                .environmentObject(savedStore)
                .environmentObject(readStore)
                .environmentObject(speech)
                .onAppear {
                    NotificationScheduler.requestAndSchedule(pushMinutes: pushMinutes)
                }
        }
    }
}
