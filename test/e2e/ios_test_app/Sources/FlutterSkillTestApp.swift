import SwiftUI
import FlutterSkill

@main
struct FlutterSkillTestApp: App {
    init() {
        // Start the bridge on launch
        FlutterSkillBridge.shared.start()
        print("[FlutterSkillTestApp] Bridge started on port 18118")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
