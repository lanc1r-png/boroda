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
    private(set) var userAgent = ""
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
        if userAgent.isEmpty {
            userAgent = ((try? await webView.evaluateJavaScript("navigator.userAgent")) as? String) ?? ""
        }
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

/// Fallback image fetcher: opens the image URL in a second WKWebView (same cookies / Cloudflare
/// clearance as the main browser, Referer set) and reads the pixels back through a canvas.
@MainActor
final class ImageWebFetcher: NSObject, WKNavigationDelegate {
    static let shared = ImageWebFetcher()

    private let web: WKWebView
    private var cont: CheckedContinuation<Void, Error>?
    private var busy = false

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: cfg)
        super.init()
        web.navigationDelegate = self
    }

    private static let js = """
    (function(){
      try {
        if (!document.contentType || document.contentType.indexOf('image/') !== 0) return 'wait:' + document.contentType;
        var i = document.images[0];
        if (!i || !i.complete) return 'wait:noimg';
        var w = i.naturalWidth, h = i.naturalHeight;
        var s = Math.min(1, 4096 / Math.max(w, h));
        var c = document.createElement('canvas');
        c.width = Math.round(w * s); c.height = Math.round(h * s);
        c.getContext('2d').drawImage(i, 0, 0, c.width, c.height);
        return c.toDataURL('image/jpeg', 0.95);
      } catch (e) { return 'err:' + e; }
    })()
    """

    func fetch(_ url: URL) async throws -> UIImage {
        while busy { try await Task.sleep(nanoseconds: 100_000_000) }
        busy = true
        defer { busy = false }

        var req = URLRequest(url: url)
        req.setValue(Config.base.absoluteString + "/", forHTTPHeaderField: "Referer")

        let timeout = Task { @MainActor [weak self] in
            if (try? await Task.sleep(nanoseconds: 20_000_000_000)) == nil { return }
            self?.finish(LoadError.failed("таймаут загрузки"))
        }
        defer { timeout.cancel() }

        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            cont = c
            web.load(req)
        }

        var last = ""
        for _ in 0..<12 {
            if let r = try? await web.evaluateJavaScript(Self.js), let s = r as? String {
                if s.hasPrefix("data:image"),
                   let comma = s.firstIndex(of: ","),
                   let data = Data(base64Encoded: String(s[s.index(after: comma)...])),
                   let img = UIImage(data: data) {
                    return img
                }
                last = String(s.prefix(60))
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw LoadError.failed("не картинка (\(last))")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(error) }

    private func finish(_ error: Error?) {
        if let error, (error as NSError).code == NSURLErrorCancelled { return }
        guard let c = cont else { return }
        cont = nil
        if let error { c.resume(throwing: error) } else { c.resume() }
    }
}
