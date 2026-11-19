import Foundation
import SwiftSoup

struct Forum: Identifiable, Hashable {
    var id: String { url.absoluteString }
    let title: String
    let desc: String
    let url: URL
    var category = ""
    var threadsCount: String? = nil
    var messagesCount: String? = nil
    var lastTitle: String? = nil
    var lastURL: URL? = nil
    var lastAuthor: String? = nil
    var lastDate: String? = nil
    var lastAvatar: URL? = nil
}

/// A coloured prefix label ("Request", "TikTok"…). `url` is the forum filter link when the page provides one.
struct TagLabel: Hashable, Codable {
    let text: String
    let style: String
    var url: URL? = nil
}

struct ThreadItem: Identifiable, Hashable, Codable {
    var id: String { url.absoluteString }
    let title: String
    let author: String
    let meta: String
    let url: URL
    var labels: [TagLabel]? = nil
    var thumb: URL? = nil
    var snippet: String? = nil
    var highlights: [String]? = nil
    var forumURL: URL? = nil
    var forumName: String? = nil
}

struct LinkCard: Identifiable {
    let id = UUID()
    let title: String
    let url: URL
}

enum PostPart {
    case text(AttributedString)
    case quote(author: String, text: AttributedString)
}

/// One picture in a post. Several candidate URLs are tried in order
/// (full-size first, then proxied / lazy-load variants).
struct ImageRef: Identifiable {
    let id = UUID()
    let candidates: [URL]
    /// Image-host pages (e.g. a link wrapped around the thumbnail) whose og:image is the full-size picture.
    var pages: [URL] = []
}

struct Post: Identifiable {
    let postID: String
    var id: String { postID }
    let author: String
    let date: String
    let parts: [PostPart]
    let images: [ImageRef]
    let cards: [LinkCard]

    /// Link to this exact message on the site (XenForo redirects /posts/ID/ to the right page).
    var permalink: URL? {
        postID.allSatisfy(\.isNumber) ? Config.base.appendingPathComponent("posts/\(postID)/") : nil
    }
}

// MARK: - Parser (XenForo 2 selectors; tweak here if the markup differs)

enum Parser {
    static func abs(_ href: String) -> URL? {
        URL(string: href, relativeTo: Config.base)?.absoluteURL
    }

    /// Builds a helpful error: page title + the site's own message (login required, no results, flood limit…).
    static func noResults(_ doc: Document, what: String) -> LoadError {
        let title = (try? doc.title()) ?? ""
        var msg = ""
        if let m = try? doc.select(".blockMessage, .p-body-pageContent .block-body .blockMessage").first() {
            msg = (try? m.text()) ?? ""
        }
        if msg.isEmpty, let c = try? doc.select(".p-body-content").first() {
            msg = String(((try? c.text()) ?? "").prefix(160))
        }
        var s = "\(what) не найдено."
        if !msg.isEmpty { s += "\n\nСайт пишет: \(msg)" }
        if !title.isEmpty { s += "\n\nСтраница: \(title)" }
        return LoadError.failed(s)
    }

    static func pageCount(_ doc: Document) -> Int {
        let nums = ((try? doc.select(".pageNav-main li a").array()) ?? [])
            .compactMap { Int((try? $0.text()) ?? "") }
        return nums.max() ?? 1
    }

