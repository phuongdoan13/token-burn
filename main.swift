import AppKit
import SwiftUI

// MARK: - Pricing (USD per million tokens, Anthropic first-party list price, cached 2026-11)

struct Price { let input, output, cacheRead: Double }

let prices: [String: Price] = [
    "claude-fable-5-2":  Price(input: 8,  output: 40, cacheRead: 0.20),
    "claude-mythos-5-2": Price(input: 8,  output: 40, cacheRead: 0.20),
    "claude-fable-5-1":  Price(input: 10, output: 50, cacheRead: 0.25),
    "claude-mythos-5-1": Price(input: 10, output: 50, cacheRead: 0.25),
    "claude-fable-5":    Price(input: 10, output: 50, cacheRead: 1.00),
    "claude-opus-5-5":   Price(input: 4,  output: 20, cacheRead: 0.20),
    "claude-opus-5":     Price(input: 5,  output: 25, cacheRead: 0.50),
    "claude-opus-4-8":   Price(input: 5,  output: 25, cacheRead: 0.50),
    "claude-opus-4-7":   Price(input: 5,  output: 25, cacheRead: 0.50),
    "claude-opus-4-6":   Price(input: 5,  output: 25, cacheRead: 0.50),
    "claude-opus-4-5":   Price(input: 5,  output: 25, cacheRead: 0.50),
    "claude-sonnet-5-5": Price(input: 2,  output: 10, cacheRead: 0.10),
    "claude-sonnet-5":   Price(input: 2,  output: 10, cacheRead: 0.20),
    "claude-sonnet-4-6": Price(input: 3,  output: 15, cacheRead: 0.30),
    "claude-sonnet-4-5": Price(input: 3,  output: 15, cacheRead: 0.30),
    "claude-haiku-5-5":  Price(input: 0.10, output: 0.50, cacheRead: 0.01),
    "claude-haiku-4-5":  Price(input: 1,  output: 5,  cacheRead: 0.10),
]

