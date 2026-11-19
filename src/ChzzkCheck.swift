// 치지직 점검.app : 번들 안의 check.mjs 를 한 번 실행해 그 결과(JSON)를 화면에 보여 주는 껍데기.
// 판정 로직은 전부 check.mjs 에 있다. 창을 닫으면 앱도 끝난다(상시 프로세스 없음).
import Charts
import SwiftUI

// MARK: - check.mjs --json 출력

struct Chat: Decodable { let t: Double; let member: Int?; let who: String }
struct Point: Decodable { let t: Double; let member: Int }
struct Jump: Decodable { let from: Point; let to: Point }
struct Prev: Decodable { let time: String; let viewers: Int; let chatUsers: String }

struct Hist: Decodable {
    let time: String
    let openDate: String
    let viewers: Int
    let chatUsers: Int?
    let followers: Int?
    let signals: Int
}

struct PPoint: Decodable { let min: Double; let viewers: Int; let chatUsers: Int? }
struct PMark: Decodable { let time: String; let viewers: Int }

/// 방송 한 편의 기록(점검 + 지켜보기)
struct Broadcast: Decodable, Identifiable {
    var id: String { openDate }
    let openDate: String
    let count: Int
    let rose: Bool
    let low: PMark?
    let high: PMark?
    let points: [PPoint]
    var label: String { String(openDate.dropFirst(5).prefix(11)) }   // "11-19 22:30"
}

struct Pattern: Decodable { let broadcasts: [Broadcast]; let roseCount: Int; let text: String }
struct WatchRow: Decodable { let t: Double; let viewers: Int; let chatUsers: Int? }

/// 지켜보기 화면에 넘기는 상태
struct WatchState { let rows: [WatchRow]; let jump: Jump?; let range: [Int]; let active: Bool }

struct Snap: Decodable {
    let checkedAt: Double
    let serverDate: String?
    let channelId: String
    let name: String
    let followers: Int?
    let title: String
    let category: String
    let openDate: String
    let viewers: Int
    let chatGroup: String
    let chatCondition: String
    let thumbUrl: String?
    let vodViews: [Int]
    let chatUsers: Int?
    let chats: [Chat]
}

struct Analysis: Decodable {
    let lastChatMin: Int?
    let chats30: Int
    let chatters30: Int
    let vodMedian: Int?
    let series: [Point]
    let jump: Jump?
    let chatSpanMin: Double?
    let chatRate: Double?
    let chatters: Int
    let topShare: Double?
    let signals: [String]
}

struct Event: Decodable {
    let type: String
    let s: Snap?
    let a: Analysis?
    let prev: Prev?
    let dir: String?
    let text: String?
    let history: [Hist]?
    let pattern: Pattern?
    let channelDir: String?
    let channelId: String?
    let rows: [WatchRow]?
    let row: WatchRow?
    let jump: Jump?
    let range30: [Int]?
    let total: Int?
    let name: String?
    let message: String?
}

struct CheckResult: Identifiable {
    var id: String { s.channelId }
    let s: Snap
    let a: Analysis
    let prev: Prev?
    let dir: String?
    let text: String
    let history: [Hist]
    let pattern: Pattern?
    let channelDir: String?

    var liveURL: URL { URL(string: "https://chzzk.naver.com/live/\(s.channelId)")! }
    /// 채팅방 접속 인원 / 시청자수
    var ratio: Double? {
        guard let c = s.chatUsers, s.viewers > 0 else { return nil }
        return Double(c) / Double(s.viewers)
    }
    /// 시청자 100명당 분당 채팅 수
    var ratePer100: Double? {
        guard let r = a.chatRate, s.viewers > 0 else { return nil }
        return r / Double(s.viewers) * 100
    }
}

struct Fav: Codable, Identifiable { let id: String; var name: String }

/// 지금 목록에 있는 방송들의 중앙값. 5곳 이상일 때만 비교 기준으로 쓴다.
struct Baseline { var ratio: Double?; var ratePer100: Double? }

enum SortMode: String, CaseIterable { case signals = "신호", viewers = "시청자", ratio = "채팅방 비율" }

func date(_ ms: Double) -> Date { Date(timeIntervalSince1970: ms / 1000) }
func rate(_ v: Double) -> String { v < 10 ? String(format: "%.1f", v) : String(Int(v.rounded())) }
func median(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.sorted()[v.count / 2] }

extension Color {
    /// 아이콘의 차트 선과 같은 초록
    static let brand = Color(red: 0.10, green: 0.76, blue: 0.55)
}

// MARK: - 실행과 상태

@MainActor @Observable
final class Store {
    var results: [CheckResult] = []
    var selection: String?
    var busy = false
    var done = 0
    var total = 0
    var status = ""
    var input = ""
    var focusTick = 0          // 메뉴의 "주소 입력"이 올리면 입력칸에 커서가 간다
    var minViewers = 10
    var maxViewers = 100
    var limit = 30
    var category = ""
    var sortMode = SortMode.signals
    var dataDir: String { didSet { UserDefaults.standard.set(dataDir, forKey: "dataDir") } }
    var favorites: [Fav] { didSet { UserDefaults.standard.set(try? JSONEncoder().encode(favorites), forKey: "favorites") } }
    // 지켜보기: 앱이 열려 있고 직접 켰을 때만 도는 30초 간격 기록
    var watching = false
    var watchId: String?
    var watchName = ""
    var watchRows: [WatchRow] = []
    var watchJump: Jump?
    var watchRange: [Int] = []
    private var watchProcess: Process?
    private var process: Process?
    private var offline: [String] = []
    /// 앱이 끝날 때 남은 프로세스를 정리하려고 AppDelegate 가 찾는다
    static weak var current: Store?

