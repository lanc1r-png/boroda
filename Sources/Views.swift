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

// MARK: - Root

struct RootView: View {
    var body: some View {
        TabView {
            Tab("Главная", systemImage: "house.fill") { HomeView() }
            Tab("Закладки", systemImage: "bookmark.fill") { BookmarksView() }
            Tab("Профиль", systemImage: "person.crop.circle") { ProfileView() }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
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

struct PostView: View {
    let post: Post
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(post.author).font(.subheadline.weight(.bold))
                    Spacer()
                    Text(post.date).font(.caption).foregroundStyle(.secondary)
                }
                if !post.text.isEmpty {
                    Text(post.text).textSelection(.enabled)
                }
                ForEach(post.images, id: \.self) { url in
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                        case .failure:
                            Label("Не удалось загрузить", systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                        default:
                            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                        }
                    }
                }
            }
        }
    }
}

struct ThreadView: View {
    let item: ThreadItem
    @State private var posts: [Post] = []
    @State private var page = 0
    @State private var pages = 1
    @State private var loading = false
    @State private var error: String?
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
        let url = next == 1 ? item.url : item.url.appendingPathComponent("page-\(next)")
        let result = await fetch(url, Parser.posts)
        switch result {
        case .loaded(let r):
            posts.append(contentsOf: r.posts)
            pages = r.pages
            page = next
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

    var body: some View {
        NavigationStack {
            List {
                Section("Аккаунт") {
                    Button("Войти / пройти проверку", systemImage: "person.badge.key") {
                        showBrowser = true
                    }
                    Button("Выйти (очистить сессию)", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        Task { await WebLoader.shared.clearSession() }
                    }
                }
                Section("О приложении") {
                    Text("Неофициальный клиент. Страницы загружаются через встроенный браузер и разбираются нативно.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Профиль")
            .sheet(isPresented: $showBrowser) {
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
