import SwiftUI
import UIKit

/// Lớp điều hướng tương thích xuyên suốt từ iOS 15.0 đến iOS 26.6+
public struct AdaptiveNavigation<Content: View>: View {
    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                content()
            }
        } else {
            NavigationView {
                content()
            }
            .navigationViewStyle(.stack)
        }
    }
}

/// Dòng hiển thị Cặp Khóa – Giá trị chuẩn iOS 15+ (thay thế LabeledContent chỉ có từ iOS 16+)
public struct InfoRow: View {
    public let title: String
    public let value: String
    public var monospaced: Bool = false
    public var valueColor: Color = .primary

    public init(
        title: String,
        value: String,
        monospaced: Bool = false,
        valueColor: Color = .primary
    ) {
        self.title = title
        self.value = value
        self.monospaced = monospaced
        self.valueColor = valueColor
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .foregroundColor(.secondary)
                .font(.subheadline)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .system(.footnote, design: .monospaced) : .subheadline)
                .foregroundColor(valueColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 2)
    }
}

public enum BadgeTone {
    case neutral
    case success
    case warning
    case danger
}

public struct StatusBadge: View {
    public let text: String
    public let tone: BadgeTone

    public init(_ text: String, tone: BadgeTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .danger: return .red
        }
    }

    public var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(foreground.opacity(0.15))
            .foregroundColor(foreground)
            .clipShape(Capsule())
    }
}

/// UIActivityViewController tương thích iOS 15.0+ (thay cho ShareLink của iOS 16+)
public struct ShareSheet: UIViewControllerRepresentable {
    public let activityItems: [Any]

    public init(activityItems: [Any]) {
        self.activityItems = activityItems
    }

    public func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    public func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Nhận diện thông tin phiên bản iOS & phần cứng thực tế của thiết bị
public enum DeviceEnvironment {
    public static var iosVersionString: String {
        UIDevice.current.systemVersion
    }

    public static var majorIOSVersion: Int {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    public static var requiresDeveloperModeToggle: Bool {
        majorIOSVersion >= 16
    }

    public static var deviceModelIdentifier: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        let mirror = Mirror(reflecting: sysinfo.machine)
        let identifier = mirror.children.reduce("") { acc, elem in
            guard let v = elem.value as? Int8, v != 0 else { return acc }
            return acc + String(UnicodeScalar(UInt8(v)))
        }
        return identifier.isEmpty ? UIDevice.current.model : identifier
    }

    public static func isMinimumOSMet(_ requiredVersion: String?) -> Bool {
        guard let req = requiredVersion, !req.isEmpty else { return true }
        let currentParts = iosVersionString.split(separator: ".").compactMap { Int($0) }
        let reqParts = req.split(separator: ".").compactMap { Int($0) }
        let count = max(currentParts.count, reqParts.count)
        for idx in 0..<count {
            let c = idx < currentParts.count ? currentParts[idx] : 0
            let r = idx < reqParts.count ? reqParts[idx] : 0
            if c > r { return true }
            if c < r { return false }
        }
        return true
    }

    public static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: max(0, bytes))
    }
}