/// "claude-haiku-4-5-20251001" or "claude-opus-5-5[1m]" -> base id
func baseModel(_ m: String) -> String {
    m.replacingOccurrences(of: #"(\[.*\]|-\d{8})$"#, with: "", options: .regularExpression)
}

struct Usage: Codable {
    var input = 0, output = 0, write5m = 0, write1h = 0, read = 0
    var total: Int { input + output + write5m + write1h + read }
    static func += (a: inout Usage, b: Usage) {
        a.input += b.input; a.output += b.output; a.write5m += b.write5m
        a.write1h += b.write1h; a.read += b.read
    }
    init() {}
    init(_ u: [String: Any]) {
        func n(_ d: [String: Any]?, _ k: String) -> Int { (d?[k] as? NSNumber)?.intValue ?? 0 }
        input = n(u, "input_tokens"); output = n(u, "output_tokens"); read = n(u, "cache_read_input_tokens")
        let split = u["cache_creation"] as? [String: Any]
        write1h = n(split, "ephemeral_1h_input_tokens")
        write5m = max(n(u, "cache_creation_input_tokens") - write1h, 0)
    }
}

/// nil when the model has no known price
func cost(_ model: String, _ u: Usage) -> Double? {
    let m = baseModel(model)
    guard var p = prices[m] else { return nil }
    // Haiku 5.5 has a second rate card for prompts over 100K tokens
    if m == "claude-haiku-5-5" && u.input + u.read + u.write5m + u.write1h > 100_000 {
        p = Price(input: 0.50, output: 2.50, cacheRead: 0.05)
    }
    return (Double(u.input) * p.input + Double(u.output) * p.output + Double(u.read) * p.cacheRead
        + Double(u.write5m) * p.input * 1.25 + Double(u.write1h) * p.input * 2) / 1_000_000
}

// MARK: - Log reader

struct Entry: Codable { let date: Date; let model: String; let usage: Usage; let cost: Double; let priced: Bool }

/// Tails Claude Code's JSONL transcripts, reading only bytes added since the last scan.
final class Store {
    private var offsets: [String: UInt64] = [:]
    private(set) var entries: [String: Entry] = [:]
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    // Claude Code deletes transcripts after 30 days, shorter than some billing months,
    // so every response seen is also kept here.
    private let ledger = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TokenBurn/ledger.json")
    private var changed = false

    init() {
        guard let data = try? Data(contentsOf: ledger) else { return }
        if let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        } else {  // keep an unreadable ledger instead of overwriting it
            try? FileManager.default.moveItem(at: ledger, to: ledger.appendingPathExtension("bad-\(Int(Date().timeIntervalSince1970))"))
        }
    }

    func save() {
        guard changed else { return }
        do {
            try FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: ledger, options: .atomic)
            changed = false
        } catch { NSLog("TokenBurn: cannot save ledger: \(error)") }
    }

    var roots: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var r = [home.appendingPathComponent(".claude/projects"), home.appendingPathComponent(".config/claude/projects")]
        if let c = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] {
            r.append(URL(fileURLWithPath: c).appendingPathComponent("projects"))
        }
        return Array(Set(r.map { $0.resolvingSymlinksInPath() }))
    }

    func scan() {
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            for case let url as URL in walker where url.pathExtension == "jsonl" {
                let size = UInt64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                var offset = offsets[url.path] ?? 0
                if size < offset { offset = 0 }  // file was rewritten
                if size == offset { continue }
                autoreleasepool { read(url, from: offset) }
            }
        }
    }

    private func read(_ url: URL, from offset: UInt64) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        try? h.seek(toOffset: offset)
        guard let data = try? h.readToEnd(), let end = data.lastIndex(of: 10) else { return }
        let complete = data[data.startIndex...end]  // leave a half-written line for next time
        offsets[url.path] = offset + UInt64(complete.count)
        let marker = Data("\"usage\"".utf8)
        for line in complete.split(separator: 10) where line.range(of: marker) != nil {
            parse(Data(line))
        }
    }

    private func parse(_ line: Data) {
        guard let d = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let msg = d["message"] as? [String: Any],
              let raw = msg["usage"] as? [String: Any],
              let model = msg["model"] as? String, model != "<synthetic>",
              let ts = d["timestamp"] as? String, let date = iso.date(from: ts) else { return }
        let id = "\(msg["id"] as? String ?? d["uuid"] as? String ?? ts)|\(d["requestId"] as? String ?? "")"

        var extra = 1.0
        if raw["speed"] as? String == "fast" { extra *= 2 }
        if raw["inference_geo"] as? String == "us" { extra *= 1.1 }
        let searches = ((raw["server_tool_use"] as? [String: Any])?["web_search_requests"] as? NSNumber)?.doubleValue ?? 0
        add(id, date, model, Usage(raw), extra, searches * 0.01)

        // Advisor calls are billed separately and are not part of the top-level counts
        for (i, it) in (raw["iterations"] as? [[String: Any]] ?? []).enumerated()
        where it["type"] as? String == "advisor_message" {
            if let m = it["model"] as? String { add("\(id)|advisor\(i)", date, m, Usage(it), 1, 0) }
        }
    }

    /// One API response is logged on several lines; keep it once, with its most complete counts.
    private func add(_ id: String, _ date: Date, _ model: String, _ u: Usage, _ extra: Double, _ flat: Double) {
        if let old = entries[id], old.usage.total > u.total || (old.usage.total == u.total && old.priced) { return }
        changed = true
        let c = cost(model, u)
        entries[id] = Entry(date: date, model: baseModel(model), usage: u,
                            cost: (c ?? 0) * extra + flat, priced: c != nil)
    }
}

// MARK: - Billing month

