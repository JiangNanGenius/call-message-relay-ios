import Foundation
import Intents

/// Donates the `INStartCallIntent` for outgoing calls so the system Phone app
/// stores a Recents row that can relaunch this app with the same peer. The
/// call itself is still owned by CallKit (`includesCallsInRecents = true`);
/// the donation only attaches the start-call interaction, per Apple's
/// INStartCallIntent guidance for CallKit apps. Audio only — video intents are
/// never donated by this app.
enum CallIntentDonor {
    static func donateOutgoing(peer: String) {
        let personHandle: INPersonHandle
        if CallKitManager.handleType(for: peer) == .phoneNumber {
            personHandle = INPersonHandle(value: peer, type: .phoneNumber)
        } else {
            personHandle = INPersonHandle(value: peer, type: .unknown)
        }
        let person = INPerson(
            personHandle: personHandle, nameComponents: nil, displayName: nil,
            image: nil, contactIdentifier: nil, customIdentifier: nil
        )
        let intent = INStartCallIntent(
            callRecordFilter: nil,
            callRecordToCallBack: nil,
            audioRoute: .unknown,
            destinationType: .normal,
            contacts: [person],
            callCapability: .audioCall
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.donate { error in
            if let error {
                AppLog.callKit.notice("start call intent donation failed: \(error.localizedDescription)")
            }
        }
    }
}
