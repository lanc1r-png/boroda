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

struct Post: Identifiable {
    let id = UUID()
    let author: String
    let date: String
    let text: AttributedString
    let images: [URL]
    let cards: [LinkCard]
}

// MARK: - Parser (XenForo 2 selectors; tweak here if the markup differs)

enum Parser {
    private static let empty = LoadError.failed("Ничего не найдено. Возможно, нужен вход или изменилась вёрстка сайта.")

    static func abs(_ href: String) -> URL? {
        URL(string: href, relativeTo: Config.base)?.absoluteURL
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
        if out.isEmpty { throw empty }
        return out
    }

    static func threads(_ html: String) throws -> [ThreadItem] {
        let doc = try SwiftSoup.parse(html)
        var out: [ThreadItem] = []
        for it in try doc.select(".structItem--thread").array() {
            guard let a = try it.select(".structItem-title a[href*='/threads/']").first() else { continue }
            guard let url = try abs(a.attr("href")) else { continue }
            let author = try it.attr("data-author")
            let replies = (try it.select(".structItem-cell--meta dl dd").first()?.text()) ?? "0"
            out.append(ThreadItem(title: try a.text(), author: author, meta: "Ответов: \(replies)", url: url))
        }
        if out.isEmpty { throw empty }
        return out
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
        if out.isEmpty { throw empty }
        return out
    }

    /// Walks the post DOM into an AttributedString, keeping links tappable.
    static func render(_ node: Node, into out: inout AttributedString, link: URL?) {
        if let t = node as? TextNode {
            var s = AttributedString(t.text())
            if let link { s.link = link }
            out += s
            return
        }
        guard let el = node as? Element else { return }
        let tag = el.tagName()
        if ["img", "script", "style"].contains(tag) { return }
        if el.hasClass("bbCodeBlock--unfurl") || el.hasClass("bbCodeBlock--quote")
            || el.hasClass("bbCodeBlock-expandLink") { return }
        if tag == "br" {
            out += AttributedString("\n")
            return
        }
        var newLink = link
        if tag == "a", let href = try? el.attr("href"), !href.hasPrefix("#"), let u = abs(href) {
            newLink = u
        }
        let isBlock = ["div", "p", "li", "ul", "ol"].contains(tag)
        if isBlock, let last = out.characters.last, last != "\n" {
            out += AttributedString("\n")
        }
        for child in el.getChildNodes() {
            render(child, into: &out, link: newLink)
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

    static func posts(_ html: String) throws -> (posts: [Post], pages: Int) {
        let doc = try SwiftSoup.parse(html)
        var out: [Post] = []
        for m in try doc.select("article.message--post").array() {
            let author = try m.attr("data-author")
            let date = (try m.select("time").first()?.text()) ?? ""
            guard let body = try m.select(".bbWrapper").first() else { continue }

            // Link preview cards (unfurl blocks) -> tappable cards instead of broken images
            var cards: [LinkCard] = []
            for u in try body.select(".bbCodeBlock--unfurl").array() {
                guard let a = try u.select("a[href]").first() else { continue }
                guard let url = try abs(a.attr("href")) else { continue }
                let t = (try u.select(".contentRow-title").first()?.text()) ?? ""
                cards.append(LinkCard(title: t.isEmpty ? (url.host ?? url.absoluteString) : t, url: url))
            }

            // Images: prefer full-size URLs, skip icons / smilies / images inside previews and quotes
            var images: [URL] = []
            for img in try body.select("img").array() {
                if img.hasClass("smilie") || img.hasClass("reaction-image") { continue }
                let inSkipped = img.parents().array().contains {
                    $0.hasClass("bbCodeBlock--unfurl") || $0.hasClass("bbCodeBlock--quote")
                }
                if inSkipped { continue }
                let w = Int((try? img.attr("width")) ?? "") ?? 999
                let h = Int((try? img.attr("height")) ?? "") ?? 999
                if w < 100 || h < 100 { continue }

                var src = (try? img.attr("data-url")) ?? ""
                if src.isEmpty { src = (try? img.attr("data-src")) ?? "" }
                if src.isEmpty {
                    let s = (try? img.attr("src")) ?? ""
                    if !s.hasPrefix("data:") { src = s }
                }
                if let parent = img.parent(), parent.tagName() == "a" {
                    let href = (try? parent.attr("href")) ?? ""
                    let l = href.lowercased()
                    if [".jpg", ".jpeg", ".png", ".webp", ".gif", "/attachments/"].contains(where: { l.contains($0) }) {
                        src = href
                    }
                }
                if let u = abs(src), !images.contains(u) { images.append(u) }
            }

            var text = AttributedString()
            render(body, into: &text, link: nil)
            out.append(Post(author: author, date: date, text: text, images: images, cards: cards))
        }
        let pages = try doc.select(".pageNav-main li a").array()
            .compactMap { Int((try? $0.text()) ?? "") }.max() ?? 1
        if out.isEmpty { throw empty }
        return (out, pages)
    }
}
