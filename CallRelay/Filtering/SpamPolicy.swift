import Foundation

/// Result of classifying one inbound SMS.
enum SpamVerdict: Equatable {
    /// Explicitly trusted (whitelist / known sender) — always shown.
    case allow(reason: String)
    /// Not junk: unknown senders stay in the normal list, never hidden.
    case unknown
    /// Matched an enabled junk rule; moved to the junk folder (recoverable).
    case junk(reason: String)

    var isJunk: Bool { if case .junk = self { return true }; return false }
    var isAllowed: Bool { if case .allow = self { return true }; return false }
}

/// Call screening decision (separate from SMS because it drives CallKit).
enum CallScreening: Equatable {
    /// Ring normally.
    case allow
    /// Show a "疑似骚扰" label but still ring (historical/opt-in lists).
    case label(reason: String)
    /// The owner chose to silence this caller; the call is reported to CallKit
    /// and ended immediately per PushKit rules (never silently dropped).
    case reject(reason: String)
}

/// A single user-editable rule. Persisted locally; never leaves the device.
struct SpamRule: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case senderExact      // full number/short code, canonical match
        case numberPrefix     // digit prefix on the canonical number
        case keyword          // case-insensitive substring in body
        case regex            // ICU regex on body
        case whitelistSender  // trusted number/short code (overrides junk)
        case whitelistKeyword // trusted body marker (OTP/transaction owners)

        var displayName: String {
            switch self {
            case .senderExact: return "拦截号码（完全匹配）"
            case .numberPrefix: return "拦截号码前缀"
            case .keyword: return "短信关键词"
            case .regex: return "短信正则表达式"
            case .whitelistSender: return "信任号码"
            case .whitelistKeyword: return "信任短信关键词"
            }
        }
    }

    var id: UUID
    var kind: Kind
    /// Number/short code for sender rules; substring or regex pattern for body.
    var value: String
    var enabled: Bool
    /// Free-form owner label shown as the match reason.
    var label: String
    let createdAt: Date

    init(id: UUID = UUID(), kind: Kind, value: String, enabled: Bool = true,
         label: String = "我的规则", createdAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.value = value
        self.label = label
        self.enabled = enabled
        self.createdAt = createdAt
    }
}

/// Built-in conservative preset groups. All patterns were authored for this
/// project; they match common Chinese/English promotion and scam language
/// without importing any third-party rule engine. Every group is opt-in.
enum SpamPreset: String, CaseIterable, Codable {
    case loanAndInvestment   // 贷款/代开发票/理财诱导
    case gamblingAndTask     // 赌博/刷单/网络兼职诈骗
    case marketingOptOut     // 营销退订/店铺促销
    case englishPromo        // English promotional patterns

    var displayName: String {
        switch self {
        case .loanAndInvestment: return "贷款、理财与发票骚扰"
        case .gamblingAndTask: return "赌博、刷单与兼职诈骗"
        case .marketingOptOut: return "营销促销与退订短信"
        case .englishPromo: return "English promotional SMS"
        }
    }

    var detail: String {
        switch self {
        case .loanAndInvestment:
            return "匹配“无抵押/低息贷款、代开发票、内部荐股、稳赚”等常见诱导话术。"
        case .gamblingAndTask:
            return "匹配“刷单返佣、网赌、彩票导师、兼职点赞”等高风险诈骗话术。"
        case .marketingOptOut:
            return "匹配带“回T退订/退订回T”的商业营销与店铺促销短信。"
        case .englishPromo:
            return "Matches common English loan, casino and marketing phrases."
        }
    }

