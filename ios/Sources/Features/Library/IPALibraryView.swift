import SwiftUI
import UIKit

/// Màn hình 3: Thư viện IPA (Quản lý IPA gốc & IPA đã ký)
struct IPALibraryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText: String = ""

    private var filteredImported: [IPAPackageItem] {
        appState.packages.filter { pkg in
            !pkg.isSignedOutput && matchesQuery(pkg)
        }
    }

    private var filteredSigned: [IPAPackageItem] {
        appState.packages.filter { pkg in
            pkg.isSignedOutput && matchesQuery(pkg)
        }
    }

    private func matchesQuery(_ pkg: IPAPackageItem) -> Bool {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty { return true }
        return pkg.effectiveTitle.lowercased().contains(q)
            || pkg.effectiveBundleId.lowercased().contains(q)
            || pkg.fileName.lowercased().contains(q)
    }

    var body: some View {
        AdaptiveNavigation {
            List {
                Section(header: Text("IPA gốc đã nhập (\(filteredImported.count))")) {
                    if filteredImported.isEmpty {
                        Text("Không có gói IPA gốc nào khớp tìm kiếm.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(filteredImported) { pkg in
                            NavigationLink(destination: AppDetailView(packageItem: pkg)) {
                                PackageRowView(pkg: pkg)
                            }
                        }
                        .onDelete { offsets in
                            let targets = offsets.map { filteredImported[$0] }
                            targets.forEach { appState.deletePackage($0) }
                        }
                    }
                }

                Section(header: Text("IPA đã ký số (\(filteredSigned.count))")) {
                    if filteredSigned.isEmpty {
                        Text("Chưa có gói IPA nào đã ký.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(filteredSigned) { pkg in
                            NavigationLink(destination: AppDetailView(packageItem: pkg)) {
                                PackageRowView(pkg: pkg)
                            }
                        }
                        .onDelete { offsets in
                            let targets = offsets.map { filteredSigned[$0] }
                            targets.forEach { appState.deletePackage($0) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, prompt: "Tìm tên ứng dụng hoặc Bundle ID")
            .navigationTitle("Thư viện IPA")
        }
    }
}

private struct PackageRowView: View {
    let pkg: IPAPackageItem

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.14))
                    .frame(width: 48, height: 48)

                if let iconData = pkg.metadata?.iconPNGData,
                   let uiImg = UIImage(data: iconData) {
                    Image(uiImage: uiImg)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Text(String(pkg.effectiveTitle.prefix(1)).uppercased())
                        .font(.headline)
                        .foregroundColor(.accentColor)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(pkg.effectiveTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(pkg.effectiveBundleId)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Text("\(DeviceEnvironment.formatBytes(pkg.fileSize)) • \(pkg.isSignedOutput ? "Đã ký" : "Gốc")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
