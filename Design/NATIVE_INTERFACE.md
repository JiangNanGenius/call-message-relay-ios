# Native calling and messages

Mode: Operate. The user requested the colors and layout of the native iPhone Phone and Messages apps. Their personal reference screenshots are private visual references and are not repository assets or demo content.

## Appearance

- Follow system light and dark appearance. Use system backgrounds, primary text and secondary gray text.
- Blue navigation, selected tabs, compose, search, filters and callback actions. The AccentColor asset is #007AFF in light appearance and #0A84FF in dark appearance.
- Green round dial/answer controls. Red hangup, destructive actions and missed-call numbers. Demo status stays neutral.
- Plain white/black message and recent-call lists with round avatars and native separators. Native navigation bars, search and TabView own their materials.
- The dial pad uses normal system digits, small letter captions, subtle circular keys and generous space. Connection status remains visible without dominating the dial pad.
- Received SMS uses a gray bubble on the main background; outgoing SMS uses green with readable text in both appearances. Composer and recovery actions remain easy to reach.
- Contacts use a native searchable list, permission recovery and phone selection for calls or SMS. Deduplicated vCard export shows a preview and preserves the original system contacts.

## Filtering and recovery

- Unknown senders and junk are separate. Legitimate verification, transaction and delivery notifications remain available.
- Local rules have visible names, switches and match reasons. White lists and restore actions let users resolve false positives.
- A historical Chinese community number list must display its actual date, source and size. It starts disabled; users choose whether to label or reject matching calls.
- Reconnection state describes what is happening and offers an immediate retry where useful. Resuming a connection never means automatically starting a new call or duplicating an SMS.
- Contacts follow system iCloud Contacts. SMS history, call history and filtering rules use optional private iCloud synchronization with account/gateway isolation and a visible sync state. Restored history cannot become a pending send or dial operation. Pairing credentials remain device-bound.
- The unsigned/self-signed baseline must remain usable without CloudKit permissions and describe the missing signing/container configuration accurately.

## Acceptance

Inspect the actual demo UI, contacts/export and filtering flows in light and dark appearance using synthetic reserved numbers and fictional messages. Public screenshots must never contain the user's contacts, telephone numbers, messages, tokens or pairing data. Simulator evidence does not establish real call, SMS, APNs, signing or provisioned two-device iCloud synchronization.
