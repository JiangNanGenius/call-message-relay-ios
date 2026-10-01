import Foundation

/// Result of applying a pull to a local snapshot. Besides the new snapshot it
/// reports exactly which visible records changed, so the app layer can apply
/// downloaded history/rules at runtime without diffing everything itself.
struct CloudMergeReport {
    var snapshot: SyncSnapshot
    var upsertedMessages: [SyncedMessage] = []
    var removedMessageIDs: Set<String> = []
    var upsertedCalls: [SyncedCall] = []
    var removedCallIDs: Set<String> = []
    var upsertedListSettings: [SyncedListSetting] = []
    var removedListSettingIDs: Set<String> = []
    var rules: SyncedRules?
    var rulesDeleted: Bool = false
    /// True when everything previously downloaded was discarded first
    /// (account/generation reset): the app layer must purge displayed rows.
    var resetDisplay: Bool = false
}

/// Pure, deterministic convergence rules shared by the engine and tests.
///
/// Convergence contract:
///   * writers PULL before PUSH, so a pending upsert is dropped when the pull
///     shows a newer remote write or a replicated tombstone;
///   * deletes are replicated tombstone RECORDS (entity-aware). A tombstone
///     shadows content with `updatedAt <= deletedAt`; content strictly newer
///     than the tombstone wins and the tombstone is forgotten locally;
///   * everything else is last-writer-wins by `updatedAt`.
enum CloudConvergence {

    static func merge(pull: SyncPullResult, into snapshot: SyncSnapshot) -> CloudMergeReport {
        var s = snapshot
        var report = CloudMergeReport(snapshot: s)

        // 1) Adopt remote tombstones (entity-aware, LWW on deletedAt).
        for incoming in pull.tombstones {
            if let existing = s.tombstones.first(where: { $0.key == incoming.key }) {
                if incoming.deletedAt > existing.deletedAt {
                    s.tombstones.removeAll { $0.key == incoming.key }
                    s.tombstones.append(incoming)
                }
            } else {
                s.tombstones.append(incoming)
            }
        }

        // 2) Content.
        for message in pull.messages {
            applyContent(message, snapshot: &s, report: &report, kind: .message)
        }
        for call in pull.calls {
            applyContent(call, snapshot: &s, report: &report, kind: .call)
        }
        for setting in pull.listSettings {
            applyContent(setting, snapshot: &s, report: &report, kind: .listSetting)
        }
        if let remoteRules = pull.rules {
            if let tombstone = tombstone(entity: .rule, id: CloudSyncEngine.rulesLogicalID, in: s),
               remoteRules.updatedAt <= tombstone.deletedAt {
                if s.rules != nil {
                    s.rules = nil
                    report.rulesDeleted = true
                }
            } else if s.rules == nil || remoteRules.updatedAt >= (s.rules?.updatedAt ?? .distantPast) {
                if s.rules != remoteRules {
                    s.rules = remoteRules
                    report.rules = remoteRules
                }
            }
        }

        // 3) Apply tombstone shadows to content not present in this pull.
        applyTombstoneShadows(snapshot: &s, report: &report)

        report.snapshot = s
        return report
    }

    private enum ContentKind { case message, call, listSetting }

    private static func applyContent(_ message: SyncedMessage, snapshot s: inout SyncSnapshot,
                                     report: inout CloudMergeReport, kind: ContentKind) {
        guard kind == .message else { return }
        if let tomb = tombstone(entity: .message, id: message.id, in: s) {
            if message.updatedAt <= tomb.deletedAt {
                if let idx = s.messages.firstIndex(where: { $0.id == message.id }) {
                    s.messages.remove(at: idx)
                    report.removedMessageIDs.insert(message.id)
                }
                return
            }
            // Content is strictly newer than the delete: it wins.
            s.tombstones.removeAll { $0.key == tomb.key }
        }
        if let current = s.messages.first(where: { $0.id == message.id }) {
            if message.updatedAt >= current.updatedAt, message != current {
                s.messages.removeAll { $0.id == message.id }
                s.messages.append(message)
                report.upsertedMessages.append(message)
            }
        } else {
            s.messages.append(message)
            report.upsertedMessages.append(message)
        }
    }

    private static func applyContent(_ call: SyncedCall, snapshot s: inout SyncSnapshot,
                                     report: inout CloudMergeReport, kind: ContentKind) {
        guard kind == .call else { return }
        if let tomb = tombstone(entity: .call, id: call.id, in: s) {
            if call.updatedAt <= tomb.deletedAt {
                if s.calls.contains(where: { $0.id == call.id }) {
                    s.calls.removeAll { $0.id == call.id }
                    report.removedCallIDs.insert(call.id)
                }
                return
            }
            s.tombstones.removeAll { $0.key == tomb.key }
        }
        if let current = s.calls.first(where: { $0.id == call.id }) {
            if call.updatedAt >= current.updatedAt, call != current {
                s.calls.removeAll { $0.id == call.id }
                s.calls.append(call)
                report.upsertedCalls.append(call)
            }
        } else {
            s.calls.append(call)
            report.upsertedCalls.append(call)
        }
    }

