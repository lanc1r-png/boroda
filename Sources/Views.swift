import SwiftUI
import Observation
import Translation
import SwiftSoup

// MARK: - Helpers

enum LoadState<T> {
    case idle, loading, loaded(T), failed(String)
}

struct StateView<T, Content: View>: View {
    let state: LoadState<T>
    let retry: () async -> Void
    let content: (T) -> Content

    init(state: LoadState<T>, retry: @escaping () async -> Void, @ViewBuilder content: @escaping (T) -> Content) {
        self.state = state
        self.retry = retry
        self.content = content
    }

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let value):
            content(value)
        case .failed(let message):
            ContentUnavailableView {
                Label("Ошибка", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Повторить") { Task { await retry() } }
                    .buttonStyle(.glass)
            }
        }
    }
}

@MainActor
func fetch<T>(_ url: URL, _ parse: (String) throws -> T) async -> LoadState<T> {
    do {
        let html = try await WebLoader.shared.html(url)
        return .loaded(try parse(html))
    } catch {
        return .failed(error.localizedDescription)
    }
}

@Observable
final class BookmarkStore {
    static let shared = BookmarkStore()
    private(set) var items: [ThreadItem]

    private init() {
        if let d = UserDefaults.standard.data(forKey: "bookmarks"),
           let v = try? JSONDecoder().decode([ThreadItem].self, from: d) {
            items = v
        } else {
            items = []
        }
    }

    func contains(_ t: ThreadItem) -> Bool { items.contains { $0.url == t.url } }

    func toggle(_ t: ThreadItem) {
        if let i = items.firstIndex(where: { $0.url == t.url }) {
            items.remove(at: i)
        } else {
            items.insert(t, at: 0)
        }
        if let d = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(d, forKey: "bookmarks")
        }
    }
}

@Observable
@MainActor
final class AuthState {
    static let shared = AuthState()
    var loggedIn = false
    var username = ""
    var checking = false
    var error: String?