/// Renewal day and monthly fee: what the user picked in the menu, else guessed from Claude Code's account info.
enum Plan {
    private static let account: [String: Any] = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        let json = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return json?["oauthAccount"] as? [String: Any] ?? [:]
    }()

    static var day: Int {
        let picked = UserDefaults.standard.integer(forKey: "billingDay")
        if picked > 0 { return picked }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let s = account["subscriptionCreatedAt"] as? String, let d = f.date(from: s) else { return 1 }
        return Calendar.current.component(.day, from: d)
    }

    /// Monthly subscription fee in USD, 0 for pay-per-token
    static var fee: Int {
        if let picked = UserDefaults.standard.object(forKey: "fee") as? Int { return picked }
        switch account["organizationRateLimitTier"] as? String {
        case "default_claude_max_20x": return 200
        case "default_claude_max_5x": return 100
        default: return account["organizationType"] as? String == "claude_pro" ? 20 : 0
        }
    }

    /// Start of the current billing month and of the next one. Day 31 means the last day in shorter months.
    static func cycle(day: Int, now: Date, calendar cal: Calendar = .current) -> (start: Date, end: Date) {
        func renewal(_ offset: Int) -> Date {
            let first = cal.date(from: cal.dateComponents([.year, .month], from: now))!
            let month = cal.date(byAdding: .month, value: offset, to: first)!
            let length = cal.range(of: .day, in: .month, for: month)!.count
            return cal.date(byAdding: .day, value: min(day, length) - 1, to: month)!
        }
        return renewal(0) <= now ? (renewal(0), renewal(1)) : (renewal(-1), renewal(0))
    }
}

// MARK: - Aggregation

struct Sum {
    var usage = Usage(); var cost = 0.0
    mutating func add(_ e: Entry) { usage += e.usage; cost += e.cost }
}

struct Stats {
    var today = Sum(), hour = Sum(), week = Sum(), cycle = Sum(), all = Sum()
    var models: [(String, Sum)] = []
    var daily: [Double] = []  // cost per day of the billing month
    var start = Date(), end = Date()
    var elapsedDays = 1
    var fee = 0
    /// Straight-line estimate for the whole billing month
    var projected: Double { cycle.cost / Double(elapsedDays) * Double(daily.count) }
    var unpriced: Set<String> = []
    var updated = Date()

    init() {}
    init(_ entries: [String: Entry]) {
        let cal = Calendar.current, now = Date(), midnight = cal.startOfDay(for: now)
        let week = cal.date(byAdding: .day, value: -6, to: midnight)!
        (start, end) = Plan.cycle(day: Plan.day, now: now)
        fee = Plan.fee
        func days(_ d: Date) -> Int { cal.dateComponents([.day], from: start, to: cal.startOfDay(for: d)).day! }
        daily = [Double](repeating: 0, count: days(end))
        elapsedDays = days(now) + 1
        var byModel: [String: Sum] = [:]
        for e in entries.values {
            all.add(e)
            if !e.priced { unpriced.insert(e.model) }
            if e.date >= start && e.date < end {
                cycle.add(e)
                byModel[e.model, default: Sum()].add(e)
                daily[days(e.date)] += e.cost
            }
            if e.date >= week { self.week.add(e) }
            if e.date >= now.addingTimeInterval(-3600) { hour.add(e) }
            if e.date >= midnight { today.add(e) }
        }
        models = byModel.sorted { $0.value.cost > $1.value.cost }.map { ($0.key, $0.value) }
    }
}

func money(_ v: Double) -> String { String(format: v >= 1000 ? "$%.0f" : "$%.2f", v) }
func count(_ n: Int) -> String {
    switch n {
    case 1_000_000_000...: return String(format: "%.2fB", Double(n) / 1e9)
    case 1_000_000...: return String(format: "%.2fM", Double(n) / 1e6)
    case 1_000...: return String(format: "%.1fK", Double(n) / 1e3)
    default: return "\(n)"
    }
}

// MARK: - Widget view

final class Model: ObservableObject { @Published var stats = Stats(); @Published var loading = true }

struct Row: View {
    let label: String; let tokens: Int; var cost: Double? = nil
    var body: some View {
        HStack {
            Text(label).foregroundColor(.secondary)
            Spacer()
            Text(count(tokens)).frame(width: 66, alignment: .trailing)
            Text(cost.map(money) ?? "").frame(width: 66, alignment: .trailing)
        }
        .font(.system(size: 11).monospacedDigit())
    }
}