    private static func applyContent(_ setting: SyncedListSetting, snapshot s: inout SyncSnapshot,
                                     report: inout CloudMergeReport, kind: ContentKind) {
        guard kind == .listSetting else { return }
        if let tomb = tombstone(entity: .listSetting, id: setting.id, in: s) {
            if setting.updatedAt <= tomb.deletedAt {
                if s.listSettings.contains(where: { $0.id == setting.id }) {
                    s.listSettings.removeAll { $0.id == setting.id }
                    report.removedListSettingIDs.insert(setting.id)
                }
                return
            }
            s.tombstones.removeAll { $0.key == tomb.key }
        }
        if let current = s.listSettings.first(where: { $0.id == setting.id }) {
            if setting.updatedAt >= current.updatedAt, setting != current {
                s.listSettings.removeAll { $0.id == setting.id }
                s.listSettings.append(setting)
                report.upsertedListSettings.append(setting)
            }
        } else {
            s.listSettings.append(setting)
            report.upsertedListSettings.append(setting)
        }
    }

    /// Remove local content shadowed by a tombstone even when the pull did not
    /// re-deliver the content record (e.g. first pull on a new device).
    private static func applyTombstoneShadows(snapshot s: inout SyncSnapshot, report: inout CloudMergeReport) {
        for tomb in s.tombstones {
            switch tomb.entity {
            case .message:
                if let item = s.messages.first(where: { $0.id == tomb.logicalID }),
                   item.updatedAt <= tomb.deletedAt {
                    s.messages.removeAll { $0.id == tomb.logicalID }
                    report.removedMessageIDs.insert(tomb.logicalID)
                }
            case .call:
                if let item = s.calls.first(where: { $0.id == tomb.logicalID }),
                   item.updatedAt <= tomb.deletedAt {
                    s.calls.removeAll { $0.id == tomb.logicalID }
                    report.removedCallIDs.insert(tomb.logicalID)
                }
            case .listSetting:
                if let item = s.listSettings.first(where: { $0.id == tomb.logicalID }),
                   item.updatedAt <= tomb.deletedAt {
                    s.listSettings.removeAll { $0.id == tomb.logicalID }
                    report.removedListSettingIDs.insert(tomb.logicalID)
                }
            case .rule:
                if tomb.logicalID == CloudSyncEngine.rulesLogicalID,
                   let rules = s.rules, rules.updatedAt <= tomb.deletedAt {
                    s.rules = nil
                    report.rulesDeleted = true
                }
            case .tombstone:
                break
            }
        }
    }

    static func tombstone(entity: SyncEntity, id: String, in snapshot: SyncSnapshot) -> SyncTombstone? {
        snapshot.tombstones.first { $0.entity == entity && $0.logicalID == id }
    }

    /// Drop pending changes made obsolete by a just-merged pull: a replicated
    /// tombstone or a newer remote record supersedes a local upsert/delete.
    static func prunePending(against snapshot: SyncSnapshot) -> [SyncPendingChange] {
        snapshot.pending.filter { change in
            switch change.op {
            case .upsert:
                // A replicated delete at/after our edit kills the upsert.
                if let tomb = tombstone(entity: change.entity, id: change.logicalID, in: snapshot),
                   tomb.deletedAt >= change.updatedAt {
                    return false
                }
                // Remote content strictly newer than our queued edit supersedes it.
                let remoteUpdated: Date?
                switch change.entity {
                case .message:
                    remoteUpdated = snapshot.messages.first { $0.id == change.logicalID }?.updatedAt
                case .call:
                    remoteUpdated = snapshot.calls.first { $0.id == change.logicalID }?.updatedAt
                case .listSetting:
                    remoteUpdated = snapshot.listSettings.first { $0.id == change.logicalID }?.updatedAt
                case .rule:
                    remoteUpdated = snapshot.rules?.updatedAt
                case .tombstone:
                    remoteUpdated = nil
                }
                if let remoteUpdated, remoteUpdated > change.updatedAt { return false }
                return true
            case .delete:
                // A remote write strictly newer than our delete supersedes it.
                let remoteUpdated: Date?
                switch change.entity {
                case .message:
                    remoteUpdated = snapshot.messages.first { $0.id == change.logicalID }?.updatedAt
                case .call:
                    remoteUpdated = snapshot.calls.first { $0.id == change.logicalID }?.updatedAt
                case .listSetting:
                    remoteUpdated = snapshot.listSettings.first { $0.id == change.logicalID }?.updatedAt
                case .rule:
                    remoteUpdated = snapshot.rules?.updatedAt
                case .tombstone:
                    remoteUpdated = nil
                }
                if let remoteUpdated, remoteUpdated > change.updatedAt { return false }
                return true
            }
        }
    }