    func refresh() async {
        checking = true
        defer { checking = false }
        do {
            let html = try await WebLoader.shared.html(Config.base)
            let s = try Parser.session(html)
            loggedIn = s.loggedIn
            username = s.name
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Translation (on-device, Apple Translation framework)

@Observable
@MainActor
final class TranslationStore {
    static let shared = TranslationStore()
    var enabled = false
    var busy = false
    var lastError: String?
    var cache: [String: String] = [:]
    var configuration: TranslationSession.Configuration?
    private var pending: Set<String> = []

    static func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Russian text if translation is on and already available.
    func translated(_ s: String) -> String? {
        guard enabled else { return nil }
        return cache[Self.key(s)]
    }

    func tr(_ s: String) -> String { translated(s) ?? s }

    func request(_ texts: [String]) {
        let new = Set(texts.map(Self.key).filter { !$0.isEmpty && cache[$0] == nil })
        guard !new.isEmpty else { return }
        pending.formUnion(new)
        trigger()
    }

    private func trigger() {
        if configuration == nil {
            configuration = TranslationSession.Configuration(
                source: Locale.Language(identifier: "en"),
                target: Locale.Language(identifier: "ru"))
        } else {
            configuration?.invalidate()
        }
    }

    func run(_ session: TranslationSession) async {
        let batch = Array(pending)
        pending.removeAll()
        guard !batch.isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            var i = 0
            while i < batch.count {
                let chunk = Array(batch[i..<min(i + 25, batch.count)])
                let reqs = chunk.map { TranslationSession.Request(sourceText: $0) }
                let responses = try await session.translations(from: reqs)
                for r in responses { cache[Self.key(r.sourceText)] = r.targetText }
                i += 25
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        if !pending.isEmpty { trigger() }
    }
}

struct TranslateButton: View {
    private let store = TranslationStore.shared
    var body: some View {
        Button {
            store.enabled.toggle()
        } label: {
            if store.busy {
                ProgressView()
            } else if store.enabled && store.lastError != nil {
                Image(systemName: "exclamationmark.triangle")
            } else {
                Image(systemName: store.enabled ? "character.bubble.fill" : "character.bubble")
            }
        }
        .accessibilityLabel("Перевести на русский")
    }
}

struct TranslateTexts: ViewModifier {
    let texts: [String]
    private let store = TranslationStore.shared

    struct Key: Equatable {
        let enabled: Bool
        let hash: Int
    }

    func body(content: Content) -> some View {
        content.task(id: Key(enabled: store.enabled, hash: texts.hashValue)) {
            if store.enabled { store.request(texts) }
        }
    }
}

extension View {
    /// Registers the visible English texts of a screen for translation while translation is on.
    func translateTexts(_ texts: [String]) -> some View { modifier(TranslateTexts(texts: texts)) }
}

// MARK: - Images

enum ImageLoader {
    static let cache = NSCache<NSURL, UIImage>()

    /// Loads with the same cookies / User-Agent / Referer as the in-app browser,
    /// so hotlink protection and login-only attachments work.
    static func load(_ url: URL) async throws -> UIImage {
        if let c = cache.object(forKey: url as NSURL) { return c }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue(Config.base.absoluteString + "/", forHTTPHeaderField: "Referer")
        let ua = await WebLoader.shared.userAgent
        if !ua.isEmpty { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        req.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let ct = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "?"
        let host = url.host ?? "?"
        if !(200..<300).contains(code) {
            throw LoadError.failed("\(host): HTTP \(code) \(ct)")
        }
        guard let raw = UIImage(data: data) else {
            throw LoadError.failed("\(host): HTTP \(code) \(ct) \(data.count / 1024) KB")
        }
        let img = await raw.byPreparingForDisplay() ?? raw
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}

extension ImageLoader {
    /// For links wrapped around a thumbnail: read the image host page and return its og:image.
    static func resolvePage(_ url: URL) async -> URL? {
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue(Config.base.absoluteString + "/", forHTTPHeaderField: "Referer")
        let ua = await WebLoader.shared.userAgent
        if !ua.isEmpty { req.setValue(ua, forHTTPHeaderField: "User-Agent") }
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1),
              let doc = try? SwiftSoup.parse(html) else { return nil }
        for sel in ["meta[property=og:image]", "meta[name=twitter:image]", "link[rel=image_src]"] {
            guard let el = try? doc.select(sel).first() else { continue }
            let attr = el.tagName() == "link" ? "href" : "content"
            if let v = try? el.attr(attr), !v.isEmpty,
               let u = URL(string: v, relativeTo: url)?.absoluteURL {
                return u
            }
        }
        return nil
    }
}

struct ViewerImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

final class PhotoSaver: NSObject, ObservableObject {
    @Published var status: String?

    func save(_ image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(done(_:didFinishSavingWithError:contextInfo:)), nil)
    }

    @objc private func done(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        status = error == nil ? "Сохранено в «Фото»" : "Не удалось сохранить: \(error!.localizedDescription)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.status = nil }
    }
}

struct ImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @StateObject private var saver = PhotoSaver()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnifyGesture()
                        .onChanged { scale = min(8, max(1, lastScale * $0.magnification)) }
                        .onEnded { _ in lastScale = scale }
                )
                .onTapGesture(count: 2) {
                    withAnimation { scale = scale > 1 ? 1 : 2.5; lastScale = scale }
                }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).padding(14)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)
                }
                .padding()
                Spacer()
                if let s = saver.status {
                    Text(s).font(.footnote).padding(10)
                        .glassEffect(.regular, in: .capsule)
                }
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button { saver.save(image) } label: {
                            Label("Сохранить", systemImage: "arrow.down.to.line")
                                .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)

                        ShareLink(item: Image(uiImage: image),
                                  preview: SharePreview("Изображение", image: Image(uiImage: image))) {
                            Label("Поделиться", systemImage: "square.and.arrow.up")
                                .padding(.horizontal, 14).padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .capsule)
                    }
                }
                .padding(.bottom, 24)
            }
        }
    }
}