struct WidgetView: View {
    @ObservedObject var model: Model
    var body: some View {
        let s = model.stats
        let peak = max(s.daily.max() ?? 0, 0.000001)
        let day = Date.FormatStyle().day().month(.abbreviated)
        let last = Calendar.current.date(byAdding: .day, value: -1, to: s.end)!
        VStack(alignment: .leading, spacing: 6) {
            Text("🔥 Billing month · \(s.start.formatted(day)) – \(last.formatted(day))").font(.system(size: 12, weight: .semibold))
            if model.loading {
                Text("Reading logs…").foregroundColor(.secondary)
            } else {
                Text(money(s.cycle.cost)).font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                Group {
                    Text("\(count(s.cycle.usage.total)) tokens · day \(s.elapsedDays) of \(s.daily.count)")
                    Text("On pace for \(money(s.projected)) by renewal")
                    if s.fee > 0 {
                        Text("You pay $\(s.fee)/mo · usage is \(String(format: "%.1f", s.cycle.cost / Double(s.fee)))× that")
                    }
                }
                .font(.system(size: 11)).foregroundColor(.secondary)
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(s.daily.indices, id: \.self) { d in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(s.daily[d] > 0 ? Color.orange : Color.secondary.opacity(0.25))
                            .frame(height: max(2, 30 * s.daily[d] / peak))
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 30, alignment: .bottom)
                HStack { Text(s.start.formatted(day)); Spacer(); Text(last.formatted(day)) }
                    .font(.system(size: 8)).foregroundColor(.secondary)
                Divider()
                Row(label: "Input", tokens: s.cycle.usage.input)
                Row(label: "Output", tokens: s.cycle.usage.output)
                Row(label: "Cache write", tokens: s.cycle.usage.write5m + s.cycle.usage.write1h)
                Row(label: "Cache read", tokens: s.cycle.usage.read)
                if !s.models.isEmpty {
                    Divider()
                    ForEach(s.models, id: \.0) { m in
                        Row(label: m.0.replacingOccurrences(of: "claude-", with: ""), tokens: m.1.usage.total, cost: m.1.cost)
                    }
                }
                Divider()
                Row(label: "Today", tokens: s.today.usage.total, cost: s.today.cost)
                Row(label: "Last hour", tokens: s.hour.usage.total, cost: s.hour.cost)
                Row(label: "Last 7 days", tokens: s.week.usage.total, cost: s.week.cost)
                Row(label: "All recorded", tokens: s.all.usage.total, cost: s.all.cost)
                if !s.unpriced.isEmpty {
                    Text("No price for \(s.unpriced.sorted().joined(separator: ", ")): cost understated")
                        .font(.system(size: 9)).foregroundColor(.red)
                }
                Text("Claude Code only · estimate at API list price · \(s.updated.formatted(date: .omitted, time: .standard))")
                    .font(.system(size: 8)).foregroundColor(.secondary)
            }
        }
        .padding(14)
        .frame(width: 270)
        .background(RoundedRectangle(cornerRadius: 18).fill(Color(NSColor.windowBackgroundColor).opacity(0.94)))
        .fixedSize()
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    let model = Model()
    let store = Store()
    let queue = DispatchQueue(label: "scan", qos: .utility)
    var item: NSStatusItem!
    var panel: NSPanel!
    var host: NSHostingView<WidgetView>!
    var onTopItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🔥 …"
        let menu = NSMenu()
        menu.addItem(withTitle: "Show / Hide Widget", action: #selector(toggle), keyEquivalent: "w").target = self
        onTopItem = menu.addItem(withTitle: "Keep on Top", action: #selector(toggleOnTop), keyEquivalent: "t")
        onTopItem.target = self
        menu.addItem(.separator())
        addPicker(menu, "Billing Day", key: "billingDay", current: Plan.day,
                  choices: (1...31).map { ("\($0)", $0) })
        addPicker(menu, "Plan Fee", key: "fee", current: Plan.fee,
                  choices: [("Pay per token", 0), ("$20 / month", 20), ("$100 / month", 100), ("$200 / month", 200)])
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Token Burn", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 270, height: 100),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        host = NSHostingView(rootView: WidgetView(model: model))
        panel.contentView = host
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        applyLevel()
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let saved = UserDefaults.standard.string(forKey: "topLeft").map(NSPointFromString)
        let visible = saved.map { p in NSScreen.screens.contains { $0.frame.contains(NSPoint(x: p.x + 20, y: p.y - 20)) } } ?? false
        resize(topLeft: visible ? saved! : NSPoint(x: screen.maxX - 290, y: screen.maxY - 20))
        panel.orderFrontRegardless()
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
            guard let f = self?.panel.frame else { return }
            UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.minX, y: f.maxY)), forKey: "topLeft")
        }

        refresh()
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func addPicker(_ menu: NSMenu, _ title: String, key: String, current: Int, choices: [(String, Int)]) {
        let parent = menu.addItem(withTitle: title, action: nil, keyEquivalent: "")
        let sub = NSMenu(title: key)
        for (label, value) in choices {
            let i = sub.addItem(withTitle: label, action: #selector(pick(_:)), keyEquivalent: "")
            i.target = self; i.tag = value; i.state = value == current ? .on : .off
        }
        parent.submenu = sub
    }
    @objc func pick(_ sender: NSMenuItem) {
        guard let sub = sender.menu else { return }
        UserDefaults.standard.set(sender.tag, forKey: sub.title)
        sub.items.forEach { $0.state = $0 === sender ? .on : .off }
        refresh()
    }

    func applicationWillTerminate(_ n: Notification) { queue.sync { store.save() } }

    private var busy = false
    func refresh() {
        if busy { return }
        busy = true
        queue.async {
            self.store.scan()
            self.store.save()
            let stats = Stats(self.store.entries)
            DispatchQueue.main.async {
                self.model.stats = stats
                self.model.loading = false
                self.item.button?.title = "🔥 \(money(stats.cycle.cost)) this month"
                self.busy = false
                DispatchQueue.main.async { self.resize(topLeft: NSPoint(x: self.panel.frame.minX, y: self.panel.frame.maxY)) }
            }
        }
    }

    func resize(topLeft: NSPoint) {
        let size = host.fittingSize
        let frame = NSRect(x: topLeft.x, y: topLeft.y - size.height, width: size.width, height: size.height)
        if frame != panel.frame { panel.setFrame(frame, display: true) }
    }

    /// Off: sits on the desktop behind other windows, like a widget. On: floats above them.
    func applyLevel() {
        let top = UserDefaults.standard.bool(forKey: "onTop")
        panel.level = top ? .floating : NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        onTopItem.state = top ? .on : .off
    }
    @objc func toggleOnTop() {
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "onTop"), forKey: "onTop")
        applyLevel()
        panel.orderFrontRegardless()
    }
    @objc func toggle() { panel.isVisible ? panel.orderOut(nil) : panel.orderFrontRegardless() }
}

