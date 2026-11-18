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

struct ForumThreadsView: View {
    let forum: Forum
    @State private var state: LoadState<[ThreadItem]> = .idle

    var body: some View {
        StateView(state: state, retry: load) { items in
            ThreadListView(items: items, reload: load)
        }
        .navigationTitle(forum.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { if case .idle = state { await load() } }
    }

    private func load() async {
        state = .loading
        state = await fetch(forum.url, Parser.threads)
    }
}

// MARK: - Thread

struct IdentURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}

struct ImageViewer: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFit()
                        .scaleEffect(scale)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { scale = max(1, $0.magnification) }
                                .onEnded { _ in withAnimation { scale = 1 } }
                        )
                } else if phase.error != nil {
                    Text("Не удалось загрузить").foregroundStyle(.white)
                } else {
                    ProgressView()
                }
            }
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).padding(14)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .padding()
        }
    }
}

struct PostView: View {
    let post: Post
    @State private var viewing: IdentURL?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(post.author).font(.subheadline.weight(.bold))
                    Spacer()
                    Text(post.date).font(.caption).foregroundStyle(.secondary)
                }
                if !post.text.characters.isEmpty {
                    Text(post.text).textSelection(.enabled)
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
                ForEach(post.images, id: \.self) { url in
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit()
                                .frame(maxWidth: .infinity, maxHeight: 520)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .onTapGesture { viewing = IdentURL(url: url) }
                        case .failure:
                            Link(destination: url) {
                                Label("Открыть изображение", systemImage: "photo").font(.caption)
                            }
                        default:
                            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                        }
                    }
                }
            }
        }
        .fullScreenCover(item: $viewing) { ImageViewer(url: $0.url) }
    }
}

struct ThreadView: View {
    let item: ThreadItem
    @State private var posts: [Post] = []
    @State private var page = 0
    @State private var pages = 1
    @State private var loading = false
    @State private var error: String?
    @State private var canonical: URL?
    private let store = BookmarkStore.shared

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(posts) { PostView(post: $0) }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.secondary).padding()
                }
                if loading {
                    ProgressView().padding()
                } else if page < pages || (posts.isEmpty && error != nil) {
                    Button(posts.isEmpty ? "Повторить" : "Загрузить ещё (\(page)/\(pages))") {
                        Task { await loadNext() }
                    }
                    .buttonStyle(.glass)
                    .padding()
                }
            }
            .padding(.horizontal)
        }
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
        .task { if posts.isEmpty { await loadNext() } }
    }

    private func loadNext() async {
        guard !loading else { return }
        loading = true
        error = nil
        let next = page + 1
        let url = next == 1 ? item.url : (canonical ?? item.url).appendingPathComponent("page-\(next)")
        let result = await fetch(url, Parser.posts)
        switch result {
        case .loaded(let r):
            posts.append(contentsOf: r.posts)
            pages = r.pages
            page = next
            if next == 1, let cur = WebLoader.shared.webView.url {
                // Links like /posts/123/ redirect to /threads/slug/page-N: normalise.
                var base = cur
                var comps = URLComponents(url: cur, resolvingAgainstBaseURL: false)
                comps?.fragment = nil
                comps?.query = nil
                base = comps?.url ?? cur
                if base.lastPathComponent.hasPrefix("page-") {
                    page = Int(base.lastPathComponent.dropFirst(5)) ?? 1
                    base = base.deletingLastPathComponent()
                }
                canonical = base
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
