import Foundation
import Combine

/// Persistent, owner-owned spam configuration: editable rules, enabled
/// preset groups, imported number lists, known-sender overrides and locally
/// dismissed junk threads. Everything stays on device; rules/lists are never
/// uploaded. Stored as a protected JSON file (numbers and rule text only —
/// never message bodies or credentials).
@MainActor
final class SpamFilterStore: ObservableObject {
    @Published private(set) var rules: [SpamRule] = []
    @Published private(set) var enabledPresets: Set<SpamPreset> = []
    @Published private(set) var lists: [NumberList] = []
    /// Canonical sender keys the owner marked known (restored / trusted).
    @Published private(set) var knownSenders: Set<String> = []
    /// Thread keys dismissed from the junk view locally (server keeps them).
    @Published private(set) var hiddenThreadKeys: Set<String> = []

    private var url: URL
    private var didLoad = false
    private var saveTask: Task<Void, Never>?
    /// Owner-local rules captured before the first cloud apply, restored on
    /// account change/logout so a previous iCloud account's downloaded rules
    /// can never stay in force for another account.
    private var preCloudSnapshot: SavedFilter?

    init(storeURL: URL? = nil) {
        self.url = storeURL ?? SpamFilterStore.defaultURL()
        load()
    }

    /// UI-test only: discard any real owner rules and operate on a fresh
    /// temporary file so automated runs are hermetic.
    func useEphemeralStore() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("spam-filter-\(UUID().uuidString).json")
        didLoad = false
        rules = []
        enabledPresets = []
        knownSenders = []
        hiddenThreadKeys = []
        lists = []
        load()
    }

    static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("CallRelay/spam-filter.json", isDirectory: false)
    }

    // MARK: Snapshot policy

    func policy() -> SpamPolicy {
        SpamPolicy(rules: rules, enabledPresets: enabledPresets)
    }

    // MARK: Rules

    func addRule(kind: SpamRule.Kind, value: String, label: String = "我的规则") {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !rules.contains(where: { $0.kind == kind && $0.value == trimmed }) else { return }
        rules.append(SpamRule(kind: kind, value: trimmed, label: label))
        scheduleSave()
    }

    func update(rule: SpamRule) {
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        rules[index] = rule
        scheduleSave()
    }

    func removeRule(at offsets: IndexSet) {
        rules.remove(atOffsets: offsets)
        scheduleSave()
    }

    func removeRule(_ rule: SpamRule) {
        rules.removeAll { $0.id == rule.id }
        scheduleSave()
    }

    func togglePreset(_ preset: SpamPreset) {
        if enabledPresets.contains(preset) { enabledPresets.remove(preset) }
        else { enabledPresets.insert(preset) }
        scheduleSave()
    }

    func enable(preset: SpamPreset) {
        enabledPresets.insert(preset); scheduleSave()
    }

    func disable(preset: SpamPreset) {
        enabledPresets.remove(preset); scheduleSave()
    }

    // MARK: Lists

    /// Cloud sync hooks (wired by AppModel). Fired only for local edits.
    var onListModeChange: ((NumberList) -> Void)?
    var onListRemoved: ((UUID) -> Void)?
    var onListAdded: ((NumberList) -> Void)?

    func list(mode: NumberListMode, for listID: UUID) {
        guard let index = lists.firstIndex(where: { $0.id == listID }) else { return }
        lists[index].mode = mode
        scheduleSave()
        guard !applyingCloud else { return }
        onListModeChange?(lists[index])
    }

    func removeList(_ listID: UUID) {
        lists.removeAll { $0.id == listID }
        scheduleSave()
        guard !applyingCloud else { return }
        onListRemoved?(listID)
    }

    func cloudSetting(for list: NumberList) -> SyncedListSetting {
        SyncedListSetting(
            listID: list.id.uuidString, name: list.name, mode: list.mode.rawValue,
            provenance: list.provenance, sourceURL: list.sourceURL?.absoluteString,
            isBundled: list.isBundled, updatedAt: list.lastUpdatedAt ?? list.importedAt)
    }

    /// Import pasted/TXT/JSON bytes as a new local list. Returns a user-facing
    /// error when nothing usable was parsed (the store is unchanged).
    @discardableResult
    func importList(
        name: String, data: Data, provenance: String, sourceURL: URL? = nil
    ) -> Result<Int, NumberListParser.Failure> {
        switch NumberListParser.parse(data) {
        case .success(let parsed):
            let list = NumberList(
                id: UUID(), name: name, sourceURL: sourceURL, provenance: provenance,
                importedAt: Date(), lastUpdatedAt: Date(), mode: .label,
                isBundled: false, numbers: parsed.numbers, lastRefreshNote: nil
            )
            lists.append(list)
            scheduleSave()
            guard !applyingCloud else { return .success(parsed.numbers.count) }
            onListAdded?(list)
            return .success(parsed.numbers.count)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Paste raw text (one number per line) directly.
    @discardableResult
    func importPasted(name: String, text: String) -> Result<Int, NumberListParser.Failure> {
        let numbers = NumberListParser.parseText(text)
        guard !numbers.isEmpty else { return .failure(.noNumbers) }
        let data = Data(text.utf8)
        guard data.count <= NumberList.maxBytes else { return .failure(.tooLarge(maxBytes: NumberList.maxBytes)) }
        let list = NumberList(
            id: UUID(), name: name, sourceURL: nil,
            provenance: "手动粘贴 · \(Date().formatted(date: .abbreviated, time: .omitted))",
            importedAt: Date(), lastUpdatedAt: Date(), mode: .label,
            isBundled: false, numbers: numbers, lastRefreshNote: nil
        )
        lists.append(list)
        scheduleSave()
        guard !applyingCloud else { return .success(numbers.count) }
        onListAdded?(list)
        return .success(numbers.count)
    }

    /// Re-download an updatable list. A failure keeps the previous numbers and
    /// records the note; only a successful parse replaces the set atomically.
    func refreshList(_ listID: UUID) async -> Bool {
        guard let index = lists.firstIndex(where: { $0.id == listID }),
              let url = lists[index].sourceURL else { return false }
        switch await NumberListRemote.refresh(url) {
        case .success(let parsed):
            lists[index].numbers = parsed.numbers
            lists[index].lastUpdatedAt = Date()
            lists[index].lastRefreshNote = "更新成功 · \(parsed.format) · \(parsed.numbers.count) 个号码"
            scheduleSave()
            return true
        case .failure(let error):
            lists[index].lastRefreshNote = "更新失败，仍保留上次列表：\(error.displayText)"
            scheduleSave()
            return false
        }
    }

    /// Add an owner-subscribed HTTPS list by URL (fetched once immediately).
    func addRemoteList(name: String, url: URL) async -> Result<Int, NumberListRemote.RefreshError> {
        switch await NumberListRemote.refresh(url) {
        case .success(let parsed):
            let list = NumberList(
                id: UUID(), name: name, sourceURL: url,
                provenance: url.absoluteString, importedAt: Date(), lastUpdatedAt: Date(),
                mode: .label, isBundled: false, numbers: parsed.numbers,
                lastRefreshNote: "导入成功 · \(parsed.format)"
            )
            lists.append(list)
            scheduleSave()
            guard !applyingCloud else { return .success(parsed.numbers.count) }
            onListAdded?(list)
            return .success(parsed.numbers.count)
        case .failure(let error):
            return .failure(error)
        }
    }

    // MARK: CloudKit rules restore (LWW document from another device)

    /// True after at least one cloud rules document was applied, so a reset
    /// knows local owner rules have to be restored.
    private(set) var cloudRulesApplied = false

    /// Replace owner-editable policy (rules, enabled presets, known senders)
    /// with a downloaded rules document when it is newer than the last one
    /// applied. Number LISTS are local data and are never replaced remotely.
    func applyCloudRules(_ synced: SyncedRules) {
        if preCloudSnapshot == nil {
            preCloudSnapshot = SavedFilter(
                rules: rules, enabledPresets: enabledPresets, lists: lists,
                knownSenders: knownSenders, hiddenThreadKeys: hiddenThreadKeys)
        }
        performCloudApply {
            rules = synced.rules
            enabledPresets = Set(synced.enabledPresets.compactMap(SpamPreset.init(rawValue:)))
            knownSenders = Set(synced.knownSenders)
            cloudRulesApplied = true
            scheduleSave()
        }
    }

    /// True while a cloud document is being applied, so the resulting
    /// objectWillChange does not bounce the download back as a local edit.
    private(set) var applyingCloud = false

    func performCloudApply(_ body: () -> Void) {
        applyingCloud = true
        body()
        applyingCloud = false
    }

    /// Apply a downloaded list SETTING (mode) to the local list with the same
    /// id. Only ids that exist locally are affected; list numbers are local.
    func applyCloudListSetting(_ setting: SyncedListSetting) {
        guard let uuid = UUID(uuidString: setting.listID),
              let index = lists.firstIndex(where: { $0.id == uuid }),
              let mode = NumberListMode(rawValue: setting.mode),
              lists[index].mode != mode else { return }
        performCloudApply {
            lists[index].mode = mode
            scheduleSave()
        }
    }

    /// A remote list-setting delete only turns the local list's MODE off; the
    /// locally cached numbers belong to this device and are never deleted.
    func resetCloudListMode(_ listID: UUID) {
        guard let index = lists.firstIndex(where: { $0.id == listID }) else { return }
        performCloudApply {
            lists[index].mode = .off
            scheduleSave()
        }
    }

    /// Account change/logout: drop the previous account's downloaded rules and
    /// restore the owner's local rules captured before the first cloud apply.
    func purgeCloudRestoredRules() {
        guard cloudRulesApplied else { return }
        if let saved = preCloudSnapshot {
            rules = saved.rules
            enabledPresets = saved.enabledPresets
            knownSenders = saved.knownSenders
            scheduleSave()
        }
        cloudRulesApplied = false
        preCloudSnapshot = nil
    }

    // MARK: Sender overrides

    /// Trust a sender permanently (restore / "标记为已知发件人").
    func markSenderKnown(_ rawPeer: String) {
        for key in PhoneNormalizer.canonicalKeys(rawPeer) { knownSenders.insert(key) }
        hiddenThreadKeys.remove(rawPeer)
        scheduleSave()
    }

    func isKnownSender(_ rawPeer: String) -> Bool {
        let keys = PhoneNormalizer.canonicalKeys(rawPeer)
        return keys.contains { knownSenders.contains($0) }
    }

    func hideThread(_ key: String) {
        hiddenThreadKeys.insert(key)
        scheduleSave()
    }

    func isThreadHidden(_ key: String) -> Bool { hiddenThreadKeys.contains(key) }

    // MARK: Call list lookups

    func callListHits(for rawPeer: String) -> [(mode: NumberListMode, listName: String)] {
        let keys = Set(PhoneNormalizer.canonicalKeys(rawPeer))
        return lists
            .filter { $0.mode != .off && $0.contains(canonicalKeys: keys) }
            .map { ($0.mode, $0.name) }
    }

    // MARK: Persistence

    private func load() {
        guard didLoad == false else { return }
        didLoad = true
        seedBundledListIfNeeded()
        guard let data = try? Data(contentsOf: url),
              let saved = try? JSONDecoder.iso.decode(SavedFilter.self, from: data) else {
            scheduleSave()
            return
        }
        rules = saved.rules
        enabledPresets = saved.enabledPresets
        knownSenders = saved.knownSenders
        hiddenThreadKeys = saved.hiddenThreadKeys
        // Bundled list is always owned by the app (provenance/count fixed);
        // preserve the owner's chosen mode, keep custom lists verbatim.
        let custom = saved.lists.filter { $0.isBundled == false }
        let bundledMode = saved.lists.first { $0.isBundled }?.mode ?? .off
        lists = bundledLists(mode: bundledMode) + custom
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = SavedFilter(
            rules: rules, enabledPresets: enabledPresets, lists: lists,
            knownSenders: knownSenders, hiddenThreadKeys: hiddenThreadKeys
        )
        let target = url
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            self?.persist(snapshot, to: target)
        }
    }

    /// Write through immediately (used before reading back in the same run).
    func flush() {
        saveTask?.cancel()
        persist(SavedFilter(
            rules: rules, enabledPresets: enabledPresets, lists: lists,
            knownSenders: knownSenders, hiddenThreadKeys: hiddenThreadKeys
        ), to: url)
    }

    private nonisolated func persist(_ snapshot: SavedFilter, to url: URL) {
        guard let data = try? JSONEncoder.iso.encode(snapshot) else { return }
        do {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            AppLog.network.error("spam filter save failed")
        }
    }

    // MARK: Bundled historical Chinese community list

    static let bundledListID = UUID(uuidString: "A1B2C3D4-0001-4000-8000-000000000001")!

    /// Locate the bundled list whether code runs in the app or a hosted test
    /// runner (resource lookup across the host and all loaded bundles).
    static func bundledResourceURL() -> URL? {
        // Bundle(for:) finds the bundle containing this class (the app bundle
        // even when code runs hosted in the unit-test runner); fall back to
        // main and all loaded bundles.
        let candidates = [Bundle(for: SpamFilterStore.self), Bundle.main] + Bundle.allBundles
        for bundle in candidates {
            if let url = bundle.url(forResource: "cn-historical-2020", withExtension: "txt") {
                return url
            }
        }
        return nil
    }

    private func seedBundledListIfNeeded() {
        // No persisted file yet: make the historical list available, disabled.
        guard FileManager.default.fileExists(atPath: url.path) == false else { return }
        lists = bundledLists(mode: .off)
    }

    private func bundledLists(mode: NumberListMode) -> [NumberList] {
        guard let url = Self.bundledResourceURL(),
              let data = try? Data(contentsOf: url) else { return [] }
        let numbers = NumberListParser.parseText(
            String(decoding: data, as: UTF8.self)
        )
        guard !numbers.isEmpty else { return [] }
        let provenance = """
        社区历史名单：blessing-gao/rubbish-phone「房地产垃圾电话.md」，\
        提交 926dc0f（2020-06-21），Apache-2.0 许可。\
        仅 34 个号码，长期未更新，默认只标记、不拦截，也不代表当前仍为骚扰号码。
        """
        return [
            NumberList(
                id: SpamFilterStore.bundledListID,
                name: "中文历史骚扰电话（34 个 · 2020）",
                sourceURL: nil, provenance: provenance,
                importedAt: Date(timeIntervalSince1970: 1_592_700_000),
                lastUpdatedAt: Date(timeIntervalSince1970: 1_592_700_000),
                mode: mode, isBundled: true, numbers: numbers,
                lastRefreshNote: "随 App 内置的历史归档，无法在线更新"
            )
        ]
    }
}

private struct SavedFilter: Codable {
    var rules: [SpamRule]
    var enabledPresets: Set<SpamPreset>
    var lists: [NumberList]
    var knownSenders: Set<String>
    var hiddenThreadKeys: Set<String>
}

extension NumberListRemote.RefreshError {
    var displayText: String {
        switch self {
        case .notHTTPS: return "仅支持 HTTPS 链接"
        case .transport(let m): return m
        case .tooLarge: return "列表超过大小上限"
        case .parse(let f): return f.displayText
        }
    }
}

extension NumberListParser.Failure {
    var displayText: String {
        switch self {
        case .tooLarge(let max): return "文件超过 \(max / 1024 / 1024)MB 上限"
        case .invalidEncoding: return "无法按文本读取"
        case .invalidJSON: return "JSON 格式无法识别"
        case .tooManyNumbers(let max): return "号码超过 \(max) 个上限"
        case .noNumbers: return "没有找到可用号码"
        }
    }
}
