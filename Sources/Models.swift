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

struct Post: Identifiable {
    let id = UUID()
    let author: String
    let date: String
    let text: String
    let images: [URL]
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

    static func posts(_ html: String) throws -> (posts: [Post], pages: Int) {
        let doc = try SwiftSoup.parse(html)
        var out: [Post] = []
        for m in try doc.select("article.message--post").array() {
            let author = try m.attr("data-author")
            let date = (try m.select("time").first()?.text()) ?? ""
            guard let body = try m.select(".bbWrapper").first() else { continue }

            var images: [URL] = []
            for img in try body.select("img").array() {
                if try img.hasClass("smilie") { continue }
                let candidates = [try img.attr("data-url"), try img.attr("data-src"), try img.attr("src")]
                let src = candidates.first { !$0.isEmpty } ?? ""
                if src.hasPrefix("data:") { continue }
                if let u = abs(src) { images.append(u) }
            }

            try body.select("br").append("\\n")
            try body.select("img, .bbCodeBlock-expandLink").remove()
            let text = try body.text().replacingOccurrences(of: "\\n", with: "\n")
            out.append(Post(author: author, date: date, text: text, images: images))
        }
        let pages = try doc.select(".pageNav-main li a").array()
            .compactMap { Int((try? $0.text()) ?? "") }.max() ?? 1
        if out.isEmpty { throw empty }
        return (out, pages)
    }
}