    static let script = Bundle.main.url(forResource: "check", withExtension: "mjs")
    static let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node"].first { FileManager.default.isExecutableFile(atPath: $0) }
    /// 증거와 기록을 쌓는 기본 폴더. 설정(⌘,)에서 바꿀 수 있다.
    static let defaultDataDir = NSHomeDirectory() + "/Documents/치지직 점검"

    init() {
        dataDir = UserDefaults.standard.string(forKey: "dataDir") ?? Self.defaultDataDir
        favorites = UserDefaults.standard.data(forKey: "favorites").flatMap { try? JSONDecoder().decode([Fav].self, from: $0) } ?? []
        Self.current = self
    }

    func watchState(for id: String) -> WatchState? {
        guard watchId == id, !watchRows.isEmpty else { return nil }
        return WatchState(rows: watchRows, jump: watchJump, range: watchRange, active: watching)
    }

    var selected: CheckResult? { results.first { $0.id == selection } }

    var sorted: [CheckResult] {
        let e = results.enumerated()
        switch sortMode {
        case .signals:   // 신호 많은 순, 같으면 점검한 순
            return e.sorted { ($0.element.a.signals.count, -$0.offset) > ($1.element.a.signals.count, -$1.offset) }.map(\.element)
        case .viewers:
            return e.sorted { ($0.element.s.viewers, -$0.offset) > ($1.element.s.viewers, -$1.offset) }.map(\.element)
        case .ratio:     // 채팅방 비율이 낮은 방송부터. 값을 못 받은 방송은 맨 뒤
            return e.sorted { ($0.element.ratio ?? .infinity, $0.offset) < ($1.element.ratio ?? .infinity, $1.offset) }.map(\.element)
        }
    }

    var baseline: Baseline {
        guard results.count >= 5 else { return Baseline() }
        return Baseline(ratio: median(results.compactMap(\.ratio)), ratePer100: median(results.compactMap(\.ratePer100)))
    }

    // MARK: 점검

    func checkInput() {
        let v = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !v.isEmpty else { return }
        run([v], select: true)
    }

    func recheckSelected() {
        guard let id = selection else { return }
        run([id], select: true)
    }

    func scan() {
        var args = ["scan", "--min", "\(minViewers)", "--max", "\(maxViewers)", "--limit", "\(limit)"]
        if !category.isEmpty { args += ["--category", category] }
        selection = nil
        run(args, select: false)
    }

    func checkFavorites() {
        guard !favorites.isEmpty else { return }
        selection = nil
        run(favorites.map(\.id), select: false)
    }

    func remove(_ id: String) {
        results.removeAll { $0.id == id }
        if selection == id { selection = nil }
    }

    func cancel() { process?.terminate() }

    /// 실제 채널이 아닌 예시 데이터를 보여 준다. 네트워크를 쓰지 않고 아무것도 저장하지 않는다.
    func showDemo() {
        selection = nil
        run(["demo"], select: false)
    }

    // MARK: 관심 채널

    func isFavorite(_ id: String) -> Bool { favorites.contains { $0.id == id } }

    func toggleFavorite(_ r: CheckResult) {
        if isFavorite(r.id) { favorites.removeAll { $0.id == r.id } } else { favorites.append(Fav(id: r.id, name: r.s.name)) }
    }

    // MARK: 지켜보기

    func toggleWatch() {
        if watching { stopWatch() } else if let r = selected { startWatch(r) }
    }

