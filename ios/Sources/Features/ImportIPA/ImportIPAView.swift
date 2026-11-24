import SwiftUI
import UniformTypeIdentifiers

/// Màn hình 2: Nhập IPA (Từ Files / iCloud Drive / URL trực tiếp)
struct ImportIPAView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ImportIPAInnerView(downloader: appState.downloader)
    }
}

private struct ImportIPAInnerView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var downloader: DownloadManager
    @State private var urlInput: String = ""
    @State private var showingPicker = false

    private var allowedIPATypes: [UTType] {
        var list: [UTType] = [.data, .archive, .zip]
        if let ipa = UTType(filenameExtension: "ipa") {
            list.insert(ipa, at: 0)
        }
        return list
    }

    var body: some View {
        AdaptiveNavigation {
            List {
                Section(
                    header: Text("Nhập từ iPhone & iCloud Drive"),
                    footer: Text("Hỗ trợ tệp IPA dung lượng lớn nhiều GB. Ứng dụng kiểm tra chữ ký nén PK ngay sau khi sao chép vào vùng Sandbox.")
                ) {
                    Button {
                        showingPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "doc.zipper")
                                .foregroundColor(.accentColor)
                            Text("Chọn tệp .ipa từ Tệp (Files)")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }

                Section(
                    header: Text("Tải trực tiếp từ liên kết URL"),
                    footer: Text("Chỉ hỗ trợ liên kết tải trực tiếp HTTP/HTTPS trỏ tới tệp .ipa.")
                ) {
                    TextField("https://example.com/app.ipa", text: $urlInput)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .font(.system(.subheadline, design: .monospaced))

                    Button {
                        do {
                            try downloader.startDownload(from: urlInput)
                            urlInput = ""
                        } catch {
                            appState.alertMessage = "Liên kết URL không hợp lệ. Vui lòng nhập đầy đủ http:// hoặc https://."
                        }
                    } label: {
                        Label("Bắt đầu tải xuống", systemImage: "arrow.down.circle.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                Section(header: Text("Tiến trình tải xuống (\(downloader.tasks.count))")) {
                    if downloader.tasks.isEmpty {
                        Text("Chưa có phiên tải xuống nào đang chạy.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(downloader.tasks) { task in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(task.sourceURL.lastPathComponent.isEmpty ? task.sourceURL.absoluteString : task.sourceURL.lastPathComponent)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)

                                if !task.isFinished && task.expectedBytes > 0 {
                                    ProgressView(value: task.fractionCompleted)
                                }

                                HStack {
                                    Text(task.errorMessage ?? task.statusText)
                                        .font(.caption)
                                        .foregroundColor(task.errorMessage == nil ? .secondary : .red)
                                    Spacer()
                                    if !task.isFinished {
                                        Button("Hủy") {
                                            downloader.cancelDownload(id: task.id)
                                        }
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.red)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        if downloader.tasks.contains(where: { $0.isFinished }) {
                            Button("Xóa các mục đã kết thúc") {
                                downloader.removeFinishedTasks()
                            }
                            .font(.footnote)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Nhập IPA")
            .fileImporter(
                isPresented: $showingPicker,
                allowedContentTypes: allowedIPATypes,
                allowsMultipleSelection: false
            ) { res in
                if case .success(let urls) = res, let first = urls.first {
                    appState.importIPAFromURL(first)
                }
            }
        }
    }
}