    /// Case-insensitive substrings; a message hitting one is junk.
    var keywords: [String] {
        switch self {
        case .loanAndInvestment:
            return [
                "无抵押贷款", "免担保贷款", "低息贷款", "贷款额度", "极速放款",
                "代开发票", "正规发票", "开票联系", "发票加",
                "内幕股票", "牛股推荐", "稳赚不赔", "高收益理财", "荐股",
                "网贷", "套现", "提额养卡", "信用卡代还"
            ]
        case .gamblingAndTask:
            return [
                "刷单", "刷信誉", "刷销量", "返佣", "兼职点赞", "点赞关注即可赚钱",
                "网络赌博", "在线博彩", "澳门赌城", "彩票计划", "彩票导师",
                "分分彩", "幸运飞艇", "包赔", "带你回血", "稳赢计划",
                "约炮", "裸聊", "刷单兼职"
            ]
        case .marketingOptOut:
            return [
                "回t退订", "退订回t", "回复t退订", "退订请回", "拒收请回复",
                "门店大促", "限时秒杀", "优惠券已到账", "全场包邮", "清仓特价"
            ]
        case .englishPromo:
            return [
                "pre-approved loan", "low-interest loan", "need cash now",
                "you are preapproved", "claim your bonus", "online casino",
                "free spins", "win big now", "text stop to opt out",
                "reply stop to unsubscribe", "limited-time offer"
            ]
        }
    }

