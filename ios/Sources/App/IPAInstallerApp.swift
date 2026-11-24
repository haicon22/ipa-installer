import SwiftUI

@main
struct IPAInstallerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .preferredColorScheme(appState.preferredColorScheme)
                .onOpenURL { incomingURL in
                    appState.importIPAFromURL(incomingURL)
                }
                .alert(
                    "Thông báo",
                    isPresented: Binding(
                        get: { appState.alertMessage != nil },
                        set: { if !$0 { appState.alertMessage = nil } }
                    )
                ) {
                    Button("Đã hiểu", role: .cancel) {
                        appState.alertMessage = nil
                    }
                } message: {
                    Text(appState.alertMessage ?? "")
                }
        }
    }
}
