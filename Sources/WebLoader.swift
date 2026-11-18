import SwiftUI
import WebKit

enum LoadError: LocalizedError {
    case challenge
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .challenge:
            return "Нужна проверка в браузере (Cloudflare). Откройте «Профиль» → «Войти / пройти проверку»."
        case .failed(let m):
            return m
        }
    }
}

/// Loads pages through a real WKWebView, so Cloudflare checks, cookies and login
/// work like in Safari. HTML is read back via JavaScript and parsed natively.
@MainActor
final class WebLoader: NSObject, WKNavigationDelegate {
    static let shared = WebLoader()

    let webView: WKWebView
    private var navContinuation: CheckedContinuation<Void, Error>?
    private var busy = false

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: cfg)
        super.init()
        webView.navigationDelegate = self
    }

    func html(_ url: URL) async throws -> String {
        while busy { try await Task.sleep(nanoseconds: 100_000_000) }
        busy = true
        defer { busy = false }

        try await load(url)
        for _ in 0..<20 {
            let html = try await currentHTML()
            if !Self.isChallenge(html) { return html }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw LoadError.challenge
    }

    func clearSession() async {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
    }

    private func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            navContinuation = c
            webView.load(URLRequest(url: url))
        }
    }

    private func currentHTML() async throws -> String {
        let r = try await webView.evaluateJavaScript("document.documentElement.outerHTML")
        return (r as? String) ?? ""
    }

    private static func isChallenge(_ h: String) -> Bool {
        h.contains("Just a moment") || h.contains("Checking your browser") || h.contains("cf-turnstile")
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(error)
    }

    private func finish(_ error: Error?) {
        if let error, (error as NSError).code == NSURLErrorCancelled { return }
        guard let c = navContinuation else { return }
        navContinuation = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}

/// Shows the shared WKWebView (for login / Cloudflare verification).
struct SharedWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { WebLoader.shared.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