struct RemoteImage: View {
    let ref: ImageRef
    let onTap: (UIImage) -> Void
    @State private var image: UIImage?
    @State private var failure: String?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onTapGesture { onTap(image) }
            } else if let failure {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Не удалось загрузить:\n\(failure)", systemImage: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 16) {
                        Button("Повторить") { Task { await load() } }
                            .buttonStyle(.borderless)
                        if let u = ref.candidates.first {
                            Link("Открыть в браузере", destination: u)
                        }
                    }
                    .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 100)
            }
        }
        .task { if image == nil && failure == nil { await load() } }
    }

    private func load() async {
        failure = nil
        var notes: [String] = []

        func isCancel(_ e: Error) -> Bool {
            e is CancellationError || (e as? URLError)?.code == .cancelled
        }

        func pixels(_ i: UIImage) -> CGFloat { i.size.width * i.scale }

        // Candidates are ordered full-size first. Keep the sharpest one; stop early once it is large enough.
        var best: UIImage?
        for u in ref.candidates {
            do {
                let img = try await ImageLoader.load(u)
                if best == nil || pixels(img) > pixels(best!) { best = img }
                if pixels(img) >= 1000 { break }
            } catch {
                if isCancel(error) { return }   // view scrolled away: retry on reappear
                notes.append(error.localizedDescription)
            }
        }
        // Thumbnail wrapped in a link to an image-host page: take the page's og:image (full size)
        if best == nil || pixels(best!) < 1000 {
            for pg in ref.pages.prefix(2) {
                guard let u = await ImageLoader.resolvePage(pg),
                      let img = try? await ImageLoader.load(u) else { continue }
                if best == nil || pixels(img) > pixels(best!) { best = img }
                if pixels(img) >= 1000 { break }
            }
        }
        if let best {
            image = best
            return
        }
        // Fallback: let the in-app browser fetch it (cookies, Cloudflare, Referer)
        for u in ref.candidates.prefix(3) {
            do {
                let img = try await ImageWebFetcher.shared.fetch(u)
                ImageLoader.cache.setObject(img, forKey: u as NSURL)
                image = img
                return
            } catch {
                if isCancel(error) { return }
                notes.append("браузер: \(error.localizedDescription)")
            }
        }
        failure = notes.suffix(3).joined(separator: "\n")
    }
}

// MARK: - Root

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Главная", systemImage: "house.fill") { HomeView() }
            Tab("Закладки", systemImage: "bookmark.fill") { BookmarksView() }
            Tab("Профиль", systemImage: "person.crop.circle") { ProfileView() }
            Tab("Поиск", systemImage: "magnifyingglass", role: .search) { SearchView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .translationTask(TranslationStore.shared.configuration) { session in
            await TranslationStore.shared.run(session)
        }
        .task { await AuthState.shared.refresh() }
    }
}

// MARK: - Search (thread titles)

enum SearchScope: String, CaseIterable, Identifiable {
    case everywhere = "Везде"
    case titles = "Заголовки"
    var id: String { rawValue }
}

struct SearchView: View {
    @State private var query = ""
    @State private var scope: SearchScope = .everywhere
    @State private var state: LoadState<[ThreadItem]> = .idle
    @State private var page = 1
    @State private var pages = 1
    @State private var resultsURL: URL?
    @State private var loadingMore = false
    @State private var moreError: String?