    func startWatch(_ r: CheckResult) {
        stopWatch()
        watchId = r.id; watchName = r.s.name; watchRows = []; watchJump = nil; watchRange = []
        watchProcess = spawn(["watch", r.id, "--interval", "30"], onLine: { [weak self] line in
            guard let self, let e = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)) else { return }
            if e.type == "tick", e.channelId == self.watchId {
                if let rows = e.rows { self.watchRows = rows } else if let row = e.row { self.watchRows.append(row) }
                self.watchJump = e.jump
                self.watchRange = e.range30 ?? []
            } else if e.type == "watchEnd" {
                self.status = e.message ?? "지켜보기가 끝났습니다"
            }
        }, onEnd: { [weak self] _ in
            self?.watching = false
            self?.watchProcess = nil
        })
        watching = watchProcess != nil
    }

    func stopWatch() {
        watchProcess?.terminate()
        watchProcess = nil
        watching = false
    }

    func stopAll() {
        stopWatch()
        process?.terminate()
    }

    // MARK: 내보내기

    func copySummary() {
        guard let r = selected else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(r.text, forType: .string)
        status = "요약문을 복사했습니다"
    }

    private func png<V: View>(_ view: V) -> Data? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func write(_ data: Data?, to url: URL, done: String) {
        guard let data else { status = "보고서를 만들지 못했습니다"; return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            status = done
        } catch {
            status = "보고서를 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: d)
    }

    /// 화면에 보이는 점검 결과를 그림 한 장으로 저장한다 (신고할 때 첨부용)
    func saveReport() {
        guard let r = selected else { return }
        let dir = r.dir ?? dataDir + "/보고서"
        let name = r.dir != nil ? "보고서.png" : "\(r.s.name.replacingOccurrences(of: "/", with: "_"))_\(stamp(date(r.s.checkedAt))).png"
        write(png(ReportView(r: r, baseline: baseline, watch: watchState(for: r.id))),
              to: URL(fileURLWithPath: dir).appendingPathComponent(name), done: "보고서 그림을 저장했습니다")
    }

    /// 이 채널의 여러 방송 기록을 한 장으로 묶는다. 요약문(.txt)도 같이 저장한다.
    func savePatternReport() {
        guard let r = selected, let pattern = r.pattern, let dir = r.channelDir else { return }
        let base = URL(fileURLWithPath: dir).appendingPathComponent("반복패턴_\(stamp(Date()))")
        write(png(PatternReportView(r: r, pattern: pattern)), to: base.appendingPathExtension("png"), done: "반복 패턴 보고서를 저장했습니다")
        try? pattern.text.write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
    }

    func openStats() {
        // 채널 이름으로 검색하도록 이름을 클립보드에 넣어 둔다
        if let r = selected {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(r.s.name, forType: .string)
            status = "채널 이름을 복사했습니다. 통계 사이트 검색칸에 붙여 넣으세요."
        }
        NSWorkspace.shared.open(URL(string: "https://viewership.softc.one/")!)
    }

    func openEvidence() {
        if let dir = selected?.dir { NSWorkspace.shared.open(URL(fileURLWithPath: dir)) }
    }

    func openLive() {
        if let r = selected { NSWorkspace.shared.open(r.liveURL) }
    }

    func openDataDir() { NSWorkspace.shared.open(URL(fileURLWithPath: dataDir)) }

    // MARK: check.mjs 실행

    /// check.mjs 를 띄워 한 줄씩 받는다. 띄우지 못하면 nil.
    private func spawn(_ extra: [String], onLine: @escaping @MainActor (String) -> Void,
                       onEnd: @escaping @MainActor (String) -> Void) -> Process? {
        guard let node = Self.node else { status = "Node.js 를 찾지 못했습니다. brew install node 로 설치해 주세요."; return nil }
        guard let script = Self.script else { status = "앱 안에 check.mjs 가 없습니다. 다시 빌드해 주세요."; return nil }
        do {
            try FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        } catch {
            status = "저장 폴더를 만들 수 없습니다: \(dataDir)"
            return nil
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = [script.path, "--json"] + extra
        p.environment = ProcessInfo.processInfo.environment.merging(["CHZZK_CHECK_DIR": dataDir]) { $1 }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        Task {
            do {
                try p.run()
                for try await line in out.fileHandleForReading.bytes.lines { onLine(line) }
                let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                onEnd(e.trimmingCharacters(in: .whitespacesAndNewlines))
            } catch {
                onEnd(error.localizedDescription)
            }
        }
        return p
    }

    func run(_ extra: [String], select: Bool) {
        guard !busy else { return }
        done = 0; total = 0; status = ""; offline = []
        process = spawn(extra, onLine: { [weak self] in self?.handle($0, select: select) }, onEnd: { [weak self] err in
            guard let self else { return }
            if self.status.isEmpty, !err.isEmpty { self.status = err }
            if !self.offline.isEmpty { self.status = "지금 방송 중이 아님: " + self.offline.joined(separator: ", ") }
            self.busy = false
            self.process = nil
            if self.selection == nil { self.selection = self.sorted.first?.id }
        })
        busy = process != nil
    }

    private func handle(_ line: String, select: Bool) {
        guard let e = try? JSONDecoder().decode(Event.self, from: Data(line.utf8)) else { return }
        switch e.type {
        case "start": total = e.total ?? 0
        case "result":
            guard let s = e.s, let a = e.a else { return }
            let r = CheckResult(s: s, a: a, prev: e.prev, dir: e.dir, text: e.text ?? "", history: e.history ?? [],
                                pattern: e.pattern, channelDir: e.channelDir)
            if let i = results.firstIndex(where: { $0.id == r.id }) { results[i] = r } else { results.append(r) }
            done += 1
            if select { selection = r.id }
            // 관심 채널 이름이 바뀌었으면 따라간다
            if let i = favorites.firstIndex(where: { $0.id == r.id }), favorites[i].name != s.name { favorites[i].name = s.name }
        case "offline": offline.append(e.name ?? "?")
        case "error": status = e.message ?? "점검 실패"
        default: break
        }
    }
}

// MARK: - 왼쪽: 입력과 목록

struct ContentView: View {
    @Bindable var store: Store
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                controls
                Divider()
                resultList
            }
            .navigationSplitViewColumnWidth(min: 290, ideal: 320, max: 440)
        } detail: {
            if let r = store.selected {
                ScrollView {
                    DetailContent(r: r, baseline: store.baseline, forReport: false, watch: store.watchState(for: r.id),
                                  onStopWatch: { store.stopWatch() }, onSavePattern: { store.savePatternReport() },
                                  onOpenStats: { store.openStats() }).padding(20)
                }
                .id(r.id)   // 다른 방송을 고르면 맨 위부터 보이게
            } else {
                ContentUnavailableView {
                    Label("점검할 방송을 넣어 주세요", systemImage: "chart.line.uptrend.xyaxis")
                } description: {
                    Text("방송 주소를 붙여 넣고 점검을 누르거나, 방송 훑어보기로 여러 방송을 한 번에 살펴봅니다.")
                } actions: {
                    Button("주소 입력") { inputFocused = true }
                    Button("방송 훑어보기") { store.scan() }.disabled(store.busy)
                }
            }
        }
        .navigationTitle(store.selected?.s.name ?? "치지직 점검")
        .navigationSubtitle(store.selected.map {
            "시청자 \($0.s.viewers)명 · \(date($0.s.checkedAt).formatted(date: .omitted, time: .shortened)) 점검"
        } ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                let r = store.selected
                Button { store.recheckSelected() } label: { Label("다시 점검", systemImage: "arrow.clockwise") }
                    .help("이 방송을 다시 점검하고 증거를 저장합니다 (⌘R)")
                    .disabled(r == nil || store.busy)
                Button { r.map(store.toggleFavorite) } label: {
                    Label("관심 채널", systemImage: r.map { store.isFavorite($0.id) } == true ? "star.fill" : "star")
                }
                .help("관심 채널에 넣거나 뺍니다. 관심 채널은 한 번에 모두 점검할 수 있습니다 (⌘D)")
                .disabled(r == nil)
                Button { store.toggleWatch() } label: {
                    Label(store.watching ? "지켜보기 중지" : "지켜보기", systemImage: store.watching ? "eye.fill" : "eye")
                }
                .help(store.watching
                      ? "\(store.watchName) 지켜보기를 멈춥니다 (⌘K)"
                      : "이 방송을 30초마다 기록합니다. 앱이 열려 있는 동안만 돌고, 창을 닫으면 멈춥니다 (⌘K)")
                .disabled(r == nil && !store.watching)
                Button { store.copySummary() } label: { Label("요약 복사", systemImage: "doc.on.doc") }
                    .help("신고할 때 붙여 넣을 요약문을 복사합니다 (⇧⌘C)")
                    .disabled(r == nil)
                Button { store.saveReport() } label: { Label("보고서 저장", systemImage: "square.and.arrow.down") }
                    .help("이 화면을 그림 한 장으로 저장합니다. 신고할 때 첨부할 수 있습니다 (⌘S)")
                    .disabled(r == nil)
                Button { store.openEvidence() } label: { Label("증거 폴더", systemImage: "folder") }
                    .help(r?.dir == nil
                          ? "훑어보기에서는 신호가 2건 이상일 때만 저장합니다. 다시 점검을 누르면 저장됩니다."
                          : "요약문, 원본 데이터, 방송 화면 사진이 든 폴더를 엽니다 (⇧⌘E)")
                    .disabled(r?.dir == nil)
                Button { store.openLive() } label: { Label("방송 열기", systemImage: "play.rectangle") }
                    .help("브라우저에서 이 방송을 엽니다 (⇧⌘O)")
                    .disabled(r == nil)
            }
        }
        .onChange(of: store.focusTick) { inputFocused = true }
        .task {
            // 실행 인자로 채널을 주면 바로 점검: open -a "치지직 점검" --args -check <주소 또는 ID>
            // (그냥 값만 넘기면 AppKit 이 파일 열기로 받아들여 창이 안 뜬다)
            if let id = UserDefaults.standard.string(forKey: "check"), !id.isEmpty {
                store.input = id
                store.checkInput()
            } else if UserDefaults.standard.bool(forKey: "demo") {   // --args -demo 1 : 예시 데이터로 시작
                store.showDemo()
            } else {
                inputFocused = true
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("방송 주소 또는 채널 ID", text: $store.input)
                    .textFieldStyle(.roundedBorder)
                    .focused($inputFocused)
                    .onSubmit { store.checkInput() }
                Button("점검") { store.checkInput() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.busy || store.input.isEmpty)
            }
            DisclosureGroup("방송 훑어보기") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("시청자")
                        TextField("최소", value: $store.minViewers, format: .number).frame(width: 52)
                        Text("~")
                        TextField("최대", value: $store.maxViewers, format: .number).frame(width: 52)
                        Text("명")
                    }
                    HStack {
                        Text("개수")
                        TextField("개수", value: $store.limit, format: .number).frame(width: 52)
                        TextField("카테고리 (비우면 전체)", text: $store.category)
                    }
                    Button("훑어보기") { store.scan() }.disabled(store.busy)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 4)
            }
            if !store.favorites.isEmpty {
                DisclosureGroup("관심 채널 \(store.favorites.count)곳") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.favorites) { f in
                            HStack {
                                Button(f.name) { store.run([f.id], select: true) }
                                    .buttonStyle(.link).disabled(store.busy)
                                Spacer()
                                Button { store.favorites.removeAll { $0.id == f.id } } label: { Image(systemName: "xmark") }
                                    .buttonStyle(.borderless).help("관심 채널에서 빼기")
                                    .accessibilityLabel("\(f.name) 관심 채널에서 빼기")
                            }
                        }
                        Button("모두 점검") { store.checkFavorites() }.disabled(store.busy)
                    }
                    .padding(.top, 4)
                }
            }
            if store.busy {
                HStack {
                    if store.total > 0 {
                        ProgressView(value: Double(store.done), total: Double(store.total))
                        Text("\(store.done)/\(store.total)").font(.caption).monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                        Text("점검 중").font(.caption)
                    }
                    Button("중지") { store.cancel() }.controlSize(.small)
                }
            }
            if store.watching {
                HStack(spacing: 6) {
                    Image(systemName: "eye.fill").foregroundStyle(.red)
                    Text("지켜보는 중: \(store.watchName) · \(store.watchRows.count)회").font(.caption).lineLimit(1)
                    Spacer()
                    Button("중지") { store.stopWatch() }.controlSize(.small)
                }
            }
            if !store.status.isEmpty {
                Text(store.status).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.results.count > 1 {
                Picker("정렬", selection: $store.sortMode) {
                    ForEach(SortMode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                .help("목록 정렬: 의심 신호 많은 순, 시청자 많은 순, 채팅방 접속 비율이 낮은 순")
            }
        }
        .padding(12)
    }

    private var resultList: some View {
        List(selection: $store.selection) {
            let flagged = store.sorted.filter { !$0.a.signals.isEmpty }
            let clean = store.sorted.filter { $0.a.signals.isEmpty }
            if !flagged.isEmpty {
                Section("의심 신호 있음 \(flagged.count)곳") { ForEach(flagged) { row($0) } }
            }
            if !clean.isEmpty {
                Section("신호 없음 \(clean.count)곳") { ForEach(clean) { row($0) } }
            }
        }
        .overlay {
            if store.results.isEmpty {
                Text("점검한 방송이 여기에 쌓입니다").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }

    private func row(_ r: CheckResult) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(r.s.name).fontWeight(.medium).lineLimit(1)
                    if store.isFavorite(r.id) {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                            .accessibilityLabel("관심 채널")
                    }
                }
                Text("시청자 \(r.s.viewers) · 채팅방 \(r.s.chatUsers.map(String.init) ?? "?") · 채팅 분당 \(r.a.chatRate.map(rate) ?? "?")개")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !r.a.signals.isEmpty {
                Text("\(r.a.signals.count)")
                    .font(.caption.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(.red, in: Capsule())
                    .accessibilityLabel("의심 신호 \(r.a.signals.count)건")
            }
        }
        .contextMenu {
            Button("다시 점검") { store.run([r.id], select: true) }.disabled(store.busy)
            Button("방송 열기") { NSWorkspace.shared.open(r.liveURL) }
            Button(store.isFavorite(r.id) ? "관심 채널에서 빼기" : "관심 채널에 넣기") { store.toggleFavorite(r) }
            Divider()
            Button("목록에서 지우기") { store.remove(r.id) }
        }
    }
}

