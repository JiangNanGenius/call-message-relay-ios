import AppIntents
import Foundation

/// Thin Shortcuts surface over the app's existing routing. Every intent only
/// validates its inputs and stages an ``IntentHandoff``; the real work always
/// happens in the app through the same code paths as the in-UI entry points
/// (gateway dial with explicit line choice, compose sheet with in-app
/// confirmation). Intents never dial, never send SMS, and never substitute
/// an unauthorized line.
struct CallNumberIntent: AppIntent {
    static var title: LocalizedStringResource = "用 CallRelay 拨打"

    static var description: IntentDescription? {
        IntentDescription("通过已授权的网关线路拨打电话。可选择线路；不选择时使用现有默认线路偏好。线路不可用会在 App 内说明，绝不改用蜂窝电话。")
    }

    /// The app must come forward: dialing runs through the live gateway
    /// driver and, when the line choice is missing, the explicit chooser.
    static var openAppWhenRun: Bool = true

    @Parameter(title: "号码", description: "要拨打的号码，例如 +86 130 0000 0000。")
    var number: String

    @Parameter(title: "线路", description: "用于外呼的已授权线路；不选则沿用现有默认偏好。")
    var line: RelayLineEntity?

    func perform() async throws -> some IntentResult {
        let peer = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peer.isEmpty else { throw CallRelayIntentError.emptyNumber }
        guard peer.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else {
            throw CallRelayIntentError.invalidNumber
        }
        IntentHandoffCenter.shared.stage(.call(peer: peer, lineID: line?.id))
        // Route immediately when the app is already foreground; otherwise the
        // staged handoff waits for the cold-start .task / foreground consumer.
        IntentHandoffCenter.shared.wakeConsumer()
        return .result()
    }
}

/// Accurately named COMPOSE intent: it opens the CallRelay composer
/// prefilled with recipient/body/line and the user confirms in-app. It never
/// claims a message was sent — the gateway send only happens on the
/// explicit in-app confirmation, through the normal outbox path.
struct ComposeMessageIntent: AppIntent {
    static var title: LocalizedStringResource = "在 CallRelay 中编写短信"

    static var description: IntentDescription? {
        IntentDescription("在 CallRelay 中打开发短信界面并预填收件人、内容与线路；发送需在 App 内确认。")
    }

    static var openAppWhenRun: Bool = true

    @Parameter(title: "号码", description: "收件人号码，例如 +86 130 0000 0000。")
    var number: String

    @Parameter(title: "内容", description: "短信正文。")
    var body: String

    @Parameter(title: "线路", description: "用于发送的已授权线路；不选则沿用现有默认偏好。")
    var line: RelayLineEntity?

    func perform() async throws -> some IntentResult {
        let peer = number.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !peer.isEmpty else { throw CallRelayIntentError.emptyNumber }
        guard peer.unicodeScalars.contains(where: { CharacterSet.decimalDigits.contains($0) }) else {
            throw CallRelayIntentError.invalidNumber
        }
        IntentHandoffCenter.shared.stage(.compose(
            peer: peer,
            body: body.trimmingCharacters(in: .whitespacesAndNewlines),
            lineID: line?.id
        ))
        IntentHandoffCenter.shared.wakeConsumer()
        return .result()
    }
}

/// Open a fixed CallRelay destination from Shortcuts. Pure navigation: no
/// call is placed and no message is touched.
struct OpenCallRelayDestinationIntent: AppIntent {
    static var title: LocalizedStringResource = "打开 CallRelay"

    static var description: IntentDescription? {
        IntentDescription("打开 CallRelay 的拨号键盘、短信或语音留言。")
    }

    static var openAppWhenRun: Bool = true

    @Parameter(title: "目的地", description: "拨号键盘、短信或语音留言。")
    var destination: CallRelayDestination

    func perform() async throws -> some IntentResult {
        IntentHandoffCenter.shared.stage(.destination(destination))
        IntentHandoffCenter.shared.wakeConsumer()
        return .result()
    }
}
