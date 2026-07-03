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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Label(profile.label, systemImage: profile.provider == .claude ? "sparkles" : "terminal")
                    .font(.headline)

                Spacer()

                Button {
                    captureSignal += 1
                } label: {
                    Label("Capture Usage", systemImage: "text.viewfinder")
                }
            }
            .padding(10)

            Divider()

            DashboardWebView(profile: profile, captureSignal: captureSignal, onText: onText)
        }
    }
}

struct DashboardWebView: NSViewRepresentable {
    let profile: AccountProfile
    let captureSignal: Int
    let onText: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onText: onText)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: profile.webDataStoreID)
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

        init(onText: @escaping (String) -> Void) {
            self.onText = onText
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
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
                onText(text)
            }
        }
    }
}
