import XCTest
@testable import CallRelay

final class PhoneNormalizerTests: XCTestCase {
    func testMobileVariantsShareCanonicalKeys() {
        let keys = PhoneNormalizer.canonicalKeys("138 1234 5678")
        XCTAssertTrue(keys.contains("13812345678"))
        XCTAssertTrue(keys.contains("8613812345678"))
        XCTAssertTrue(keys.contains("008613812345678"))
        // +86 and 0086 spellings must intersect the local spelling.
        let plus = Set(PhoneNormalizer.canonicalKeys("+86 138-1234-5678"))
        XCTAssertTrue(plus.contains("13812345678"))
        let long = Set(PhoneNormalizer.canonicalKeys("008613812345678"))
        XCTAssertTrue(long.contains("13812345678"))
    }

    func testOrdinaryNumberIsNotMainlandMobile() {
        // A 10-digit string must not be widened into a mobile match.
        XCTAssertFalse(PhoneNormalizer.isMainlandMobile("1331234567"))
        // Real 11-digit mobile with valid leading digit.
        XCTAssertTrue(PhoneNormalizer.isMainlandMobile("15912345678"))
        // 10x/11x/12x are not mobile prefixes.
        XCTAssertFalse(PhoneNormalizer.isMainlandMobile("10912345678"))
    }

    func testLandlineAreaCodeVariants() {
        // Shanghai 021 + 8 digits.
        let sh = PhoneNormalizer.canonicalKeys("021-5566-7788")
        XCTAssertTrue(sh.contains("02155667788"))
        XCTAssertTrue(sh.contains("862155667788"))
        // Jinan 0531 + 8 digits.
        let jn = PhoneNormalizer.canonicalKeys("0531 5566 778")
        XCTAssertTrue(jn.contains("05315566778"))
        XCTAssertTrue(jn.contains("865315566778"))
    }

    func testShortCodesAreExactOnly() {
        let keys = PhoneNormalizer.canonicalKeys("10691234567890")
        XCTAssertTrue(keys.contains("10691234567890"))
        // No fabricated 86 expansion for service numbers.
        XCTAssertFalse(keys.contains("8610691234567890"))
    }

    func testFormattingNoiseIsStripped() {
        XCTAssertEqual(PhoneNormalizer.digits("(021) 5566-7788"), "02155667788")
        XCTAssertEqual(PhoneNormalizer.digits("+86 138 1234 5678"), "8613812345678")
    }
}

final class SpamPolicyTests: XCTestCase {
    private func policy(_ presets: Set<SpamPreset> = [], rules: [SpamRule] = []) -> SpamPolicy {
        SpamPolicy(rules: rules, enabledPresets: presets)
    }    // MARK: Unknown never implies spam

    func testUnknownSenderIsNotSpamByDefault() {
        let verdict = policy().classifySMS(peer: "555-0199", body: "晚上一起吃饭吗？", isKnownSender: false)
        XCTAssertEqual(verdict, .unknown)
    }

    func testUnknownShortCodeWithOrdinaryNoticeStaysUnknown() {
        let verdict = policy([.marketingOptOut])
            .classifySMS(peer: "10010", body: "您的余额为 100 元。", isKnownSender: false)
        XCTAssertEqual(verdict, .unknown)
    }

    // MARK: Genuine OTP / transactions protected

    func testOTPWithCodeIsProtectedFromKeywordPreset() {
        // Contains a real marketing keyword AND a structured verification
        // code: the OTP structure must win over the body keyword.
        let body = "【银行】全场包邮会员日提醒，您的验证码 246810，正在登录手机银行，5 分钟有效，请勿泄露。"
        let verdict = policy([.loanAndInvestment, .marketingOptOut])
            .classifySMS(peer: "555-0100", body: body, isKnownSender: false)
        XCTAssertFalse(verdict.isJunk)
    }

    func testOTPWordAloneDoesNotBypassScamRule() {
        // "验证码" with no actual 4-8 digit code does NOT grant protection.
        let body = "教你轻松提额，验证码操作即可获得无抵押贷款额度。"
        let verdict = policy([.loanAndInvestment])
            .classifySMS(peer: "555-0107", body: body, isKnownSender: false)
        guard case .junk = verdict else { return XCTFail("expected junk without a real code") }
    }

    func testParcelCodeProtectedAgainstMarketingKeyword() {
        // Real delivery notice with a code, even though it mentions a promo.
        let body = "【快递】您的包裹已到代收点，取件码 8-3-2091；新用户首单全场包邮。"
        let verdict = policy([.marketingOptOut])
            .classifySMS(peer: "555-0101", body: body, isKnownSender: false)
        XCTAssertFalse(verdict.isJunk)
    }