    /// Regex patterns (ICU syntax) for phrases that need word boundaries.
    var regexes: [String] {
        switch self {
        case .loanAndInvestment:
            return [#"日息[0-9.]+"#, #"月息低至[0-9.]+"#, #"额度[0-9,]+万(元)?(已|可)?"#]
        case .gamblingAndTask:
            return [#"日赚[0-9,]+"#, #"月入[0-9]+万(不是梦)?"#]
        case .marketingOptOut:
            return []
        case .englishPromo:
            return [#"\b(loan|casino|jackpot)\b.*\b(now|today|click)\b"#]
        }
    }
}

/// Pure, deterministic SMS/call classifier over user rules + enabled presets.
/// It performs no I/O and is safe to call on any thread.
struct SpamPolicy {
    var rules: [SpamRule]
    var enabledPresets: Set<SpamPreset>

    init(rules: [SpamRule] = [], enabledPresets: Set<SpamPreset> = []) {
        self.rules = rules
        self.enabledPresets = enabledPresets
    }

    // MARK: SMS

    /// Classify an inbound message.
    /// - Parameter isKnownSender: true when the thread already exists or the
    ///   owner previously marked the sender known.
    func classifySMS(peer rawPeer: String, body rawBody: String, isKnownSender: Bool) -> SpamVerdict {
        let peer = rawPeer.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        let peerKeys = Set(PhoneNormalizer.canonicalKeys(peer))

        // 1. Explicit trust always wins.
        for rule in enabledRules(of: .whitelistSender) where matchesPeer(rule.value, keys: peerKeys) {
            return .allow(reason: rule.label.isEmpty ? "信任号码" : rule.label)
        }
        for rule in enabledRules(of: .whitelistKeyword) where body.localizedCaseInsensitiveContains(rule.value) {
            return .allow(reason: rule.label.isEmpty ? "信任关键词" : rule.label)
        }

        // 2. Explicit owner block rules (exact number / prefix / body).
        for rule in enabledRules(of: .senderExact) where matchesPeer(rule.value, keys: peerKeys) {
            return .junk(reason: reason(rule, fallback: "已拦截号码"))
        }
        for rule in enabledRules(of: .numberPrefix) where matchesPrefix(rule.value, peer: peer, keys: peerKeys) {
            return .junk(reason: reason(rule, fallback: "号码前缀命中"))
        }

        // 3. Built-in presets, but only when the message doesn't carry a strong
        //    legitimate OTP/transaction/parcel marker.
        let trustedByNature = isProtectedTransaction(body)
        if !trustedByNature {
            for rule in enabledRules(of: .keyword) where body.localizedCaseInsensitiveContains(rule.value) {
                return .junk(reason: reason(rule, fallback: "关键词命中"))
            }
            for rule in enabledRules(of: .regex) {
                if let regex = compiled(rule.value), regexFirstMatch(regex, body) {
                    return .junk(reason: reason(rule, fallback: "正则命中"))
                }
            }
            for preset in enabledPresets {
                for word in preset.keywords where body.localizedCaseInsensitiveContains(word) {
                    return .junk(reason: preset.displayName)
                }
                for pattern in preset.regexes {
                    if let regex = compiled(pattern), regexFirstMatch(regex, body) {
                        return .junk(reason: preset.displayName)
                    }
                }
            }
        }

        // 4. Unknown sender is normal, not junk.
        return .unknown
    }

    /// Strong, narrow signals of genuine automated messages the owner needs.
    /// Deliberately NOT "contains 验证码 or 订单" alone — scam messages embed
    /// those words, so we require the code/transaction structure too.
    func isProtectedTransaction(_ body: String) -> Bool {
        // OTP: verification keyword within a short message + a 4-8 digit code.
        let otpMarker = body.contains("验证码") || body.contains("校验码") || body.contains("动态码")
            || body.localizedCaseInsensitiveContains("verification code")
            || body.localizedCaseInsensitiveContains("one-time code")
            || body.localizedCaseInsensitiveContains("otp")
        let hasCode = hasStandaloneCode(body)
        if otpMarker && hasCode { return true }

        // Parcel/courier delivery notices with a tracking number structure.
        let parcel = body.contains("快递") || body.contains("取件码") || body.contains("包裹")
            || body.localizedCaseInsensitiveContains("delivery")
        if parcel && hasCode { return true }

        return false
    }

    // MARK: Calls

    /// Evaluate an inbound call peer against owner block rules and imported
    /// number lists. `listMode` records how each imported list acts.
    func screenCall(
        peer rawPeer: String,
        listHits: [(mode: NumberListMode, listName: String)]
    ) -> CallScreening {
        let peer = rawPeer.trimmingCharacters(in: .whitespacesAndNewlines)
        let keys = Set(PhoneNormalizer.canonicalKeys(peer))

        for rule in enabledRules(of: .whitelistSender) where matchesPeer(rule.value, keys: keys) {
            return .allow
        }
        for rule in enabledRules(of: .senderExact) where matchesPeer(rule.value, keys: keys) {
            return .reject(reason: reason(rule, fallback: "已拦截号码"))
        }
        for rule in enabledRules(of: .numberPrefix) where matchesPrefix(rule.value, peer: peer, keys: keys) {
            return .reject(reason: reason(rule, fallback: "号码前缀命中"))
        }
        for hit in listHits {
            switch hit.mode {
            case .label: return .label(reason: hit.listName)
            case .reject: return .reject(reason: hit.listName)
            case .off: break
            }
        }
        return .allow
    }

    // MARK: Helpers

    private func enabledRules(of kind: SpamRule.Kind) -> [SpamRule] {
        rules.filter { $0.enabled && $0.kind == kind }
    }

    private func reason(_ rule: SpamRule, fallback: String) -> String {
        rule.label.isEmpty ? fallback : rule.label
    }

    private func matchesPeer(_ rawRule: String, keys: Set<String>) -> Bool {
        let rule = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty else { return false }
        let ruleKeys = Set(PhoneNormalizer.canonicalKeys(rule))
        return !keys.isDisjoint(with: ruleKeys)
    }

    private func matchesPrefix(_ rawPrefix: String, peer: String, keys: Set<String>) -> Bool {
        let prefix = PhoneNormalizer.digits(rawPrefix)
        guard !prefix.isEmpty else { return false }
        let peerDigits = PhoneNormalizer.digits(peer)
        if peerDigits.hasPrefix(prefix) { return true }
        // Also test against the +86/0086 canonical spellings.
        return keys.contains { $0.hasPrefix(prefix) }
    }

    private func compiled(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private func regexFirstMatch(_ regex: NSRegularExpression, _ body: String) -> Bool {
        let range = NSRange(body.startIndex..., in: body)
        return regex.firstMatch(in: body, range: range) != nil
    }

    private var codeRegex: NSRegularExpression {
        try! NSRegularExpression(pattern: #"(?<![0-9])([0-9]{4,8})(?![0-9])"#)
    }

    private func hasStandaloneCode(_ body: String) -> Bool {
        let range = NSRange(body.startIndex..., in: body)
        return codeRegex.firstMatch(in: body, range: range) != nil
    }
}

/// How an imported number list affects matching calls.
enum NumberListMode: String, Codable, CaseIterable {
    case off
    case label
    case reject

    var displayName: String {
        switch self {
        case .off: return "不启用"
        case .label: return "仅标记（仍响铃）"
        case .reject: return "拦截来电（静音）"
        }
    }
}
