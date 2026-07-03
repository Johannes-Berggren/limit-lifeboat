import Foundation
import LLMUsageMonitorCore
import WebKit

enum WebUsageRefresherError: Error, LocalizedError {
    case timedOut
    case noText

    var errorDescription: String? {
        switch self {
        case .timedOut:
            return "Dashboard load timed out."
        case .noText:
            return "Dashboard did not expose readable text."
        }
    }
}

@MainActor
final class WebUsageRefresher {
    func fetchVisibleText(for profile: AccountProfile, url: URL? = nil) async throws -> String {
        let loader = WebPageTextLoader(profile: profile, url: url ?? profile.provider.dashboardURL)
        return try await loader.load()
    }
}

@MainActor
private final class WebPageTextLoader: NSObject, WKNavigationDelegate {
    private let profile: AccountProfile
    private let url: URL
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var didFinish = false

    init(profile: AccountProfile, url: URL) {
        self.profile = profile
        self.url = url
    }

    func load() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = WebDataStoreFactory.makeDataStore(for: profile)
            let webView = WKWebView(frame: .init(x: 0, y: 0, width: 1100, height: 900), configuration: configuration)
            webView.navigationDelegate = self
            self.webView = webView
            webView.load(URLRequest(url: url))

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.finish(.failure(WebUsageRefresherError.timedOut))
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !didFinish else {
            return
        }
        didFinish = true

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            self?.captureText()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }

    private func captureText() {
        webView?.evaluateJavaScript("document.body ? document.body.innerText : ''") { [weak self] value, error in
            Task { @MainActor in
                if let error {
                    self?.finish(.failure(error))
                    return
                }

                guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self?.finish(.failure(WebUsageRefresherError.noText))
                    return
                }

                self?.finish(.success(text))
            }
        }
    }

    private func finish(_ result: Result<String, Error>) {
        guard let continuation else {
            return
        }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        webView?.navigationDelegate = nil
        webView = nil

        switch result {
        case .success(let text):
            continuation.resume(returning: text)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
}
