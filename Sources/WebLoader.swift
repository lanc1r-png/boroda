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
        try await lock()
        defer { busy = false }
        try await load(url)
        return try await waitReady()
    }

    /// Title-only search through the site's own search form.
    func search(_ query: String) async throws -> String {
        try await lock()
        defer { busy = false }
        try await load(Config.searchURL)
        _ = try await waitReady()
        let q = String(data: try JSONEncoder().encode(query), encoding: .utf8) ?? "\"\""
        let js = """
        (function(){
          var f=document.querySelector("form[action*='/search/search']");
          if(!f) return "noform";
          var k=f.querySelector("input[name='keywords']");
          if(!k) return "noform";
          k.value=\(q);
          var t=f.querySelector("input[name='c[title_only]']");
          if(t) t.checked=true;
          f.submit();
          return "ok";
        })()
        """
        try await submit(js)
        return try await waitReady()
    }

    private func lock() async throws {
        while busy { try await Task.sleep(nanoseconds: 100_000_000) }
        busy = true
    }

    /// Share browser cookies with URLSession so images/attachments load with the same session.
    private func syncCookies() async {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        for c in cookies { HTTPCookieStorage.shared.setCookie(c) }
    }

    private func waitReady() async throws -> String {
        for _ in 0..<20 {
            let html = try await currentHTML()
            if !Self.isChallenge(html) {
                await syncCookies()
                return html
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw LoadError.challenge
    }

    private func submit(_ js: String) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            navContinuation = c
            webView.evaluateJavaScript(js) { [weak self] result, error in
                Task { @MainActor in
                    if let error {
                        self?.finish(error)
                    } else if (result as? String) != "ok" {
                        self?.finish(LoadError.failed("Форма поиска не найдена на сайте."))
                    }
                }
            }
        }
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