    /// Merge server-side conflicts returned by a push into the snapshot and
    /// return which pending changes are now obsolete (the server value won).
    /// Conflict anchors are stored so a later local edit pushes against the
    /// actual server version instead of starting from a blind create.
    static func applyConflicts(_ conflicts: [String: SyncConflict],
                               into snapshot: inout SyncSnapshot) -> Set<String> {
        var obsolete: Set<String> = []
        for (recordName, conflict) in conflicts {
            guard let parsed = SyncEntity.fromContentRecordName(recordName) else { continue }
            let (entity, logicalID) = parsed
            if let anchor = conflict.anchor { snapshot.recordAnchors[recordName] = anchor }
            switch conflict.value {
            case .message(let message):
                if let current = snapshot.messages.first(where: { $0.id == logicalID }) {
                    if message.updatedAt >= current.updatedAt {
                        snapshot.messages.removeAll { $0.id == logicalID }
                        snapshot.messages.append(message)
                    }
                } else {
                    snapshot.messages.append(message)
                }
                if snapshot.pending.contains(where: {
                    $0.entity == .message && $0.logicalID == logicalID
                        && $0.updatedAt <= message.updatedAt
                }) { obsolete.insert(recordName) }
            case .call(let call):
                if let current = snapshot.calls.first(where: { $0.id == logicalID }),
                   current.updatedAt > call.updatedAt { break }
                snapshot.calls.removeAll { $0.id == logicalID }
                snapshot.calls.append(call)
                if snapshot.pending.contains(where: {
                    $0.entity == .call && $0.logicalID == logicalID
                        && $0.updatedAt <= call.updatedAt
                }) { obsolete.insert(recordName) }
            case .rules(let rules):
                if snapshot.rules == nil || rules.updatedAt >= (snapshot.rules?.updatedAt ?? .distantPast) {
                    snapshot.rules = rules
                }
                if (snapshot.pending.contains {
                    $0.entity == .rule && $0.updatedAt <= rules.updatedAt
                }) { obsolete.insert(recordName) }
            case .listSetting(let setting):
                if let current = snapshot.listSettings.first(where: { $0.id == logicalID }),
                   current.updatedAt > setting.updatedAt { break }
                snapshot.listSettings.removeAll { $0.id == setting.id }
                snapshot.listSettings.append(setting)
                if snapshot.pending.contains(where: {
                    $0.entity == .listSetting && $0.logicalID == logicalID
                        && $0.updatedAt <= setting.updatedAt
                }) { obsolete.insert(recordName) }
            case .tombstone(let deletedAt):
                let tomb = SyncTombstone(logicalID: logicalID, entity: entity, deletedAt: deletedAt)
                if let existing = snapshot.tombstones.first(where: { $0.key == tomb.key }) {
                    if deletedAt > existing.deletedAt {
                        snapshot.tombstones.removeAll { $0.key == tomb.key }
                        snapshot.tombstones.append(tomb)
                    }
                } else {
                    snapshot.tombstones.append(tomb)
                }
                // A local delete older than/equal to the server tombstone is
                // done; a NEWER local delete must be retried against the
                // server tombstone version (anchor supplied by the transport).
                let localDeleteAcked = snapshot.pending.contains {
                    $0.entity == entity && $0.logicalID == logicalID
                        && $0.op == .delete && $0.updatedAt <= deletedAt
                }
                if localDeleteAcked { obsolete.insert(recordName) }
            }
        }
        return obsolete
    }

    /// Discard all downloaded/queued state for an account change or sign-out.
    /// Local gateway data (inbox, recents, spam store) is untouched; the app
    /// layer receives a reset delta so it can purge DISPLAYED restored rows.
    static func wipeAccountState(_ snapshot: SyncSnapshot, accountToken: String?) -> SyncSnapshot {
        var wiped = snapshot
        wiped.messages = []
        wiped.calls = []
        wiped.rules = nil
        wiped.listSettings = []
        wiped.tombstones = []
        wiped.pending = []
        wiped.serverChangeToken = nil
        wiped.recordAnchors = [:]
        wiped.lastRulesSignature = nil
        wiped.accountToken = accountToken
        wiped.gatewayScopes = []
        return wiped
    }

    /// Content signature used to avoid a push feedback loop: inbound rules
    /// applied to the spam store must not be re-enqueued with timestamp=now.
    static func rulesSignature(_ rules: SyncedRules) -> String {
        let encoder = JSONEncoder.iso
        let body = RulesBody(rules: rules.rules,
                             enabledPresets: rules.enabledPresets.sorted(),
                             knownSenders: rules.knownSenders.sorted())
        let data = (try? encoder.encode(body)) ?? Data()
        return SHA256Lite.hex(data)
    }

    private struct RulesBody: Codable {
        let rules: [SpamRule]
        let enabledPresets: [String]
        let knownSenders: [String]
    }
}

private extension Date {
    static let distantPast = Date(timeIntervalSince1970: 0)
}
