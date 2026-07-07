import AppKit
import LLMUsageMonitorCore
import SwiftUI
import WebKit

@MainActor
final class DashboardWindowManager {
    private var windows: [UUID: NSWindowController] = [:]

    func open(profile: AccountProfile, onText: @escaping (String) -> Void) {
        if let existing = windows[profile.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let rootView = DashboardContainerView(profile: profile, onText: onText)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "\(profile.label) Usage"
        window.setContentSize(NSSize(width: 1120, height: 820))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false

        let controller = NSWindowController(window: window)
        windows[profile.id] = controller
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.windows[profile.id] = nil
            }
        }

        controller.showWindow(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct DashboardContainerView: View {
    let profile: AccountProfile
    let onText: (String) -> Void
    @State private var captureSignal = 0
    @State private var notice: DashboardNotice?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProviderLabel(text: profile.label, provider: profile.provider)
                    .font(.headline)

                Spacer()

                Button {
                    openInBrowser()
                } label: {
                    Label("Open in Browser", systemImage: "safari")
                }
                .help("Use this if Google sign-in fails in the app window")

                Button {
                    importBrowserTextFromClipboard()
                } label: {
                    Label("Import Browser Text", systemImage: "doc.on.clipboard")
                }
                .help("Copy dashboard page text from your browser, then import it here")

                Button {
                    captureSignal += 1
                } label: {
                    Label("Read Page", systemImage: "text.viewfinder")
                }
            }
            .padding(DS.Spacing.md)

            if let notice {
                DashboardNoticeView(notice: notice)
            }

            Divider()

            DashboardWebView(
                profile: profile,
                captureSignal: captureSignal,
                onText: onText,
                onNotice: { notice = $0 }
            )
        }
    }

    private func openInBrowser() {
        NSWorkspace.shared.open(profile.provider.dashboardURL)
        notice = DashboardNotice(
            message: "Opened the dashboard in your browser. After signing in there, press Command-A then Command-C on the dashboard page, then click Import Browser Text.",
            tone: .info
        )
    }

    private func importBrowserTextFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice = DashboardNotice(
                message: "Copy the dashboard page text from your browser first, then click Import Browser Text.",
                tone: .warning
            )
            return
        }

        onText(text)
        notice = DashboardNotice(
            message: "Imported dashboard text from the clipboard.",
            tone: .success
        )
    }
}

struct DashboardWebView: NSViewRepresentable {
    let profile: AccountProfile
    let captureSignal: Int
    let onText: (String) -> Void
    let onNotice: (DashboardNotice) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onText: onText, onNotice: onNotice)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WebDataStoreFactory.makeDataStore(for: profile)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.lastCaptureSignal = captureSignal
        webView.load(URLRequest(url: profile.provider.dashboardURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.lastCaptureSignal != captureSignal else {
            return
        }
        context.coordinator.lastCaptureSignal = captureSignal
        context.coordinator.captureText()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var lastCaptureSignal = 0
        private let onText: (String) -> Void
        private let onNotice: (DashboardNotice) -> Void

        init(onText: @escaping (String) -> Void, onNotice: @escaping (DashboardNotice) -> Void) {
            self.onText = onText
            self.onNotice = onNotice
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if let notice = DashboardLoginIssueDetector.notice(for: "", url: webView.url) {
                onNotice(notice)
            }

            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                captureText()
            }
        }

        func captureText() {
            webView?.evaluateJavaScript("document.body ? document.body.innerText : ''") { [onText] value, _ in
                guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return
                }
                if let notice = DashboardLoginIssueDetector.notice(for: text, url: self.webView?.url) {
                    self.onNotice(notice)
                    return
                }
                onText(text)
            }
        }
    }
}

struct DashboardNotice: Equatable {
    let message: String
    let tone: DashboardNoticeTone
}

enum DashboardNoticeTone {
    case info
    case warning
    case success
}

struct DashboardNoticeView: View {
    let notice: DashboardNotice

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: imageName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(color)
            Text(notice.message)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(color.opacity(0.12))
    }

    private var imageName: String {
        switch notice.tone {
        case .info:
            return "info.circle"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .success:
            return "checkmark.circle.fill"
        }
    }

    private var color: Color {
        switch notice.tone {
        case .info:
            return .blue
        case .warning:
            return .orange
        case .success:
            return .green
        }
    }
}

enum DashboardLoginIssueDetector {
    static func notice(for text: String, url: URL?) -> DashboardNotice? {
        if isGoogleURL(url) {
            return DashboardNotice(
                message: "Google sign-in is open inside the app window. If it fails, use Open in Browser, sign in there, press Command-A then Command-C on the dashboard page, and click Import Browser Text.",
                tone: .warning
            )
        }

        let lower = text.lowercased()
        let googleBlockedFragments = [
            "there was an error logging you in",
            "contact support for assistance",
            "this browser or app may not be secure",
            "couldn't sign you in"
        ]

        guard googleBlockedFragments.contains(where: lower.contains) else {
            return nil
        }

        return DashboardNotice(
            message: "Google sign-in failed in the app window. Use Open in Browser for this account, press Command-A then Command-C on the dashboard page, and click Import Browser Text.",
            tone: .warning
        )
    }

    private static func isGoogleURL(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else {
            return false
        }

        return host == "accounts.google.com" || host.hasSuffix(".accounts.google.com")
    }
}