    /// Prefix labels inside a row (colour comes from the label--xxx class).
    static func labels(in root: Element, selector: String) -> [TagLabel] {
        var out: [TagLabel] = []
        for lab in ((try? root.select(selector).array()) ?? []) {
            let text = ((try? lab.text()) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || out.contains(where: { $0.text == text }) { continue }
            let cls = ((try? lab.className()) ?? "").split(separator: " ").map(String.init)
            let style = cls.first(where: { $0.hasPrefix("label--") })?
                .replacingOccurrences(of: "label--", with: "") ?? ""
            var url: URL?
            if let p = lab.parent(), p.tagName() == "a",
               let href = try? p.attr("href"), href.contains("prefix_id") {
                url = abs(href)
            }
            out.append(TagLabel(text: text, style: style, url: url))
        }
        return out
    }

    /// Raw HTML of the first row of each kind, so it can be copied from the Profile screen for debugging.
    static var samples: [String: String] = [:]

    static func sample(_ key: String, _ el: Element?, limit: Int = 6000) {
        guard let el, let html = try? el.outerHtml() else { return }
        samples[key] = String(html.prefix(limit))
    }

    /// First usable image URL inside an element: <img> (data-src/src/srcset) or CSS url(...).
    static func firstImageURL(in el: Element) -> URL? {
        for img in ((try? el.select("img").array()) ?? []) {
            for key in ["data-src", "data-url", "data-original", "src"] {
                if let v = try? img.attr(key), !v.isEmpty, !v.hasPrefix("data:"), let u = abs(v) { return u }
            }
            if let ss = try? img.attr("srcset"),
               let first = ss.split(separator: ",").first?.split(separator: " ").first,
               let u = abs(String(first)) { return u }
        }
        let html = (try? el.outerHtml()) ?? ""
        if let re = try? NSRegularExpression(pattern: #"url\(\s*(?:&quot;|&#0?39;|['"])?([^)'"&\s]+)"#),
           let m = re.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
           m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: html) {
            let v = String(html[r])
            if !v.hasPrefix("data:"), let u = abs(v) { return u }
        }
        return nil
    }

    /// Cover / icon image of a list row.
    static func thumb(in root: Element) -> URL? {
        for sel in [".contentRow-figure", ".structItem-cell--icon", ".structItem-cell--thumb",
                    ".structItem-thumb", "[class*=thumb]", "[class*=cover]"] {
            for c in ((try? root.select(sel).array()) ?? []) {
                if let u = firstImageURL(in: c) { return u }
            }
        }
        return nil
    }

    static func forumNode(_ n: Element, category: String) -> Forum? {
        guard let a = try? n.select(".node-title a").first(),
              let href = try? a.attr("href"), let url = abs(href) else { return nil }
        let title = (try? a.text()) ?? ""
        let desc = (try? n.select(".node-description").first()?.text()) ?? ""

        var threads: String?
        var messages: String?
        for dl in ((try? n.select(".node-stats dl").array()) ?? []) {
            let k = ((try? dl.select("dt").first()?.text()) ?? "").lowercased()
            let v = (try? dl.select("dd").first()?.text()) ?? ""
            if k.contains("thread") { threads = v } else if k.contains("message") || k.contains("post") { messages = v }
        }

        let last = try? n.select(".node-extra-title").first()
        let lastTitle = last.flatMap { try? $0.text() }
        let lastURL = last.flatMap { try? $0.attr("href") }.flatMap { abs($0) }
        let lastDate = (try? n.select(".node-extra-date").first()?.text()) ?? nil
        let lastAuthor = (try? n.select(".node-extra-user").first()?.text()) ?? nil
        var avatar: URL?
        if let img = try? n.select(".node-extra-icon img").first() {
            for key in ["data-src", "src"] {
                if let v = try? img.attr(key), !v.isEmpty, !v.hasPrefix("data:"), let u = abs(v) { avatar = u; break }
            }
        }
        return Forum(title: title, desc: desc, url: url, category: category,
                     threadsCount: threads, messagesCount: messages,
                     lastTitle: (lastTitle ?? "").isEmpty ? nil : lastTitle,
                     lastURL: lastURL, lastAuthor: lastAuthor, lastDate: lastDate, lastAvatar: avatar)
    }

    static func forums(_ html: String) throws -> [Forum] {
        let doc = try SwiftSoup.parse(html)
        var out: [Forum] = []
        func add(_ f: Forum?) {
            if let f, !out.contains(where: { $0.url == f.url }) { out.append(f) }
        }
        let blocks = (try? doc.select(".block--category").array()) ?? []
        if blocks.isEmpty {
            for n in try doc.select(".node--forum").array() { add(forumNode(n, category: "")) }
        } else {
            for b in blocks {
                let cat = ((try? b.select(".block-header").first()?.text()) ?? "") ?? ""
                for n in ((try? b.select(".node--forum").array()) ?? []) { add(forumNode(n, category: cat)) }
            }
        }
        sample("forum", (try? doc.select(".node--forum").first()) ?? nil)
        if out.isEmpty { throw noResults(doc, what: "Форумов") }
        return out
    }

    static func threads(_ html: String) throws -> (items: [ThreadItem], pages: Int) {
        let doc = try SwiftSoup.parse(html)
        var out: [ThreadItem] = []
        for it in try doc.select(".structItem--thread").array() {
            guard let a = try it.select(".structItem-title a[href*='/threads/']").first() else { continue }
            guard let url = try abs(a.attr("href")) else { continue }
            if out.isEmpty { sample("thread", it) }
            let author = try it.attr("data-author")
            let replies = (try it.select(".structItem-cell--meta dl dd").first()?.text()) ?? "0"
            out.append(ThreadItem(title: try a.text(), author: author, meta: "Ответов: \(replies)", url: url,
                                  labels: labels(in: it, selector: ".structItem-title .label"),
                                  thumb: thumb(in: it)))
        }
        if out.isEmpty { throw noResults(doc, what: "Тем") }
        return (out, pageCount(doc))
    }

    static func latest(_ html: String) throws -> [ThreadItem] {
        let doc = try SwiftSoup.parse(html)
        var out: [ThreadItem] = []
        for r in try doc.select(".contentRow").array() {
            guard let a = try r.select(".contentRow-title a").first() else { continue }
            guard let url = try abs(a.attr("href")) else { continue }
            let snippetEl = try r.select(".contentRow-snippet").first()
            let snippet = (try snippetEl?.text()) ?? ""
            var words: [String] = []
            if let sn = snippetEl {
                for h in ((try? sn.select(".textHighlight, b, strong").array()) ?? []) {
                    if let t = try? h.text(), !t.isEmpty { words.append(t) }
                }
            }
            let author = (try r.select(".username").first()?.text()) ?? ""
            let labs = labels(in: r, selector: ".contentRow-title .label")
            var title = try a.text()
            for l in labs where title.hasPrefix(l.text) {
                title = String(title.dropFirst(l.text.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let blockRow: Element? = r.parent().flatMap { $0.hasClass("block-row") ? $0 : nil }
            let scope = blockRow ?? r
            if out.isEmpty { sample("search", blockRow ?? r) }
            var parts = ((try? r.select(".contentRow-minor li").array()) ?? [])
                .compactMap { try? $0.text() }.filter { !$0.isEmpty }
            if let f = parts.first, f == author { parts.removeFirst() }
            let forumLink = try? r.select(".contentRow-minor a[href*='/forums/']").first()
            let forumURL = forumLink.flatMap { try? $0.attr("href") }.flatMap { abs($0) }
            let forumName = forumLink.flatMap { try? $0.text() }
            out.append(ThreadItem(title: title, author: author,
                                  meta: parts.joined(separator: " · "), url: url,
                                  labels: labs, thumb: thumb(in: scope),
                                  snippet: snippet, highlights: words,
                                  forumURL: forumURL, forumName: forumName))
        }
        if out.isEmpty { throw noResults(doc, what: "Ничего") }
        return out
    }

    // MARK: Post body rendering

    struct Rendered {
        var parts: [PostPart] = []
        var current = AttributedString()

        mutating func flush() {
            let t = Parser.trim(current)
            if !t.characters.isEmpty { parts.append(.text(t)) }
            current = AttributedString()
        }
    }

    static func trim(_ s: AttributedString) -> AttributedString {
        let chars = s.characters
        guard let start = chars.firstIndex(where: { !$0.isWhitespace }),
              let end = chars.lastIndex(where: { !$0.isWhitespace }) else { return AttributedString() }
        return AttributedString(s[start...end])
    }

    /// Walks the post DOM, keeping links tappable and quotes as separate blocks.
    static func render(_ node: Node, into r: inout Rendered, link: URL?, inQuote: Bool) {
        if let t = node as? TextNode {
            var s = AttributedString(t.text())
            if let link { s.link = link }
            r.current += s
            return
        }
        guard let el = node as? Element else { return }
        let tag = el.tagName()
        if ["img", "script", "style"].contains(tag) { return }
        if el.hasClass("bbCodeBlock--unfurl") || el.hasClass("bbCodeBlock-expandLink") { return }

        if el.hasClass("bbCodeBlock--quote") {
            if inQuote { return }
            r.flush()
            let title = (try? el.select(".bbCodeBlock-title").first()?.text()) ?? ""
            var q = Rendered()
            let expand: Element? = try? el.select(".bbCodeBlock-expandContent").first()
            let plain: Element? = try? el.select(".bbCodeBlock-content").first()
            if let content = expand ?? plain {
                render(content, into: &q, link: nil, inQuote: true)
            }
            q.flush()
            if case .text(let t)? = q.parts.first {
                r.parts.append(.quote(author: title, text: t))
            }
            return
        }

        if tag == "br" {
            let tail = r.current.characters.suffix(2)
            if tail.count < 2 || !tail.allSatisfy({ $0 == "\n" }) {
                r.current += AttributedString("\n")
            }
            return
        }
        var newLink = link
        if tag == "a", let href = try? el.attr("href"), !href.hasPrefix("#"), let u = abs(href) {
            newLink = u
        }
        let isBlock = ["div", "p", "li", "ul", "ol"].contains(tag)
        if isBlock, let last = r.current.characters.last, last != "\n" {
            r.current += AttributedString("\n")
        }
        for child in el.getChildNodes() {
            render(child, into: &r, link: newLink, inQuote: inQuote)
        }
    }

    static func session(_ html: String) throws -> (loggedIn: Bool, name: String) {
        let doc = try SwiftSoup.parse(html)
        let flag = (try doc.select("html").first()?.attr("data-logged-in")) ?? ""
        let hasLogout = !(try doc.select("a[href*='/logout/']").isEmpty())
        let userLink = try doc.select(".p-navgroup-link--user").first()
        let loggedIn = flag == "true" || hasLogout || userLink != nil
        let name = (try userLink?.select(".p-navgroup-linkText").first()?.text()) ?? ""
        return (loggedIn, name)
    }

    /// Image hosts (Chevereto etc.) serve thumbnails as name.md.jpg / name.th.jpg; the original is name.jpg.
    static func fullSizeVariants(_ u: URL) -> [URL] {
        var out: [URL] = []
        let s = u.absoluteString
        for tag in [".md.", ".th.", ".thumb.", ".small.", ".medium.", ".lg."] where s.contains(tag) {
            if let v = URL(string: s.replacingOccurrences(of: tag, with: ".")) { out.append(v) }
        }
        let host = u.host ?? ""
        // imgbox: thumbnail _t -> original _o
        if host.contains("imgbox"), s.contains("_t."), let v = URL(string: s.replacingOccurrences(of: "_t.", with: "_o.")) {
            out.append(v)
        }
        // imgur: id + one size letter (s, t, m, l, h) -> plain id
        if host == "i.imgur.com" {
            let name = u.deletingPathExtension().lastPathComponent
            if [6, 8].contains(name.count), let last = name.last, "stmlhb".contains(last) {
                out.append(u.deletingLastPathComponent()
                    .appendingPathComponent(String(name.dropLast()))
                    .appendingPathExtension(u.pathExtension))
            }
        }
        // XenForo image proxy: the original URL is in ?image=
        if u.path.hasSuffix("proxy.php"),
           let items = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems,
           let orig = items.first(where: { $0.name == "image" })?.value,
           let v = URL(string: orig) {
            out.insert(v, at: 0)
        }
        // size-limiting query parameters
        if var c = URLComponents(url: u, resolvingAgainstBaseURL: false), let items = c.queryItems {
            let drop = ["w", "h", "width", "height", "size", "resize", "thumb"]
            let kept = items.filter { !drop.contains($0.name.lowercased()) }
            if kept.count != items.count {
                c.queryItems = kept.isEmpty ? nil : kept
                if let v = c.url { out.append(v) }
            }
        }
        return out
    }

    private static func looksLikeImage(_ href: String) -> Bool {
        let l = href.lowercased()
        return [".jpg", ".jpeg", ".png", ".webp", ".gif", ".avif", "/attachments/"].contains { l.contains($0) }
    }

    static func searchResults(_ html: String) throws -> (items: [ThreadItem], pages: Int) {
        let items = try latest(html)
        let doc = try SwiftSoup.parse(html)
        return (items, pageCount(doc))
    }

    /// Extracts a post id from /posts/123/, /threads/x.1/post-123 or #post-123.
    static func postID(from url: URL) -> String? {
        let s = url.absoluteString
        for pattern in [#"/posts/(\d+)"#, #"post-(\d+)"#] {
            if let re = try? NSRegularExpression(pattern: pattern),
               let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
               m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) {
                return String(s[r])
            }
        }
        return nil
    }

    static func posts(_ html: String) throws -> (posts: [Post], pages: Int) {
        let doc = try SwiftSoup.parse(html)
        var out: [Post] = []
        for m in try doc.select("article.message--post").array() {
            let author = try m.attr("data-author")
            let date = (try m.select("time").first()?.text()) ?? ""
            guard let body = try m.select(".bbWrapper").first() else { continue }
            let digits = ((try? m.attr("data-content")) ?? "").filter(\.isNumber)
            let postID = digits.isEmpty ? UUID().uuidString : digits

            // Link preview cards (unfurl blocks)
            var cards: [LinkCard] = []
            for u in try body.select(".bbCodeBlock--unfurl").array() {
                guard let a = try u.select("a[href]").first() else { continue }
                guard let url = try abs(a.attr("href")) else { continue }
                let t = (try u.select(".contentRow-title").first()?.text()) ?? ""
                cards.append(LinkCard(title: t.isEmpty ? (url.host ?? url.absoluteString) : t, url: url))
            }

            // Images: several candidate URLs per picture
            var images: [ImageRef] = []
            for img in try body.select("img").array() {
                if img.hasClass("smilie") || img.hasClass("reaction-image") { continue }
                let inSkipped = img.parents().array().contains {
                    $0.hasClass("bbCodeBlock--unfurl") || $0.hasClass("bbCodeBlock--quote")
                }
                if inSkipped { continue }
                let w = Int((try? img.attr("width")) ?? "") ?? 999
                let h = Int((try? img.attr("height")) ?? "") ?? 999
                if w < 100 || h < 100 { continue }

                var raw: [String] = []
                var pageLinks: [URL] = []
                if let parent = img.parent(), parent.tagName() == "a",
                   let href = try? parent.attr("href"), !href.isEmpty {
                    if looksLikeImage(href) {
                        raw.append(href)
                    } else if let u = abs(href), u.host != Config.base.host,
                              u.scheme?.hasPrefix("http") == true {
                        pageLinks.append(u)
                    }
                }
                for key in ["data-url", "data-src", "src"] {
                    if let v = try? img.attr(key), !v.isEmpty, !v.hasPrefix("data:") { raw.append(v) }
                }
                var cands: [URL] = []
                for s in raw {
                    guard let u = abs(s) else { continue }
                    // Full-size guesses first, then the URL as given
                    for v in fullSizeVariants(u) + [u] where !cands.contains(v) { cands.append(v) }
                }
                if cands.isEmpty { continue }
                if images.contains(where: { $0.candidates.first == cands.first }) { continue }
                images.append(ImageRef(candidates: cands, pages: pageLinks))
            }

            var r = Rendered()
            render(body, into: &r, link: nil, inQuote: false)
            r.flush()
            out.append(Post(postID: postID, author: author, date: date, parts: r.parts, images: images, cards: cards))
        }
        sample("post", (try? doc.select("article.message--post").first()) ?? nil, limit: 9000)
        if out.isEmpty { throw noResults(doc, what: "Сообщений") }
        return (out, pageCount(doc))
    }
}