    func testOrderWordDoesNotBypassScamRule() {
        // The word 订单 appears but the message is a classic 刷单 scam.
        let body = "您的订单获得刷单返佣资格，垫付 100 元日赚 800，速来报名。"
        let verdict = policy([.gamblingAndTask])
            .classifySMS(peer: "555-0102", body: body, isKnownSender: false)
        guard case .junk = verdict else { return XCTFail("expected junk, got \(verdict)") }
    }

    func testMarketingOptOutPhraseIsJunk() {
        let body = "【商场】会员日全场包邮清仓特价，回T退订。"
        let verdict = policy([.marketingOptOut])
            .classifySMS(peer: "555-0103", body: body, isKnownSender: false)
        guard case .junk = verdict else { return XCTFail("expected junk") }
    }

    func testLoanSolicitationIsJunk() {
        let body = "无需抵押，无抵押贷款额度最高 50 万，低息贷款极速放款。"
        let verdict = policy([.loanAndInvestment])
            .classifySMS(peer: "555-0104", body: body, isKnownSender: false)
        guard case .junk = verdict else { return XCTFail("expected junk") }
    }

    // MARK: Whitelist precedence

    func testWhitelistedSenderBeatsBlockRuleAndPreset() {
        let rules = [
            SpamRule(kind: .senderExact, value: "555-0105"),
            SpamRule(kind: .whitelistSender, value: "555-0105", label: "客户")
        ]
        let verdict = policy([.gamblingAndTask], rules: rules)
            .classifySMS(peer: "555-0105", body: "刷单", isKnownSender: false)
        guard case .allow = verdict else { return XCTFail("expected allow, got \(verdict)") }
    }

    func testWhitelistKeywordProtectsBody() {
        let rules = [SpamRule(kind: .whitelistKeyword, value: "公司内网")]
        let verdict = policy([.loanAndInvestment], rules: rules)
            .classifySMS(peer: "555-0106", body: "公司内网通知：低息贷款培训改期。", isKnownSender: false)
        guard case .allow = verdict else { return XCTFail("expected allow") }
    }

    // MARK: User rules

    func testExactSenderAndPrefixRules() {
        let rules = [
            SpamRule(kind: .senderExact, value: "+86 138 0000 0000"),
            SpamRule(kind: .numberPrefix, value: "400")
        ]
        let p = policy(rules: rules)
        guard case .junk = p.classifySMS(peer: "13800000000", body: "x", isKnownSender: false) else {
            return XCTFail("exact sender rule should fire")
        }
        guard case .junk = p.classifySMS(peer: "4008012345", body: "x", isKnownSender: false) else {
            return XCTFail("prefix rule should fire")
        }
        XCTAssertEqual(p.classifySMS(peer: "5550123", body: "x", isKnownSender: false), .unknown)
    }

    func testKeywordAndRegexRules() {
        let rules = [
            SpamRule(kind: .keyword, value: "VIP会所"),
            SpamRule(kind: .regex, value: #"加[微V]\s*[0-9]{5,}"#)
        ]
        let p = policy(rules: rules)
        guard case .junk = p.classifySMS(peer: "1", body: "VIP会所招聘", isKnownSender: false) else {
            return XCTFail("keyword rule should fire")
        }
        guard case .junk = p.classifySMS(peer: "2", body: "详情加微 12345 了解", isKnownSender: false) else {
            return XCTFail("regex rule should fire")
        }
    }

    func testDisabledRulesDoNotFire() {
        let rules = [SpamRule(kind: .keyword, value: "刷单", enabled: false)]
        let verdict = policy(rules: rules).classifySMS(peer: "1", body: "刷单兼职", isKnownSender: false)
        XCTAssertEqual(verdict, .unknown)
    }

    // MARK: Calls

    func testCallScreeningWhitelistAndReject() {
        let rules = [
            SpamRule(kind: .senderExact, value: "13900000000"),
            SpamRule(kind: .whitelistSender, value: "555-0123")
        ]
        let p = policy(rules: rules)
        guard case .reject = p.screenCall(peer: "13900000000", listHits: []) else {
            return XCTFail("expected reject")
        }
        guard case .allow = p.screenCall(peer: "555-0123", listHits: [(.reject, "list")]) else {
            return XCTFail("whitelist beats list reject")
        }
        // Label-only list keeps ringing.
        guard case .label = p.screenCall(peer: "555-0177",
                                         listHits: [(.label, "历史名单")]) else {
            return XCTFail("expected label")
        }
        XCTAssertEqual(p.screenCall(peer: "555-0188", listHits: [(.off, "x")]), .allow)
    }
}
