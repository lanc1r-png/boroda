import SwiftUI
import Observation

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

struct ViewerImage: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ImageViewer: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(
                    MagnifyGesture()
                        .onChanged { scale = max(1, $0.magnification) }
                        .onEnded { _ in withAnimation { scale = 1 } }
                )
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).padding(14)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .padding()
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

        for u in ref.candidates {
            do {
                image = try await ImageLoader.load(u)
                return
            } catch {
                if isCancel(error) { return }   // view scrolled away: retry on reappear
                notes.append(error.localizedDescription)
            }
        }
        // Fallback: let the in-app browser fetch it (cookies, Cloudflare, Referer)
        for u in ref.candidates.prefix(2) {
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
        .task { await AuthState.shared.refresh() }
    }
}

// MARK: - Search (thread titles)

struct SearchView: View {
    @State private var query = ""
    @State private var state: LoadState<[ThreadItem]> = .idle

    var body: some View {
        NavigationStack {
            Group {
                if case .idle = state {
                    ContentUnavailableView("Поиск по названиям тем", systemImage: "magnifyingglass",
                                           description: Text("Введите запрос и нажмите «Поиск»."))
                } else {
                    StateView(state: state, retry: run) { items in
                        ThreadListView(items: items, reload: run)
                    }
                }
            }
            .navigationTitle("Поиск")
            .navigationDestination(for: ThreadItem.self) { ThreadView(item: $0) }
        }
        .searchable(text: $query, prompt: "Название темы")
        .onSubmit(of: .search) { Task { await run() } }
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        state = .loading
        do {
            let html = try await WebLoader.shared.search(q)
            state = .loaded(try Parser.latest(html))
        } catch {
            state = .failed(error.localizedDescription)
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

    var body: some View {
        StateView(state: state, retry: load) { forums in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(forums) { f in
                        NavigationLink(value: f) {
                            Card {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(f.title).font(.headline)
                                    if !f.desc.isEmpty {
                                        Text(f.desc).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.headline).multilineTextAlignment(.leading)
                HStack {
                    if !item.author.isEmpty { Text(item.author).font(.caption.weight(.semibold)) }
                    Text(item.meta).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
        .navigationTitle(forum.title)
        .navigationBarTitleDisplayMode(.inline)
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

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(Color.accentColor).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                if !author.isEmpty {
                    Text(author).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(12)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct PostView: View {
    let post: Post
    let onImage: (UIImage) -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(post.author).font(.subheadline.weight(.bold))
                    Spacer()
                    Text(post.date).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(post.parts.enumerated()), id: \.offset) { _, part in
                    switch part {
                    case .text(let t):
                        Text(t)
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
    private let store = BookmarkStore.shared

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(posts) { p in
                    PostView(post: p) { viewer = ViewerImage(image: $0) }
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
        .pageToolbar(page: page, pages: pages) { n in Task { await load(n) } }
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
            scrollKey += 1
            if canonical == nil, let cur = WebLoader.shared.webView.url {
                // Links like /posts/123/ redirect to /threads/slug/page-N: normalise.
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