    var body: some View {
        NavigationStack {
            Group {
                if case .idle = state {
                    ContentUnavailableView("Поиск по форуму", systemImage: "magnifyingglass",
                                           description: Text("Ищет слова в сообщениях. Нажмите на результат, чтобы перейти прямо к сообщению."))
                } else {
                    StateView(state: state, retry: run) { items in
                        resultsList(items)
                    }
                }
            }
            .navigationTitle("Поиск")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { TranslateButton() } }
            .navigationDestination(for: ThreadItem.self) { ThreadView(item: $0) }
        }
        .searchable(text: $query, prompt: "Слово или фраза")
        .searchScopes($scope) {
            ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
        }
        .onSubmit(of: .search) { Task { await run() } }
        .onChange(of: scope) { _, _ in Task { await run() } }
    }

    @ViewBuilder
    private func resultsList(_ items: [ThreadItem]) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(items) { t in
                    NavigationLink(value: t) { ThreadRow(item: t) }.buttonStyle(.plain)
                }
                if page < pages {
                    Button(loadingMore ? "Загрузка…" : "Показать ещё") { Task { await more() } }
                        .buttonStyle(.glass)
                        .disabled(loadingMore)
                        .padding()
                }
                if let moreError {
                    Text(moreError).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
            }
            .padding(.horizontal)
        }
        .refreshable { await run() }
        .translateTexts(items.map(\.title) + items.map(\.meta))
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        state = .loading
        page = 1
        pages = 1
        moreError = nil
        do {
            let html = try await WebLoader.shared.search(q, titleOnly: scope == .titles)
            let r = try Parser.searchResults(html)
            resultsURL = WebLoader.shared.webView.url
            pages = max(r.pages, 1)
            state = .loaded(r.items)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func more() async {
        guard case .loaded(let current) = state, let base = resultsURL, !loadingMore else { return }
        loadingMore = true
        moreError = nil
        defer { loadingMore = false }
        var c = URLComponents(url: base, resolvingAgainstBaseURL: false)
        var qi = (c?.queryItems ?? []).filter { $0.name != "page" }
        qi.append(URLQueryItem(name: "page", value: String(page + 1)))
        c?.queryItems = qi
        guard let url = c?.url else { return }
        do {
            let html = try await WebLoader.shared.html(url)
            let r = try Parser.searchResults(html)
            let known = Set(current.map(\.id))
            state = .loaded(current + r.items.filter { !known.contains($0.id) })
            page += 1
            pages = max(pages, r.pages)
        } catch {
            moreError = error.localizedDescription
        }
    }
}

// MARK: - Home (swipeable sections)

