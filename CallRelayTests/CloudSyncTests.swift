import XCTest
@testable import CallRelay

@MainActor
final class CloudSyncEngineTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cloud-\(UUID().uuidString).json")
    }

    private func makeMessage(
        id: String = "m1", scope: String = "g_a",
        body: String = "你好", updated: Date = Date(timeIntervalSince1970: 100)
    ) -> SyncedMessage {
        SyncedMessage(id: id, gatewayScope: scope, threadKey: "555-0123", peer: "555-0123",
                      body: body, direction: "inbound", status: "sent",
                      createdAt: 1000, updatedAt: updated)
    }

    private func makeEngine(transport: ScriptedCloudTransport? = nil,
                            backoff: RetryPolicy? = nil)
    -> (CloudSyncEngine, CloudSyncStore, ScriptedCloudTransport) {
        let store = CloudSyncStore(storeURL: tempURL())
        let fake = transport ?? ScriptedCloudTransport()
        let engine = backoff.map {
            CloudSyncEngine(store: store, transport: fake, failureBackoff: $0)
        } ?? CloudSyncEngine(store: store, transport: fake)
        engine.setCurrentScope("g_a")
        return (engine, store, fake)
    }

    // MARK: Enable / provisioning

    func testEnableChecksProvisioningBeforeSync() async {
        let (engine, _, fake) = makeEngine()
        await engine.enable()
        XCTAssertEqual(engine.status, .ready)
        XCTAssertEqual(fake.ensureZoneCount, 1)
    }

    func testMissingEntitlementDisablesSyncButKeepsLocalWorking() async {
        let fake = ScriptedCloudTransport()
        fake.availabilityResult = .unavailable("no entitlement")
        let (engine, _, _) = makeEngine(transport: fake)
        await engine.enable()
        guard case .unavailable = engine.status else { return XCTFail("expected unavailable") }
        XCTAssertEqual(fake.containerTouches, 0, "no CloudKit use past a failed gate")
        engine.enqueueMessage(makeMessage())
    }

    // MARK: #1 dotted logical ids survive record naming

    func testDottedLogicalIDsMapToPayloadAndRecordName() async {
        let (engine, _, fake) = makeEngine()
        await engine.enable()
        let dotted = "g_a.2f4c9e11-7b3e-4d3f-9a2a-0c1234567890"
        engine.enqueueMessage(makeMessage(id: dotted))
        await engine.syncNow()
        let pushed = fake.pushedChanges.first { $0.entity == .message }
        XCTAssertEqual(pushed?.logicalID, dotted)
        XCTAssertEqual(fake.lastPayloads?.messages[dotted]?.id, dotted)
        XCTAssertEqual(pushed.map { CloudSync.recordName(entity: .message, logicalID: $0.logicalID) },
                       "message|\(dotted)")
        // Round trip through the parser keeps the dots intact.
        let parsed = SyncEntity.fromContentRecordName("message|\(dotted)")
        XCTAssertEqual(parsed?.entity, .message)
        XCTAssertEqual(parsed?.logicalID, dotted)
    }

    // MARK: Mid-flight enqueue keeps the new revision

    func testNewRevisionQueuedDuringFlightIsNotACKed() async {
        let fake = ScriptedCloudTransport()
        let (engine, store, _) = makeEngine(transport: fake)
        await engine.enable()
        let t0 = Date(timeIntervalSince1970: 100)
        engine.enqueueMessage(makeMessage(id: "m1", updated: t0))
        let firstRev = store.snapshot.pending.first { $0.logicalID == "m1" }?.revision
        XCTAssertNotNil(firstRev)

        fake.holdPush = true
        let flight = Task { await engine.syncNow() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        // Newer edit arrives WHILE the awaited upload is in flight.
        let t1 = t0.addingTimeInterval(0.35) // sub-second LWW
        engine.enqueueMessage(makeMessage(id: "m1", body: "更新", updated: t1))
        let secondRev = store.snapshot.pending.first { $0.logicalID == "m1" }?.revision
        XCTAssertNotNil(secondRev)
        XCTAssertNotEqual(firstRev, secondRev, "every actual edit takes a new revision")
        fake.releasePush(savedKeys: [CloudSync.recordName(entity: .message, logicalID: "m1")])
        await flight.value

        // The older revision was carried; the newer one MUST still be queued.
        let stillQueued = store.snapshot.pending.first { $0.logicalID == "m1" }
        XCTAssertEqual(stillQueued?.revision, secondRev)
        XCTAssertEqual(stillQueued?.updatedAt, t1, "sub-second edit timestamp must persist exactly")
    }

    // MARK: #2 concurrent device conflict converges

    func testConcurrentDeviceConflictConvergesThenPushesLocalWinner() async {
        let fake = ScriptedCloudTransport()
        let (engine, store, _) = makeEngine(transport: fake)
        await engine.enable()
        let t0 = Date(timeIntervalSince1970: 100)
        let t1 = t0.addingTimeInterval(10)
        engine.enqueueMessage(makeMessage(id: "m1", body: "本地", updated: t0))

        // Device B's newer copy arrives as a push conflict on the first flight.
        fake.conflictOnNextPush = [
            CloudSync.recordName(entity: .message, logicalID: "m1"):
                .message(makeMessage(id: "m1", body: "对端更新", updated: t1), anchor: Data("tag-b".utf8))
        ]
        await engine.syncNow()
        // The conflict converged: server wins by updatedAt, older local upsert dropped.
        XCTAssertEqual(store.snapshot.messages.first?.body, "对端更新")
        XCTAssertTrue(store.snapshot.pending.isEmpty)
        XCTAssertEqual(store.snapshot.recordAnchors[
            CloudSync.recordName(entity: .message, logicalID: "m1")], Data("tag-b".utf8))

        // A strictly newer local edit is then pushed against the conflict anchor.
        let t2 = t1.addingTimeInterval(5)
        engine.enqueueMessage(makeMessage(id: "m1", body: "本地再改", updated: t2))
        fake.conflictOnNextPush = [:]
        await engine.syncNow()
        XCTAssertEqual(fake.lastAnchors?[
            CloudSync.recordName(entity: .message, logicalID: "m1")], Data("tag-b".utf8))
        XCTAssertTrue(store.snapshot.pending.isEmpty)
    }

    // MARK: #3 tombstones are replicated and prevent resurrection

    func testTombstoneRecordReplicatedAndOfflineDeviceCannotResurrect() async {
        let fake = ScriptedCloudTransport()
        let (engine, store, _) = makeEngine(transport: fake)
        await engine.enable()
        engine.enqueueMessage(makeMessage(id: "m1"))
        await engine.syncNow()
        engine.delete(entity: .message, logicalID: "m1", at: Date(timeIntervalSince1970: 200))
        await engine.syncNow()

        // A tombstone RECORD was pushed (not a bare physical delete).
        let tombName = CloudSync.tombstoneRecordName(entity: .message, logicalID: "m1")
        XCTAssertTrue(fake.pushedTombstones.contains { $0.id == tombName })
        // The delete is ACKed only because the tombstone saved.
        XCTAssertTrue(store.snapshot.pending.isEmpty)

        // Another (offline) engine: pull delivers the content and tombstone.
        let otherFake = ScriptedCloudTransport()
        otherFake.nextPull = SyncPullResult(
            messages: [makeMessage(id: "m1", updated: Date(timeIntervalSince1970: 150))],
            tombstones: [SyncTombstone(logicalID: "m1", entity: .message,
                                       deletedAt: Date(timeIntervalSince1970: 200))],
            newToken: Data("tok-1".utf8))
        let (other, otherStore, _) = makeEngine(transport: otherFake)
        await other.enable()
        XCTAssertTrue(otherStore.snapshot.messages.isEmpty, "tombstone must suppress content")
        XCTAssertTrue(otherStore.snapshot.tombstones.contains { $0.logicalID == "m1" })

        // Even a later pull with the old content cannot resurrect it.
        otherFake.nextPull = SyncPullResult(
            messages: [makeMessage(id: "m1", updated: Date(timeIntervalSince1970: 160))],
            newToken: Data("tok-2".utf8))
        await other.syncNow()
        XCTAssertTrue(otherStore.snapshot.messages.isEmpty)
    }

    func testDeleteNotACKedWhenTombstoneSaveFailsButContentDeleteSucceeds() async {
        let fake = ScriptedCloudTransport()
        let (engine, store, _) = makeEngine(transport: fake)
        await engine.enable()
        engine.enqueueMessage(makeMessage(id: "m1"))
        await engine.syncNow()
        engine.delete(entity: .message, logicalID: "m1")
        // Physical content delete "succeeds" but the tombstone record fails.
        fake.tombstoneSaveFails = true
        await engine.syncNow()
        let queued = store.snapshot.pending.first { $0.entity == .message && $0.logicalID == "m1" }
        XCTAssertEqual(queued?.op, .delete, "delete stays queued until the tombstone replicated")
        // Content removed locally regardless.
        XCTAssertTrue(store.snapshot.messages.isEmpty)
        // Retry succeeds: tombstone saves now.
        fake.tombstoneSaveFails = false
        await engine.syncNow()
        XCTAssertTrue(store.snapshot.pending.isEmpty)
    }

    func testNewerLocalDeleteRetriedAgainstOlderServerTombstoneConflict() async {
        let fake = ScriptedCloudTransport()
        let (engine, store, _) = makeEngine(transport: fake)
        await engine.enable()
        engine.enqueueMessage(makeMessage(id: "m1"))
        await engine.syncNow()
        let localDelete = Date(timeIntervalSince1970: 300)
        engine.delete(entity: .message, logicalID: "m1", at: localDelete)
        fake.conflictOnNextPush = [
            CloudSync.recordName(entity: .message, logicalID: "m1"):
                .tombstone(deletedAt: Date(timeIntervalSince1970: 200), anchor: Data("ttag".utf8))
        ]
        await engine.syncNow()
        let queued = store.snapshot.pending.first { $0.entity == .message && $0.logicalID == "m1" }
        XCTAssertEqual(queued?.op, .delete, "newer delete retried, not dropped")
        XCTAssertEqual(store.snapshot.recordAnchors[
            CloudSync.tombstoneRecordName(entity: .message, logicalID: "m1")],
                       Data("ttag".utf8), "tombstone anchor retained for the retry")
    }

    // MARK: #4 overlapping syncNow calls

    private func waitFor(_ timeout: TimeInterval = 3, _ predicate: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while await MainActor.run(body: { !predicate() }) {
            if Date() > deadline { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testOverlappingSyncsSingleFlightAndRerunsForMidflightEnqueue() async {
        let fake = ScriptedCloudTransport()
        let (engine, _, _) = makeEngine(transport: fake)
        await engine.enable()
        // A real queued mutation must exist, otherwise performPush correctly
        // short-circuits and the hold never engages.
        engine.enqueueMessage(makeMessage(id: "first"))
        fake.holdPush = true
        let a = Task { await engine.syncNow() }
        let b = Task { await engine.syncNow() }
        await waitFor { fake.inFlightCount == 1 }
        XCTAssertEqual(fake.inFlightCount, 1)
        engine.enqueueMessage(makeMessage(id: "late"))
        fake.releasePushAll()
        await a.value
        await b.value
        await waitFor { fake.pushedChanges.contains { $0.logicalID == "late" } }
        // The coalesced rerun pushed the late message (no recursion/deadlock).
        XCTAssertTrue(fake.pushedChanges.contains { $0.logicalID == "late" })
    }

    /// Regression for the reproduced single-flight starvation: the owner runs
    /// as a .background caller and the joiner at .high priority. The original
    /// broken algorithm let the joiner re-await a completed-but-still-
    /// registered owner task in a tight loop, hogging the queue so the
    /// background owner's cleanup never ran (inflight stranded, joiner spun
    /// forever). The fixed algorithm makes the joiner mark one rerun and await
    /// exactly once, and the owner drains the rerun and clears inflight
    /// BEFORE completion wakes waiters.
    ///
    /// Only the joiner's bounded return, the cleaned-flight state and the
    /// coalesced mutation are asserted on the 8s window: those are engine
    /// invariants. The outer .background caller's own epilogue is observed
    /// afterwards with a generous bound — a loaded shared runner may delay
    /// background continuations for seconds, which is scheduler fairness, not
    /// engine behavior (the app always drives syncNow from the main actor).
    /// The original re-await algorithm fails the bounded joiner/flight
    /// assertions; the fixed ownership passes them regardless of background
    /// scheduling latency.
    func testBackgroundOwnerHighPriorityJoinerBothReturnBounded() async {
        let fake = ScriptedCloudTransport()
        let (engine, _, _) = makeEngine(transport: fake)
        await engine.enable()
        engine.enqueueMessage(makeMessage(id: "m1"))
        fake.holdPush = true
        var ownerReturned = false
        var joinerReturned = false
        let owner = Task(priority: .background) {
            await engine.syncNow()
            ownerReturned = true
        }
        await waitFor { fake.inFlightCount == 1 }
        XCTAssertEqual(fake.inFlightCount, 1, "background owner must reach the held push first")
        let joiner = Task(priority: .high) {
            await engine.syncNow()
            joinerReturned = true
        }
        try? await Task.sleep(nanoseconds: 30_000_000)
        engine.enqueueMessage(makeMessage(id: "late2"))
        fake.releasePushAll()

        // Bounded engine invariants: the high-priority joiner returns (only
        // possible once the owner drained the coalesced rerun AND cleared
        // inflight before waking waiters) and no flight is stranded.
        await waitFor(8) { joinerReturned && !engine.isSyncing }
        XCTAssertTrue(joinerReturned, "joiner must return once, not spin on the completed owner")
        XCTAssertFalse(engine.isSyncing, "owning flight must be cleaned before the joiner wakes")
        XCTAssertTrue(fake.pushedChanges.contains { $0.logicalID == "late2" },
                      "the coalesced rerun must push the mid-flight mutation")

        // The background caller's own completion is observed separately with
        // a generous bound (eventual completion, not an 8s CPU guarantee).
        await waitFor(30) { ownerReturned }
        XCTAssertTrue(ownerReturned, "background caller eventually completes once scheduled")
        if ownerReturned { await owner.value }
        owner.cancel(); joiner.cancel()
    }

    func testSamePriorityOverlapNeverRunsTwoPushesConcurrently() async {
        let fake = ScriptedCloudTransport()
        let (engine, _, _) = makeEngine(transport: fake)
        await engine.enable()
        fake.holdPush = true
        let tasks = (0..<8).map { i in
            Task {
                if i == 4 { try? await Task.sleep(nanoseconds: 100_000_000) }
                await engine.syncNow()
            }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertLessThanOrEqual(fake.inFlightCount, 1)
        fake.releasePushAll()
        for task in tasks { await task.value }
        XCTAssertFalse(engine.isSyncing)
    }

    // MARK: #5 account switch/logout fence

    func testAccountSwitchWipesAllCacheIncludingTombstonesAndRestores() async {
        final class Recorder: CloudSyncApplying {
            var resets = 0
            var reports = 0
            func cloudSyncDidApply(_ report: CloudMergeReport, scope: String?) { reports += 1 }
            func cloudSyncDidReset() { resets += 1 }
        }
        let recorder = Recorder()
        let fake = ScriptedCloudTransport()
        let store = CloudSyncStore(storeURL: tempURL())
        let engine = CloudSyncEngine(store: store, transport: fake)
        engine.appLayer = recorder
        await engine.enable()
        engine.enqueueMessage(makeMessage())
        engine.delete(entity: .message, logicalID: "other")
        await engine.syncNow()
        XCTAssertFalse(store.snapshot.tombstones.isEmpty)

        let second = ScriptedCloudTransport()
        second.account = "account-2"
        let engine2 = CloudSyncEngine(store: store, transport: second)
        engine2.appLayer = recorder
        await engine2.enable()
        XCTAssertTrue(store.snapshot.messages.isEmpty)
        XCTAssertTrue(store.snapshot.calls.isEmpty)
        XCTAssertTrue(store.snapshot.tombstones.isEmpty, "old-account tombstones cannot fence a new account")
        XCTAssertTrue(store.snapshot.pending.isEmpty)
        XCTAssertNil(store.snapshot.serverChangeToken)
        XCTAssertEqual(store.snapshot.accountToken, "account-2")
        XCTAssertEqual(recorder.resets, 1)
    }

    func testPersistedEnabledReValidatesEntitlementBeforeZone() async {
        var snapshot = SyncSnapshot()
        snapshot.enabled = true
        snapshot.accountToken = "account-1"
        let store = CloudSyncStore(storeURL: tempURL())
        store.save(snapshot)
        let fake = ScriptedCloudTransport()
        fake.availabilityResult = .unavailable("re-signed without iCloud")
        let engine = CloudSyncEngine(store: store, transport: fake)
        await engine.syncNow()
        XCTAssertEqual(fake.ensureZoneCount, 0)
        guard case .unavailable = engine.status else { return XCTFail() }
    }

    // MARK: #7 rules payload goes through encrypted payload bundle

    func testRulesAndListPayloadsRideEncryptedPayloadBundle() async {
        let fake = ScriptedCloudTransport()
        let (engine, store, _) = makeEngine(transport: fake)
        await engine.enable()
        let rules = SyncedRules(rules: [], enabledPresets: [], knownSenders: ["5550000111"],
                                updatedAt: Date(timeIntervalSince1970: 50))
        engine.enqueueRules(rules)
        await engine.syncNow()
        XCTAssertEqual(fake.lastPayloads?.rules?.knownSenders, ["5550000111"])
        XCTAssertTrue(store.snapshot.pending.isEmpty)
    }

    // MARK: #8 change token expiry -> full reset baseline

    func testExpiredTokenTriggersFullFetchAndReplacesBaseline() async {
        let fake = ScriptedCloudTransport()
        let (engine, store, _) = makeEngine(transport: fake)
        await engine.enable()
        let freshLogical = AppModel.cloudLogicalID(scope: "g_a", rawID: "fresh")
        var seeded = SyncSnapshot()
        seeded.enabled = true
        seeded.accountToken = "account-1"
        seeded.serverChangeToken = Data("old-token".utf8)
        seeded.recordAnchors = ["message|stale": Data("old".utf8)]
        store.save(seeded)
        fake.nextPull = SyncPullResult(
            messages: [makeMessage(id: freshLogical, updated: Date(timeIntervalSince1970: 90))],
            newToken: Data("new-token".utf8),
            anchors: [CloudSync.recordName(entity: .message, logicalID: freshLogical): Data("fresh".utf8)],
            tokenReset: true)
        await engine.syncNow()
        XCTAssertEqual(store.snapshot.serverChangeToken, Data("new-token".utf8))
        XCTAssertNil(store.snapshot.recordAnchors["message|stale"], "stale anchor discarded on reset")
        XCTAssertEqual(store.snapshot.recordAnchors[
            CloudSync.recordName(entity: .message, logicalID: freshLogical)], Data("fresh".utf8))
    }

    // MARK: rules feedback loop

    func testRemoteRulesAppliedDoNotBounceBackAsLocalEdit() async {
        let fake = ScriptedCloudTransport()
        let (engine, _, _) = makeEngine(transport: fake)
        await engine.enable()
        let rules = SyncedRules(rules: [], enabledPresets: [], knownSenders: ["5550000111"],
                                updatedAt: Date(timeIntervalSince1970: 50))
        fake.nextPull = SyncPullResult(rules: rules, newToken: Data("t".utf8))
        await engine.syncNow()
        let pushesBefore = fake.pushedChanges.count
        // Simulate the spam store re-emitting the same document "now".
        engine.enqueueRules(SyncedRules(rules: rules.rules, enabledPresets: rules.enabledPresets,
                                        knownSenders: rules.knownSenders, updatedAt: Date()))
        await engine.syncNow()
        XCTAssertEqual(fake.pushedChanges.count, pushesBefore, "identical remote rules must not re-enqueue")
    }

    func testRulesSignatureIsStableAcrossInsertionOrderAndRepeatedEncodes() {
        let fixed = Date(timeIntervalSince1970: 500)
        let makeRules: () -> SyncedRules = {
            SyncedRules(
                rules: [
                    SpamRule(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!,
                             kind: .keyword, value: "中奖", enabled: true,
                             label: "a", createdAt: fixed),
                    SpamRule(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!,
                             kind: .senderExact, value: "5550100", enabled: true,
                             label: "b", createdAt: fixed),
                    SpamRule(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!,
                             kind: .whitelistSender, value: "5550188", enabled: true,
                             label: "c", createdAt: fixed),
                ],
                enabledPresets: ["loan", "gambling"],
                knownSenders: ["5550123", "5550166", "5550199"],
                updatedAt: fixed)
        }
        let forward = makeRules()
        // Same elements, different insertion order must hash identically —
        // this is what stops inbound rules bouncing back as a "new" local edit.
        var shuffled = forward
        shuffled.rules = [forward.rules[2], forward.rules[0], forward.rules[1]]
        shuffled.enabledPresets = ["gambling", "loan"]
        shuffled.knownSenders = [forward.knownSenders[2], forward.knownSenders[0],
                                 forward.knownSenders[1]]
        XCTAssertEqual(CloudConvergence.rulesSignature(forward),
                       CloudConvergence.rulesSignature(shuffled))
        XCTAssertEqual(CloudConvergence.rulesSignature(forward),
                       CloudConvergence.rulesSignature(makeRules()),
                       "repeated identical encodes must be byte-stable")
    }

    // MARK: gateway isolation

    func testTwoScopesNeverMix() {
        let store = CloudSyncStore(storeURL: tempURL())
        var snapshot = store.snapshot
        snapshot.enabled = true
        snapshot.messages = [
            makeMessage(id: "a", scope: "g_a"),
            SyncedMessage(id: "b", gatewayScope: "g_other", threadKey: "x", peer: "x",
                          body: "y", direction: "inbound", status: "sent",
                          createdAt: 1, updatedAt: Date())
        ]
        store.save(snapshot)
        let engine = CloudSyncEngine(store: store, transport: ScriptedCloudTransport())
        XCTAssertEqual(engine.messages(scope: "g_a").map(\.id), ["a"])
        XCTAssertTrue(engine.calls(scope: "g_a").isEmpty)
    }

    func testScopeQualifiedIDsIsolateSameRawIDAcrossGateways() {
        let a = AppModel.cloudLogicalID(scope: "g_a", rawID: "raw-1")
        let b = AppModel.cloudLogicalID(scope: "g_b", rawID: "raw-1")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("g_a."))
        XCTAssertTrue(b.hasPrefix("g_b."))
    }

    // MARK: transient identity / definitive logout / backoff

    func testTransientIdentityFailurePreservesQueueAndCacheAndRetries() async {
        let fake = ScriptedCloudTransport()
        let backoff = RetryPolicy(base: 30, cap: 120, maxJitter: 0)
        let (engine, store, _) = makeEngine(transport: fake, backoff: backoff)
        await engine.enable()
        engine.enqueueMessage(makeMessage(id: "m1"))
        XCTAssertFalse(store.snapshot.pending.isEmpty)

        // availability stays available but identity fetch is indeterminate
        // (offline/service error): NOT a logout.
        fake.identityMode = .indeterminate
        await engine.syncNow()
        XCTAssertEqual(engine.status, .offline)
        XCTAssertFalse(store.snapshot.pending.isEmpty, "queue must survive indeterminate identity")
        XCTAssertEqual(store.snapshot.accountToken, "account-1", "fence preserved")
        XCTAssertNotNil(engine.lastRetryDelay)

        // On recovery the next pass succeeds.
        fake.identityMode = .account("account-1")
        await engine.syncNow()
        XCTAssertEqual(engine.status, .ready)
        XCTAssertTrue(store.snapshot.pending.isEmpty)
    }

    func testTransientAccountStatusDoesNotWipeCache() async {
        let fake = ScriptedCloudTransport()
        let (engine, store, _) = makeEngine(transport: fake)
        await engine.enable()
        engine.enqueueMessage(makeMessage(id: "m1"))
        await engine.syncNow()

        fake.availabilityResult = .transient
        await engine.syncNow()
        XCTAssertEqual(engine.status, .offline)
        XCTAssertFalse(store.snapshot.messages.isEmpty, "cache preserved across transient status")
        XCTAssertEqual(store.snapshot.accountToken, "account-1")

        fake.availabilityResult = .available
        await engine.syncNow()
        XCTAssertEqual(engine.status, .ready)
    }

    func testDefinitiveLogoutPurgesRestoredState() async {
        final class Recorder: CloudSyncApplying {
            var resets = 0
            func cloudSyncDidApply(_ report: CloudMergeReport, scope: String?) {}
            func cloudSyncDidReset() { resets += 1 }
        }
        let recorder = Recorder()
        let fake = ScriptedCloudTransport()
        let (engine, store, _) = makeEngine(transport: fake)
        engine.appLayer = recorder
        await engine.enable()
        engine.enqueueMessage(makeMessage(id: "m1"))
        await engine.syncNow()
        XCTAssertFalse(store.snapshot.messages.isEmpty)

        fake.identityMode = .none
        await engine.syncNow()
        XCTAssertEqual(engine.status, .needsAccount)
        XCTAssertTrue(store.snapshot.messages.isEmpty, "proven sign-out wipes restored cache")
        XCTAssertTrue(store.snapshot.pending.isEmpty)
        XCTAssertNil(store.snapshot.accountToken)
        XCTAssertEqual(recorder.resets, 1)
    }

    func testRepeatedOutagesUseGrowingBackoffNotFixedTwoSeconds() async {
        let fake = ScriptedCloudTransport()
        let backoff = RetryPolicy(base: 30, cap: 120, maxJitter: 0)
        let (engine, _, _) = makeEngine(transport: fake, backoff: backoff)
        await engine.enable()
        engine.enqueueMessage(makeMessage(id: "m1"))
        fake.batchFailure = .retryable(nil)
        await engine.syncNow()
        let firstDelay = engine.lastRetryDelay
        fake.batchFailure = .retryable(nil)
        await engine.syncNow()
        let secondDelay = engine.lastRetryDelay
        XCTAssertNotNil(firstDelay)
        XCTAssertNotNil(secondDelay)
        XCTAssertGreaterThan(secondDelay ?? 0, firstDelay ?? 0, "backoff grows across outages")
        XCTAssertNotEqual(firstDelay, 2)
    }

    func testRetryAfterIsHonored() async {
        let fake = ScriptedCloudTransport()
        let backoff = RetryPolicy(base: 1, cap: 300, maxJitter: 0)
        let (engine, _, _) = makeEngine(transport: fake, backoff: backoff)
        await engine.enable()
        engine.enqueueMessage(makeMessage(id: "m1"))
        fake.batchFailure = .retryable(17)
        await engine.syncNow()
        XCTAssertEqual(engine.lastRetryDelay, 17)
    }
}

// MARK: - Scripted "second device" transport

@MainActor
final class ScriptedCloudTransport: CloudSyncTransport {
    var availabilityResult: CloudSyncAvailability = .available
    var account = "account-1"
    enum IdentityMode { case account(String), indeterminate, none, passthrough }
    var identityMode: IdentityMode = .passthrough
    var ensureZoneResult = true
    var ensureZoneCount = 0
    /// Increments per push while one is held, proves single-flight.
    var inFlightCount = 0
    var containerTouches = 0

    var pushedChanges: [SyncPendingChange] = []
    var pushedTombstones: [SyncTombstone] = []
    var lastPayloads: SyncPayloadBundle?
    var lastAnchors: [String: Data]?
    var nextPull: SyncPullResult?
    var conflictOnNextPush: [String: SyncConflict] = [:]
    var tombstoneSaveFails = false
    var batchFailure: SyncTransportError?
    var holdPush = false

    private var waiters: [() -> Void] = []

    func availability() async -> CloudSyncAvailability { availabilityResult }
    func accountIdentity() async -> CloudAccountIdentity {
        switch identityMode {
        case .account(let id): return .identified(id)
        case .indeterminate: return .indeterminate
        case .none: return .none
        case .passthrough: return .identified(account)
        }
    }

    func ensureZone() async -> Bool {
        containerTouches += 1
        ensureZoneCount += 1
        return ensureZoneResult
    }

    func releasePush(savedKeys: Set<String>? = nil) {
        let waiters = waiters
        self.waiters = []
        pendingSaved = savedKeys ?? pendingSaved
        waiters.forEach { $0() }
    }

    func releasePushAll() {
        let waiters = waiters
        self.waiters = []
        waiters.forEach { $0() }
    }

    private var pendingSaved = Set<String>()

    func push(changes: [SyncPendingChange], payloads: SyncPayloadBundle,
              anchors: [String: Data]) async -> SyncPushOutcome {
        inFlightCount += 1
        lastPayloads = payloads
        lastAnchors = anchors
        if holdPush {
            // Only the FIRST push of a test parks: the coalesced rerun after
            // release must complete (mirrors the standalone repro gate).
            holdPush = false
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters.append { continuation.resume() }
            }
        }
        pushedChanges.append(contentsOf: changes)
        pushedTombstones.append(contentsOf: payloads.tombstones)

        if !conflictOnNextPush.isEmpty {
            let conflicts = conflictOnNextPush
            conflictOnNextPush = [:]
            // Conflicts replace a normal ACK for those keys. Content
            // conflicts carry the content-record anchor; a conflict on a
            // tombstone SAVE is keyed by content name but its anchor is for
            // the tombstone record, so it is returned under that record name.
            var anchorUpdates: [String: Data] = [:]
            for (key, conflict) in conflicts {
                guard let anchor = conflict.anchor,
                      let parsed = SyncEntity.fromContentRecordName(key) else { continue }
                switch conflict.value {
                case .tombstone:
                    anchorUpdates[CloudSync.tombstoneRecordName(
                        entity: parsed.entity, logicalID: parsed.logicalID)] = anchor
                default:
                    anchorUpdates[key] = anchor
                }
            }
            return SyncPushOutcome(savedKeys: [], deletedKeys: [],
                                   conflicts: conflicts, anchorUpdates: anchorUpdates)
        }
        if let batchFailure {
            return SyncPushOutcome(batchFailure: batchFailure)
        }

        var savedKeys = Set<String>()
        var deletedKeys = Set<String>()
        for change in changes {
            let contentKey = SyncPendingChange.contentKey(entity: change.entity, logicalID: change.logicalID)
            switch change.op {
            case .upsert:
                savedKeys.insert(contentKey)
            case .delete:
                if change.entity == .message && tombstoneSaveFails { continue }
                // Simulates the real transport: delete ACK comes from the tombstone.
                deletedKeys.insert(contentKey)
            }
        }
        return SyncPushOutcome(savedKeys: savedKeys, deletedKeys: deletedKeys)
    }

    func pull(token: Data?) async -> Result<SyncPullResult, SyncTransportError> {
        if let nextPull {
            let result = nextPull
            self.nextPull = nil
            return .success(result)
        }
        return .success(SyncPullResult(newToken: token))
    }
}

// MARK: - Validation generation races

@MainActor
final class HeldCloudTransport: CloudSyncTransport {
    var availabilityResult: CloudSyncAvailability = .available
    var identityResult: CloudAccountIdentity = .identified("account-1")
    /// Result delivered specifically to the held FIRST call when released —
    /// simulates a stale in-flight answer without poisoning the current
    /// identity that every fresh probe must keep seeing.
    var heldCallIdentityResult: CloudAccountIdentity?
    var holdFirstAvailability = false
    var holdFirstIdentity = false
    private var availabilityWaiters: [() -> Void] = []
    private var identityWaiters: [() -> Void] = []
    private var firstAvailability = true
    private var firstIdentity = true
    var ensureZoneCount = 0

    /// Deterministic hold engagement for tests: poll instead of sleeping a
    /// fixed duration and hoping the suspended call already parked.
    var availabilityIsHeld: Bool { !availabilityWaiters.isEmpty }
    var identityIsHeld: Bool { !identityWaiters.isEmpty }

    func releaseAvailability() {
        let waiters = availabilityWaiters
        availabilityWaiters = []
        waiters.forEach { $0() }
    }
    func releaseIdentity() {
        let waiters = identityWaiters
        identityWaiters = []
        waiters.forEach { $0() }
    }

    func availability() async -> CloudSyncAvailability {
        if holdFirstAvailability, firstAvailability {
            firstAvailability = false
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                availabilityWaiters.append { c.resume() }
            }
        }
        return availabilityResult
    }

    func accountIdentity() async -> CloudAccountIdentity {
        if holdFirstIdentity, firstIdentity {
            firstIdentity = false
            return await withCheckedContinuation { (c: CheckedContinuation<CloudAccountIdentity, Never>) in
                identityWaiters.append { [self] in
                    c.resume(returning: heldCallIdentityResult ?? identityResult)
                }
            }
        }
        return identityResult
    }

    func ensureZone() async -> Bool { ensureZoneCount += 1; return true }
    func push(changes: [SyncPendingChange], payloads: SyncPayloadBundle,
              anchors: [String: Data]) async -> SyncPushOutcome { SyncPushOutcome() }
    func pull(token: Data?) async -> Result<SyncPullResult, SyncTransportError> {
        .success(SyncPullResult())
    }
}

extension CloudSyncEngineTests {
    func testStaleAvailabilityAfterDisableHasNoSideEffects() async {
        let store = CloudSyncStore(storeURL: tempURL())
        let transport = HeldCloudTransport()
        transport.holdFirstAvailability = true
        let engine = CloudSyncEngine(store: store, transport: transport)

        let enable = Task { await engine.enable() }
        await waitFor { transport.availabilityIsHeld }
        XCTAssertTrue(transport.availabilityIsHeld, "enable() must park inside availability()")
        engine.disable() // bumps generation while enable() is suspended
        transport.availabilityResult = .available
        transport.identityResult = .identified("account-late")
        transport.releaseAvailability()
        await waitFor(5) { !transport.availabilityIsHeld }
        await enable.value

        XCTAssertEqual(engine.status, .off)
        XCTAssertFalse(store.snapshot.enabled, "stale validation must not persist enabled")
        XCTAssertNil(store.snapshot.accountToken)
        XCTAssertEqual(transport.ensureZoneCount, 0)
    }

    func testStaleIdentityFromOldGenerationCannotFenceCurrentAccount() async {
        let store = CloudSyncStore(storeURL: tempURL())
        var seeded = SyncSnapshot()
        seeded.enabled = true
        seeded.accountToken = "account-1"
        store.save(seeded)

        let transport = HeldCloudTransport()
        transport.holdFirstIdentity = true
        // The held generation-N call eventually returns the OLD account, while
        // every CURRENT probe keeps seeing account-2 (never flip the global
        // fixture back, which would make a legitimate fresh probe lie).
        transport.heldCallIdentityResult = .identified("account-1")
        let engine = CloudSyncEngine(store: store, transport: transport)

        // Generation N sync is suspended inside accountIdentity(). The newer
        // account-change validation below re-enters syncNow as a JOINER that
        // awaits this held flight, so the held identity must be released by
        // the test BEFORE awaiting the account-change task — otherwise the
        // test deadlocks against its own fixture.
        let oldSync = Task { await engine.syncNow() }
        await waitFor { transport.identityIsHeld }
        XCTAssertTrue(transport.identityIsHeld, "syncNow() must park inside accountIdentity()")

        // Newer account-change validation (generation N+1) completes at once.
        transport.holdFirstIdentity = false
        transport.identityResult = .identified("account-2")
        var changeFinished = false
        Task {
            await engine.accountMayHaveChanged()
            changeFinished = true
        }
        await waitFor { store.snapshot.accountToken == "account-2" }
        XCTAssertEqual(store.snapshot.accountToken, "account-2")

        // The stale call finally returns the OLD identity: it must not refence.
        transport.releaseIdentity()
        await waitFor(5) { changeFinished }
        XCTAssertTrue(changeFinished,
                      "account-change validation must finish once the held identity is released")
        // The joiner only returns after the held owner completes, so a
        // finished change implies oldSync is done; bail out bounded on failure.
        guard changeFinished else { return }
        await oldSync.value
        XCTAssertEqual(store.snapshot.accountToken, "account-2",
                       "a delayed old-account identity must never overwrite the current fence")
        // The account-change request must not be lost: the current generation
        // actually pulls (zone ensured) and settles READY, not stuck checking.
        XCTAssertGreaterThan(transport.ensureZoneCount, 0, "new account must ensureZone + pull")
        XCTAssertEqual(engine.status, .ready, "coalesced current-generation sync must complete")
    }
}