// MARK: - 오른쪽: 점검 결과

struct Tile: View {
    let label: String
    let value: String
    var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold)).monospacedDigit()
            Text(note.isEmpty ? " " : note).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}

struct Card<Content: View>: View {
    let title: String
    var note = ""
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
            if !note.isEmpty {
                Text(note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct Bucket: Identifiable { let id: Int; let start: Date; let end: Date; let count: Int }

/// 방송별 시청자수를 "방송 시작 후 경과 시간"에 맞춰 겹쳐 그린다. 같은 모양이 되풀이되는지 보는 용도.
struct BroadcastCompare: View {
    let pattern: Pattern

    var body: some View {
        let shown = Array(pattern.broadcasts.suffix(8))
        VStack(alignment: .leading, spacing: 8) {
            Text("기록된 방송 \(pattern.broadcasts.count)편 중 \(pattern.roseCount)편에서 방송 도중 시청자수가 10명 이상, 1.5배 이상 늘었습니다.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Chart {
                ForEach(shown) { b in
                    ForEach(b.points.indices, id: \.self) { i in
                        LineMark(x: .value("경과 시간", b.points[i].min / 60), y: .value("시청자수", b.points[i].viewers),
                                 series: .value("방송", b.label))
                            .foregroundStyle(by: .value("방송", b.label))
                        if b.points.count <= 40 {
                            PointMark(x: .value("경과 시간", b.points[i].min / 60), y: .value("시청자수", b.points[i].viewers))
                                .symbolSize(20)
                                .foregroundStyle(by: .value("방송", b.label))
                        }
                    }
                }
            }
            .chartXAxisLabel("방송 시작 후 경과 시간(시간)")
            .chartYAxisLabel("시청자수")
            .frame(height: 220)
            ForEach(shown) { b in
                HStack(spacing: 8) {
                    Text(b.label).monospacedDigit().fontWeight(.medium)
                    Text("기록 \(b.count)회").foregroundStyle(.secondary)
                    if let lo = b.low, let hi = b.high {
                        Text("최저 \(lo.viewers)명(\(lo.time)) → 이후 최고 \(hi.viewers)명(\(hi.time))")
                    }
                    if b.rose {
                        Text("크게 늘어남").font(.caption2.bold()).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(.red, in: Capsule())
                    }
                }
                .font(.caption)
            }
        }
    }
}

/// 화면과 보고서 그림이 함께 쓰는 본문
struct DetailContent: View {
    let r: CheckResult
    let baseline: Baseline
    let forReport: Bool
    var watch: WatchState?
    var onStopWatch: (() -> Void)?
    var onSavePattern: (() -> Void)?
    var onOpenStats: (() -> Void)?
    private var s: Snap { r.s }
    private var a: Analysis { r.a }

    private var elapsed: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "Asia/Seoul")
        guard let open = f.date(from: s.openDate) else { return "" }
        let m = max(0, Int(date(s.checkedAt).timeIntervalSince(open) / 60))
        return "\(m / 60)시간 \(m % 60)분 경과"
    }

    /// 세 시간 그래프가 같은 가로축을 쓰게 한다
    private var startMs: Double { min(s.chats.first?.t ?? s.checkedAt, a.series.first?.t ?? s.checkedAt) }
    private var xDomain: ClosedRange<Date> { date(startMs)...date(max(s.checkedAt, startMs + 1000)) }
    private var shortSpan: Bool { s.checkedAt - startMs < 5 * 60_000 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            signals
            if let watch { watchCard(watch) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 10)], spacing: 10) { tiles }
            if !s.chats.isEmpty { activityChart }
            if a.series.count > 1 { memberChart }
            if !s.chats.isEmpty { whoChart }
            if let p = r.pattern, p.broadcasts.contains(where: { $0.count > 1 }) { patternCard(p) }
            screenshot
            Text("치지직 공개 정보만으로 본 결과입니다. 신호는 판정 기준을 넘었다는 뜻일 뿐 조작을 확정하지 않습니다. 실제 접속 기록은 치지직만 확인할 수 있으니, 신고할 때 참고 자료로 붙이세요.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(s.title).font(.title3.weight(.semibold)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(s.category) · 방송 시작 \(s.openDate) (\(elapsed))")
                .font(.callout).foregroundStyle(.secondary)
            if let p = r.prev {
                Text("같은 방송의 직전 점검: \(p.time) 시청자 \(p.viewers)명, 채팅방 \(p.chatUsers)명")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var signals: some View {
        let serious = a.signals.contains { !$0.hasPrefix("(참고)") }
        return VStack(alignment: .leading, spacing: 6) {
            if a.signals.isEmpty {
                Label("의심 신호 없음", systemImage: "checkmark.circle.fill").foregroundStyle(Color.brand)
            } else {
                Text("의심 신호 \(a.signals.count)건").font(.headline)
                ForEach(a.signals, id: \.self) { x in
                    let minor = x.hasPrefix("(참고)")
                    Label(x, systemImage: minor ? "info.circle" : "exclamationmark.triangle.fill")
                        .foregroundStyle(minor ? Color.secondary : Color.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background((serious ? Color.red : a.signals.isEmpty ? Color.brand : Color.gray).opacity(0.09),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var tiles: some View {
        Tile(label: "시청자수", value: "\(s.viewers.formatted())명")
        Tile(label: "채팅방 접속 인원", value: s.chatUsers.map { "\($0.formatted())명" } ?? "?",
             note: r.ratio.map { String(format: "시청자수의 %.1f배", $0) + (baseline.ratio.map { String(format: " · 목록 중앙값 %.1f배", $0) } ?? "") } ?? "받지 못함")
        Tile(label: "채팅 속도", value: a.chatRate.map { "분당 \(rate($0))개" } ?? "?",
             note: r.ratePer100.map { "시청자 100명당 \(rate($0))개" + (baseline.ratePer100.map { " · 목록 중앙값 \(rate($0))개" } ?? "") } ?? "채팅이 거의 없음")
        Tile(label: "채팅 참여 계정", value: "\(a.chatters)개",
             note: a.topShare.map { "최다 계정 비중 \(Int(($0 * 100).rounded()))% · 봇 포함 가능" } ?? "최근 채팅 없음")
        Tile(label: "마지막 채팅", value: a.lastChatMin.map { "\($0)분 전" } ?? "없음",
             note: "최근 30분 채팅 \(a.chats30)개 · 계정 \(a.chatters30)개")
        Tile(label: "팔로워", value: s.followers.map { "\($0.formatted())명" } ?? "?")
        Tile(label: "다시보기 조회수 중앙값", value: a.vodMedian.map { "\($0.formatted())회" } ?? "?",
             note: "최근 \(s.vodViews.count)개 기준")
    }

    private var timeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 6)) {
            AxisGridLine()
            AxisValueLabel(format: shortSpan ? Date.FormatStyle.dateTime.hour().minute().second() : Date.FormatStyle.dateTime.hour().minute())
        }
    }

    // 채팅 활동량: 최근 채팅을 일정한 시간 칸으로 나눠 칸마다 몇 개 올라왔는지
    private var bucketSec: Int {
        let span = (s.checkedAt - startMs) / 1000
        return [5, 10, 30, 60, 120, 300, 600, 900, 1800, 3600].first { Double($0) >= span / 30 } ?? 7200
    }

    private var buckets: [Bucket] {
        let size = Double(bucketSec) * 1000
        var counts: [Int: Int] = [:]
        for c in s.chats { counts[Int((c.t - startMs) / size), default: 0] += 1 }
        return counts.keys.sorted().map { i in
            let from = startMs + Double(i) * size
            return Bucket(id: i, start: date(from + size * 0.08), end: date(from + size * 0.92), count: counts[i] ?? 0)
        }
    }

    private var activityChart: some View {
        let unit = bucketSec < 60 ? "\(bucketSec)초" : "\(bucketSec / 60)분"
        return Card(title: "채팅 활동량 (\(unit) 단위)",
                    note: "막대는 그 시간 칸에 올라온 채팅 수입니다. 치지직이 내주는 최근 \(s.chats.count)개까지만 볼 수 있어서, 채팅이 많은 방송은 짧은 구간만 보입니다.") {
            Chart(buckets) { b in
                // BarMark 는 가로 구간을 주면 세로가 고정 두께가 되어, 0부터 채우는 막대는 RectangleMark 로 그린다
                RectangleMark(xStart: .value("시작", b.start), xEnd: .value("끝", b.end),
                              yStart: .value("바닥", 0), yEnd: .value("채팅 수", b.count))
                    .foregroundStyle(Color.brand)
                    .cornerRadius(2)
            }
            .chartXScale(domain: xDomain)
            .chartXAxis { timeAxis }
            .frame(height: 150)
        }
    }

    private var memberChart: some View {
        Card(title: "채팅방 접속 인원 변화",
             note: "점은 채팅이 올라온 순간에 찍힌 채팅방 인원입니다. 점 사이 구간은 실제 값을 모릅니다. 빨간 영역은 급증으로 판정한 구간입니다.") {
            Chart {
                if let j = a.jump {
                    RectangleMark(xStart: .value("시작", date(j.from.t)), xEnd: .value("끝", date(j.to.t)))
                        .foregroundStyle(.red.opacity(0.12))
                }
                ForEach(a.series.indices, id: \.self) { i in
                    LineMark(x: .value("시각", date(a.series[i].t)), y: .value("채팅방 인원", a.series[i].member))
                        .foregroundStyle(Color.brand)
                    PointMark(x: .value("시각", date(a.series[i].t)), y: .value("채팅방 인원", a.series[i].member))
                        .symbolSize(24)
                        .foregroundStyle(Color.brand)
                }
                RuleMark(y: .value("시청자수", s.viewers))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading) {
                        Text("점검 시점 시청자수 \(s.viewers)명").font(.caption2).foregroundStyle(.secondary)
                    }
            }
            .chartXScale(domain: xDomain)
            .chartXAxis { timeAxis }
            .frame(height: 220)
        }
    }

    private var whoChart: some View {
        let accounts = Set(s.chats.map(\.who)).count
        return Card(title: "누가 언제 채팅했는지 (계정은 익명 번호)",
                    note: "주황색은 스트리머 본인입니다. 닉네임과 채팅 내용은 저장하지 않습니다.") {
            Chart(s.chats.indices, id: \.self) { i in
                PointMark(x: .value("시각", date(s.chats[i].t)), y: .value("계정", s.chats[i].who))
                    .symbolSize(30)
                    .foregroundStyle(s.chats[i].who == "스트리머" ? Color.orange : Color.brand)
            }
            .chartXScale(domain: xDomain)
            .chartXAxis { timeAxis }
            .frame(height: CGFloat(max(90, accounts * 24 + 40)))
        }
    }

    // 지켜보기: 30초마다 잰 시청자수와 채팅방 인원
    private func watchCard(_ w: WatchState) -> some View {
        let range = w.range.count == 2 ? " · 최근 30분 시청자 \(w.range[0])~\(w.range[1])명" : ""
        return Card(title: w.active ? "지켜보는 중 (30초 간격, \(w.rows.count)회 기록)" : "지켜보기 기록 (\(w.rows.count)회, 멈춤)",
                    note: "실제 시청자는 들어오고 나가서 숫자가 조금씩 흔들립니다. 한 번에 계단처럼 오르거나 오래 전혀 움직이지 않으면 눈여겨볼 만합니다. 빨간 영역은 급증으로 판정한 구간입니다. 앱을 닫으면 멈추고, 기록은 저장 폴더의 '지켜보기'에 남습니다.") {
            HStack {
                Text("\(date(w.rows.first!.t).formatted(date: .omitted, time: .shortened))부터\(range)")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if w.active, let onStopWatch { Button("중지", action: onStopWatch).controlSize(.small) }
            }
            Chart {
                if let j = w.jump {
                    RectangleMark(xStart: .value("시작", date(j.from.t)), xEnd: .value("끝", date(j.to.t)))
                        .foregroundStyle(.red.opacity(0.12))
                }
                ForEach(w.rows.indices, id: \.self) { i in
                    LineMark(x: .value("시각", date(w.rows[i].t)), y: .value("인원", w.rows[i].viewers), series: .value("종류", "시청자수"))
                        .foregroundStyle(by: .value("종류", "시청자수"))
                    if w.rows.count <= 60 {   // 기록이 적을 때는 점도 찍어 한두 번 잰 값이 보이게
                        PointMark(x: .value("시각", date(w.rows[i].t)), y: .value("인원", w.rows[i].viewers))
                            .symbolSize(20)
                            .foregroundStyle(by: .value("종류", "시청자수"))
                    }
                    if let c = w.rows[i].chatUsers {
                        LineMark(x: .value("시각", date(w.rows[i].t)), y: .value("인원", c), series: .value("종류", "채팅방 인원"))
                            .foregroundStyle(by: .value("종류", "채팅방 인원"))
                    }
                }
            }
            .chartForegroundStyleScale(["시청자수": Color.blue, "채팅방 인원": Color.brand])
            .frame(height: 200)
        }
    }

    // 방송별 비교: 점검할 때마다, 지켜볼 때마다 쌓인 기록
    private func patternCard(_ p: Pattern) -> some View {
        let f0 = r.history.first?.followers, f1 = r.history.last?.followers
        let follow = (f0 != nil && f1 != nil) ? " 팔로워는 첫 기록 \(f0!.formatted())명에서 지금 \(f1!.formatted())명입니다." : ""
        return Card(title: "방송별 비교 (반복 패턴)",
                    note: "점검하거나 지켜본 순간의 값만 있습니다. 기록이 없는 시간대는 모릅니다. 여러 날에 걸쳐 같은 모양이 되풀이되면 한 번의 급증보다 훨씬 강한 근거가 됩니다." + follow) {
            BroadcastCompare(pattern: p)
            if !forReport {
                HStack {
                    if let onSavePattern { Button("반복 패턴 보고서 저장", action: onSavePattern) }
                    if let onOpenStats { Button("통계 사이트에서 지난 방송 보기", action: onOpenStats) }
                }
            }
        }
    }

    @ViewBuilder private var screenshot: some View {
        if let dir = r.dir, let img = NSImage(contentsOfFile: dir + "/화면.jpg") {
            Card(title: "점검 시점 방송 화면") {
                Image(nsImage: img).resizable().scaledToFit().frame(maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity)
            }
        } else if !forReport, let u = s.thumbUrl, let url = URL(string: u) {
            Card(title: "지금 방송 화면 (저장 안 됨)") {
                AsyncImage(url: url) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
                    .frame(maxHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

/// "보고서 저장"이 그림으로 굽는 화면. 인쇄·첨부에 맞게 밝은 바탕으로 고정한다.
struct ReportView: View {
    let r: CheckResult
    let baseline: Baseline
    var watch: WatchState?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("치지직 방송 점검 보고서").font(.caption).foregroundStyle(.secondary)
                Text(r.s.name).font(.largeTitle.bold())
                Text(r.liveURL.absoluteString).font(.callout).foregroundStyle(.secondary)
                Text("점검 시각 \(date(r.s.checkedAt).formatted(date: .numeric, time: .standard)) · 치지직 서버 응답 시각 \(r.s.serverDate ?? "?")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DetailContent(r: r, baseline: baseline, forReport: true, watch: watch)
        }
        .frame(width: 900)
        .padding(28)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .tint(.brand)
    }
}

/// 여러 방송 기록을 한 장으로 묶은 보고서
struct PatternReportView: View {
    let r: CheckResult
    let pattern: Pattern

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("치지직 방송 반복 패턴 보고서").font(.caption).foregroundStyle(.secondary)
                Text(r.s.name).font(.largeTitle.bold())
                Text(r.liveURL.absoluteString).font(.callout).foregroundStyle(.secondary)
                Text("작성 \(Date().formatted(date: .numeric, time: .standard)) · 기록 기간 \(pattern.broadcasts.first?.openDate ?? "?") ~ \(date(r.s.checkedAt).formatted(date: .numeric, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Card(title: "방송별 시청자수 비교",
                 note: "가로축은 방송 시작 후 지난 시간입니다. 점검하거나 지켜본 순간의 값만 있고, 기록이 없는 시간대는 모릅니다. 방송 시작 15분 이내는 판정에서 뺐습니다.") {
                BroadcastCompare(pattern: pattern)
            }
            Text("치지직 공개 정보를 직접 기록한 것입니다. 조작을 확정하지 않으며, 비정상 유입인지 확인을 요청하는 참고 자료입니다.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 900)
        .padding(28)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .tint(.brand)
    }
}

// MARK: - 설정

struct SettingsView: View {
    @Bindable var store: Store

    var body: some View {
        Form {
            Section("증거 저장 폴더") {
                Text(store.dataDir).font(.callout).textSelection(.enabled)
                HStack {
                    Button("변경…") { pick() }
                    Button("Finder에서 열기") { store.openDataDir() }
                    Spacer()
                    Button("기본값으로") { store.dataDir = Store.defaultDataDir }
                        .disabled(store.dataDir == Store.defaultDataDir)
                }
                Text("점검할 때마다 요약문, 원본 데이터, 방송 화면 사진이 이 폴더의 '증거' 아래에 저장되고, 점검기록.tsv 에 한 줄씩 쌓입니다. 채팅 닉네임과 내용은 저장하지 않습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("실행 환경") {
                LabeledContent("Node.js", value: Store.node ?? "찾지 못함 (brew install node)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: store.dataDir)
        panel.prompt = "이 폴더에 저장"
        if panel.runModal() == .OK, let url = panel.url { store.dataDir = url.path }
    }
}

// MARK: - 앱

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    // 앱이 끝날 때 지켜보기·점검 프로세스를 남기지 않는다
    func applicationWillTerminate(_ notification: Notification) { Store.current?.stopAll() }
}

@main
struct ChzzkCheckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = Store()

    var body: some Scene {
        Window("치지직 점검", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 900, minHeight: 600)
                .tint(.brand)
        }
        .defaultSize(width: 1150, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("치지직 점검에 관하여") { showAbout() }
            }
            CommandMenu("점검") {
                Button("주소 입력") { store.focusTick += 1 }.keyboardShortcut("l")
                Button("다시 점검") { store.recheckSelected() }.keyboardShortcut("r")
                    .disabled(store.selected == nil || store.busy)
                Button("방송 훑어보기") { store.scan() }.keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(store.busy)
                Button("중지") { store.cancel() }.keyboardShortcut(".")
                    .disabled(!store.busy)
                Divider()
                Button(store.selected.map { store.isFavorite($0.id) } == true ? "관심 채널에서 빼기" : "관심 채널에 넣기") {
                    store.selected.map(store.toggleFavorite)
                }
                .keyboardShortcut("d")
                .disabled(store.selected == nil)
                Button("관심 채널 모두 점검") { store.checkFavorites() }.keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(store.favorites.isEmpty || store.busy)
                Button(store.watching ? "지켜보기 중지" : "지켜보기 시작") { store.toggleWatch() }.keyboardShortcut("k")
                    .disabled(store.selected == nil && !store.watching)
                Divider()
                Button("요약 복사") { store.copySummary() }.keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(store.selected == nil)
                Button("보고서 그림 저장") { store.saveReport() }.keyboardShortcut("s")
                    .disabled(store.selected == nil)
                Button("반복 패턴 보고서 저장") { store.savePatternReport() }.keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(store.selected?.pattern == nil)
                Button("증거 폴더 열기") { store.openEvidence() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(store.selected?.dir == nil)
                Button("방송 열기") { store.openLive() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(store.selected == nil)
                Divider()
                Button("저장 폴더 열기") { store.openDataDir() }
                Button("통계 사이트 열기 (소프트콘 뷰어십)") { store.openStats() }
            }
            CommandGroup(replacing: .help) {
                Button("판정 기준 보기") { showCriteria() }
                Button("예시 데이터로 둘러보기") { store.showDemo() }.disabled(store.busy)
            }
        }

        Settings {
            SettingsView(store: store).tint(.brand)
        }
    }

    private func showCriteria() {
        let alert = NSAlert()
        alert.messageText = "의심 신호 판정 기준"
        alert.informativeText = """
        - 채팅방 접속 인원이 시청자수의 60% 미만 (시청자 20명 이상)
        - 채팅방 인원이 10명 이상, 1.3배 이상 증가 (방송 시작 15분 이내 제외)
        - 시청자 20명 이상인데 30분 넘게 채팅 없음
        - 같은 방송의 직전 점검보다 시청자가 10명 이상, 1.5배 이상 증가
        - (참고) 시청자수가 다시보기 조회수 중앙값의 2배 이상
        - (참고) 시청자수가 팔로워의 10%를 넘음
        - (참고) 시청자 50명 이상인데 최근 채팅 20개 이상이 계정 3개 이하에서만 나옴

        신호는 기준을 넘었다는 뜻일 뿐 조작을 확정하지 않습니다. 실제 접속 기록은 치지직만 확인할 수 있습니다.
        """
        alert.runModal()
    }

    private func showAbout() {
        let credits = NSAttributedString(
            string: "치지직 공개 정보로 방송의 시청자수, 채팅방 접속 인원, 채팅 흐름을 한 번에 점검하고 신고용 증거를 남깁니다.\n\n의심 신호는 판정 기준을 넘었다는 뜻일 뿐 조작을 확정하지 않습니다.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}