// MARK: - Entry point

let args = CommandLine.arguments
if args.contains("--once") || args.contains("--snapshot") {
    let store = Store(); store.scan()
    let s = Stats(store.entries)
    if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
        _ = NSApplication.shared
        let model = Model(); model.stats = s; model.loading = false
        let view = NSHostingView(rootView: WidgetView(model: model))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        view.layoutSubtreeIfNeeded()
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[i + 1]))
    } else {
        for (name, x) in [("today", s.today), ("7d", s.week), ("cycle", s.cycle), ("all", s.all)] {
            let u = x.usage
            print("\(name) in=\(u.input) out=\(u.output) w5m=\(u.write5m) w1h=\(u.write1h) read=\(u.read) cost=\(String(format: "%.4f", x.cost))")
        }
        print("billing day=\(Plan.day) fee=\(Plan.fee) from=\(s.start.formatted(date: .abbreviated, time: .omitted)) next=\(s.end.formatted(date: .abbreviated, time: .omitted))")
        // renewal-date edge cases
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let iso = ISO8601DateFormatter()
        for (day, now) in [(21, "2026-11-28T00:00:00Z"), (21, "2026-12-20T23:00:00Z"), (21, "2027-01-05T00:00:00Z"),
                           (31, "2027-02-15T00:00:00Z"), (31, "2027-02-28T00:00:00Z"), (1, "2026-12-01T00:00:00Z")] where args.contains("--check") {
            let c = Plan.cycle(day: day, now: iso.date(from: now)!, calendar: utc)
            print("check day=\(day) now=\(now.prefix(10)) -> \(iso.string(from: c.start).prefix(10)) .. \(iso.string(from: c.end).prefix(10))")
        }
        print("responses=\(store.entries.count) unpriced=\(s.unpriced.sorted())")
    }
} else {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