struct SectionBar: View {
    let titles: [String]
    @Binding var selection: Int

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(titles.indices, id: \.self) { i in
                    Button {
                        withAnimation(.smooth) { selection = i }
                    } label: {
                        Text(titles[i])
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(
                        selection == i ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                        in: .capsule
                    )
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

struct HomeView: View {
    @State private var page = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SectionBar(titles: ["Форумы", "Новое"], selection: $page)
                TabView(selection: $page) {
                    ForumsView().tag(0)
                    LatestView().tag(1)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationTitle("SimpClient")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { TranslateButton() } }
            .navigationDestination(for: Forum.self) { ForumThreadsView(forum: $0) }
            .navigationDestination(for: ThreadItem.self) { ThreadView(item: $0) }
        }
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct ForumsView: View {
    @State private var state: LoadState<[Forum]> = .idle
    private let tx = TranslationStore.shared

    var body: some View {
        StateView(state: state, retry: load) { forums in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(forums) { f in
                        NavigationLink(value: f) {
                            Card {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(tx.tr(f.title)).font(.headline)
                                    if !f.desc.isEmpty {
                                        Text(tx.tr(f.desc)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
            }
            .refreshable { await load() }
            .translateTexts(forums.flatMap { [$0.title, $0.desc] })
        }
        .task { if case .idle = state { await load() } }
    }

    private func load() async {
        state = .loading
        state = await fetch(Config.forumsURL, Parser.forums)
    }
}

struct ThreadRow: View {
    let item: ThreadItem
    private let tx = TranslationStore.shared
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(tx.tr(item.title)).font(.headline).multilineTextAlignment(.leading)
                HStack {
                    if !item.author.isEmpty { Text(item.author).font(.caption.weight(.semibold)) }
                    Text(tx.tr(item.meta)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

struct ThreadListView: View {
    let items: [ThreadItem]
    let reload: () async -> Void
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(items) { t in
                    NavigationLink(value: t) { ThreadRow(item: t) }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .refreshable { await reload() }
        .translateTexts(items.map(\.title) + items.map(\.meta).filter { !$0.hasPrefix("Ответов") })
    }
}

struct LatestView: View {
    @State private var state: LoadState<[ThreadItem]> = .idle

    var body: some View {
        StateView(state: state, retry: load) { items in
            ThreadListView(items: items, reload: load)
        }
        .task { if case .idle = state { await load() } }
    }

    private func load() async {
        state = .loading
        state = await fetch(Config.latestURL, Parser.latest)
    }
}

// MARK: - Pagination

struct PagePicker: View {
    let pages: Int
    let onPick: (Int) -> Void
    @State private var selected: Int
    @Environment(\.dismiss) private var dismiss

    init(page: Int, pages: Int, onPick: @escaping (Int) -> Void) {
        self.pages = pages
        self.onPick = onPick
        _selected = State(initialValue: page)
    }

    var body: some View {
        VStack(spacing: 8) {
            Text("Перейти на страницу").font(.headline).padding(.top)
            Picker("Страница", selection: $selected) {
                ForEach(1...max(pages, 1), id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.wheel)
            Button("Перейти") {
                onPick(selected)
                dismiss()
            }
            .buttonStyle(.glassProminent)
            .padding(.bottom)
        }
        .padding(.horizontal)
    }
}

struct PageToolbar: ViewModifier {
    let page: Int
    let pages: Int
    let go: (Int) -> Void
    @State private var picking = false

    func body(content: Content) -> some View {
        content
            .toolbarVisibility(.hidden, for: .tabBar)
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    if pages > 1 {
                        Button { go(1) } label: { Image(systemName: "chevron.left.2") }
                            .disabled(page <= 1)
                        Button { go(page - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(page <= 1)
                        Spacer()
                        Button { picking = true } label: {
                            Text("\(page) / \(pages)").font(.body.monospacedDigit())
                        }
                        Spacer()
                        Button { go(page + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(page >= pages)
                        Button { go(pages) } label: { Image(systemName: "chevron.right.2") }
                            .disabled(page >= pages)
                    }
                }
            }
            .sheet(isPresented: $picking) {
                PagePicker(page: page, pages: pages) { go($0) }
                    .presentationDetents([.height(340)])
            }
    }
}

extension View {
    func pageToolbar(page: Int, pages: Int, go: @escaping (Int) -> Void) -> some View {
        modifier(PageToolbar(page: page, pages: pages, go: go))
    }
}

struct ForumThreadsView: View {
    let forum: Forum
    @State private var items: [ThreadItem] = []
    @State private var page = 1
    @State private var pages = 1
    @State private var target = 1
    @State private var loading = false
    @State private var error: String?
    @State private var scrollKey = 0

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(items) { t in
                    NavigationLink(value: t) { ThreadRow(item: t) }.buttonStyle(.plain)
                }
                if loading {
                    ProgressView().padding(40)
                }
                if let error {
                    VStack(spacing: 10) {
                        Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Повторить") { Task { await load(target) } }.buttonStyle(.glass)
                    }
                    .padding()
                }
            }
            .padding(.horizontal)
        }
        .id(scrollKey)
        .refreshable { await load(page) }
        .pageToolbar(page: page, pages: pages) { n in Task { await load(n) } }
        .navigationTitle(TranslationStore.shared.tr(forum.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { TranslateButton() } }
        .translateTexts([forum.title] + items.map(\.title))
        .task { if items.isEmpty && error == nil && !loading { await load(1) } }
    }

    private func load(_ n: Int) async {
        guard !loading else { return }
        loading = true
        error = nil
        target = n
        items = []
        let url = n == 1 ? forum.url : forum.url.appendingPathComponent("page-\(n)")
        let result = await fetch(url, Parser.threads)
        switch result {
        case .loaded(let r):
            items = r.items
            pages = max(r.pages, pages, n)
            page = n
            scrollKey += 1
        case .failed(let m):
            error = m
        default:
            break
        }
        loading = false
    }
}

// MARK: - Thread

struct QuoteView: View {
    let author: String
    let text: AttributedString
    private let tx = TranslationStore.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                if !author.isEmpty {
                    Text(author).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Group {
                    if let tt = tx.translated(String(text.characters)) { Text(tt) } else { Text(text) }
                }
                .font(.footnote).foregroundStyle(.secondary).lineLimit(12)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct PostView: View {
    let post: Post
    var highlight = false
    let onImage: (UIImage) -> Void
    private let tx = TranslationStore.shared

    var body: some View {
        card.overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.accentColor, lineWidth: highlight ? 2.5 : 0)
        )
    }

    private var card: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(post.author).font(.subheadline.weight(.bold))
                    Spacer()
                    Text(post.date).font(.caption).foregroundStyle(.secondary)
                    if let link = post.permalink {
                        Link(destination: link) {
                            Image(systemName: "safari").font(.body).padding(4)
                        }
                        .accessibilityLabel("Открыть это сообщение на сайте")
                    }
                }
                ForEach(Array(post.parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let t):
                        if let tt = tx.translated(String(t.characters)) { Text(tt) } else { Text(t) }
                    case .quote(let author, let t):
                        QuoteView(author: author, text: t)
                    }
                }
                ForEach(post.cards) { card in
                    Link(destination: card.url) {
                        HStack {
                            Image(systemName: "link")
                            Text(card.title).lineLimit(2).multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right").font(.caption)
                        }
                        .font(.subheadline)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
                ForEach(post.images) { ref in
                    RemoteImage(ref: ref, onTap: onImage)
                }
            }
        }
    }
}

struct ThreadView: View {
    let item: ThreadItem
    @State private var posts: [Post] = []
    @State private var page = 1
    @State private var pages = 1
    @State private var target = 1
    @State private var loading = false
    @State private var error: String?
    @State private var canonical: URL?
    @State private var scrollKey = 0
    @State private var viewer: ViewerImage?
    @State private var targetPost: String?
    @State private var highlightID: String?
    @State private var pendingScroll: String?
    private let store = BookmarkStore.shared
    private let tx = TranslationStore.shared

    private var allTexts: [String] {
        [item.title] + posts.flatMap { p in
            p.parts.map { part -> String in
                switch part {
                case .text(let t): return String(t.characters)
                case .quote(_, let t): return String(t.characters)
                }
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(posts) { p in
                        PostView(post: p, highlight: p.postID == highlightID) {
                            viewer = ViewerImage(image: $0)
                        }
                    }
                    if loading {
                        ProgressView().padding(40)
                    }
                    if let error {
                        VStack(spacing: 10) {
                            Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button("Повторить") { Task { await load(target) } }.buttonStyle(.glass)
                        }
                        .padding()
                    }
                }
                .padding(.horizontal)
            }
            .id(scrollKey)
            .onChange(of: scrollKey) { _, _ in
                guard let t = pendingScroll else { return }
                pendingScroll = nil
                Task {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    withAnimation { proxy.scrollTo(t, anchor: .top) }
                }
            }
        }
        .pageToolbar(page: page, pages: pages) { n in Task { await load(n) } }
        .navigationTitle(tx.tr(item.title))
        .navigationBarTitleDisplayMode(.inline)
        .translateTexts(allTexts)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                TranslateButton()
                Button {
                    store.toggle(item)
                } label: {
                    Image(systemName: store.contains(item) ? "bookmark.fill" : "bookmark")
                }
            }
        }
        .fullScreenCover(item: $viewer) { ImageViewer(image: $0.image) }
        .task { if posts.isEmpty && error == nil && !loading { await load(1) } }
    }

    private func load(_ n: Int) async {
        guard !loading else { return }
        loading = true
        error = nil
        target = n
        posts = []
        let base = canonical ?? item.url
        let url = (canonical != nil && n > 1) ? base.appendingPathComponent("page-\(n)") : base
        let result = await fetch(url, Parser.posts)
        switch result {
        case .loaded(let r):
            posts = r.posts
            pages = max(r.pages, 1)
            page = n
            if canonical == nil {
                if let cur = WebLoader.shared.webView.url {
                    // Links like /posts/123/ redirect to /threads/slug/page-N#post-123: normalise.
                    targetPost = Parser.postID(from: item.url) ?? Parser.postID(from: cur)
                    var comps = URLComponents(url: cur, resolvingAgainstBaseURL: false)
                    comps?.fragment = nil
                    comps?.query = nil
                    var b = comps?.url ?? cur
                    if b.lastPathComponent.hasPrefix("page-") {
                        page = Int(b.lastPathComponent.dropFirst(5)) ?? n
                        pages = max(pages, page)
                        b = b.deletingLastPathComponent()
                    }
                    canonical = b
                }
                if let t = targetPost, r.posts.contains(where: { $0.postID == t }) {
                    highlightID = t
                    pendingScroll = t
                }
            } else {
                highlightID = nil
            }
            scrollKey += 1
        case .failed(let m):
            error = m
        default:
            break
        }
        loading = false
    }
}

// MARK: - Bookmarks

struct BookmarksView: View {
    private let store = BookmarkStore.shared

    var body: some View {
        NavigationStack {
            Group {
                if store.items.isEmpty {
                    ContentUnavailableView("Закладок нет", systemImage: "bookmark",
                                           description: Text("Нажмите на закладку в теме, чтобы сохранить её."))
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(store.items) { t in
                                NavigationLink(value: t) { ThreadRow(item: t) }.buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("Закладки")
            .navigationDestination(for: ThreadItem.self) { ThreadView(item: $0) }
        }
    }
}

// MARK: - Profile / login

struct ProfileView: View {
    @State private var showBrowser = false
    private let auth = AuthState.shared

    var body: some View {
        NavigationStack {
            List {
                Section("Аккаунт") {
                    if auth.checking {
                        HStack { ProgressView(); Text("Проверяем вход…").foregroundStyle(.secondary) }
                    } else if auth.loggedIn {
                        Label(auth.username.isEmpty ? "Вы вошли" : "Вы вошли как \(auth.username)",
                              systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Button("Выйти", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            Task {
                                await WebLoader.shared.clearSession()
                                await auth.refresh()
                            }
                        }
                    } else {
                        Button("Войти", systemImage: "person.badge.key") { showBrowser = true }
                        if let e = auth.error {
                            Text(e).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Button("Пройти проверку / открыть сайт", systemImage: "safari") { showBrowser = true }
                    Button("Обновить статус", systemImage: "arrow.clockwise") {
                        Task { await auth.refresh() }
                    }
                }
                Section("О приложении") {
                    Text("Неофициальный клиент. Страницы загружаются через встроенный браузер и разбираются нативно.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Профиль")
            .task { await auth.refresh() }
            .sheet(isPresented: $showBrowser, onDismiss: { Task { await auth.refresh() } }) {
                NavigationStack {
                    SharedWebView()
                        .ignoresSafeArea(edges: .bottom)
                        .navigationTitle("Вход")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Готово") { showBrowser = false }
                            }
                        }
                        .onAppear {
                            WebLoader.shared.webView.load(URLRequest(url: Config.loginURL))
                        }
                }
            }
        }
    }
}
