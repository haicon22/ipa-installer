import SwiftUI

struct MainTabView: View {
    @State private var selectedTab: Int = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(selectedTab: $selectedTab)
                .tabItem {
                    Label("Trang chủ", systemImage: "house.fill")
                }
                .tag(0)

            ImportIPAView()
                .tabItem {
                    Label("Nhập IPA", systemImage: "square.and.arrow.down.fill")
                }
                .tag(1)

            IPALibraryView()
                .tabItem {
                    Label("Thư viện", systemImage: "archivebox.fill")
                }
                .tag(2)

            CertificateManagerView()
                .tabItem {
                    Label("Chứng chỉ", systemImage: "checkmark.shield.fill")
                }
                .tag(3)

            SystemSettingsView()
                .tabItem {
                    Label("Thiết lập", systemImage: "gearshape.fill")
                }
                .tag(4)
        }
    }
}
