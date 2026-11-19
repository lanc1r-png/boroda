import Foundation
import SwiftSoup

struct Forum: Identifiable, Hashable {
    var id: String { url.absoluteString }
    let title: String
    let desc: String
    let url: URL
}

struct ThreadItem: Identifiable, Hashable, Codable {
    var id: String { url.absoluteString }
    let title: String
    let author: String
    let meta: String
    let url: URL
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
}

struct Post: Identifiable {
    let id = UUID()
    let author: String
    let date: String
    let parts: [PostPart]
    let images: [ImageRef]
    let cards: [LinkCard]
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

    static func forums(_ html: String) throws -> [Forum] {
        let doc = try SwiftSoup.parse(html)
        var out: [Forum] = []
        for n in try doc.select(".node--forum").array() {
            guard let a = try n.select(".node-title a").first() else { continue }
            guard let url = try abs(a.attr("href")) else { continue }
            let desc = (try n.select(".node-description").first()?.text()) ?? ""
            out.append(Forum(title: try a.text(), desc: desc, url: url))
        }
        if out.isEmpty { throw noResults(doc, what: "Форумов") }
        return out
    }

    static func threads(_ html: String) throws -> (items: [ThreadItem], pages: Int) {
        let doc = try SwiftSoup.parse(html)
        var out: [ThreadItem] = []
        for it in try doc.select(".structItem--thread").array() {
            guard let a = try it.select(".structItem-title a[href*='/threads/']").first() else { continue }
            guard let url = try abs(a.attr("href")) else { continue }
            let author = try it.attr("data-author")
            let replies = (try it.select(".structItem-cell--meta dl dd").first()?.text()) ?? "0"
            out.append(ThreadItem(title: try a.text(), author: author, meta: "Ответов: \(replies)", url: url))
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
            let snippet = (try r.select(".contentRow-snippet").first()?.text()) ?? ""
            let author = (try r.select(".username").first()?.text()) ?? ""
            out.append(ThreadItem(title: try a.text(), author: author, meta: snippet, url: url))
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

    static func posts(_ html: String) throws -> (posts: [Post], pages: Int) {
        let doc = try SwiftSoup.parse(html)
        var out: [Post] = []
        for m in try doc.select("article.message--post").array() {
            let author = try m.attr("data-author")
            let date = (try m.select("time").first()?.text()) ?? ""
            guard let body = try m.select(".bbWrapper").first() else { continue }

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
                if let parent = img.parent(), parent.tagName() == "a",
                   let href = try? parent.attr("href"), looksLikeImage(href) {
                    raw.append(href)
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
                images.append(ImageRef(candidates: cands))
            }

            var r = Rendered()
            render(body, into: &r, link: nil, inQuote: false)
            r.flush()
            out.append(Post(author: author, date: date, parts: r.parts, images: images, cards: cards))
        }
        if out.isEmpty { throw noResults(doc, what: "Сообщений") }
        return (out, pageCount(doc))
    }
}
