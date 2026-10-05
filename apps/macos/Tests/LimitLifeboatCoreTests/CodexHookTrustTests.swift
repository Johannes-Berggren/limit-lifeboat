import XCTest
@testable import LimitLifeboatCore

final class CodexHookTrustTests: XCTestCase {
    private func response(_ hooks: [[String: Any]]) -> [String: Any] {
        ["id": 2, "result": ["data": [["cwd": "/Users/me", "hooks": hooks, "warnings": [], "errors": []]]]]
    }

    func testPicksOnlyOurUserPromptSubmitHook() {
        let theirs: [String: Any] = [
            "key": "/u/.codex/hooks.json:user_prompt_submit:0:0", "eventName": "userPromptSubmit",
            "handlerType": "command", "command": "bb-hook.sh", "currentHash": "sha256:aa",
            "trustStatus": "trusted", "enabled": true,
        ]
        let ours: [String: Any] = [
            "key": "/u/.codex/hooks.json:user_prompt_submit:1:0", "eventName": "userPromptSubmit",
            "handlerType": "command", "command": "'/x/limit-lifeboat-memory-guard.sh'", "currentHash": "sha256:bb",
            "trustStatus": "untrusted", "enabled": true,
        ]
        let hook = CodexHookTrust.hook(in: response([theirs, ours]), scriptFileName: MemoryGuardHookScript.fileName)
        XCTAssertEqual(hook?.key, "/u/.codex/hooks.json:user_prompt_submit:1:0")
        XCTAssertEqual(hook?.currentHash, "sha256:bb")
        XCTAssertEqual(hook?.trustStatus, "untrusted")
    }

    func testIgnoresOurScriptUnderOtherEventsAndMissingHooks() {
        let elsewhere: [String: Any] = [
            "key": "k", "eventName": "preToolUse", "handlerType": "command",
            "command": "limit-lifeboat-memory-guard.sh", "currentHash": "h", "trustStatus": "untrusted",
        ]
        XCTAssertNil(CodexHookTrust.hook(in: response([elsewhere]), scriptFileName: MemoryGuardHookScript.fileName))
        XCTAssertNil(CodexHookTrust.hook(in: ["id": 2, "result": ["data": []]], scriptFileName: MemoryGuardHookScript.fileName))
    }

    func testSkipsProjectLevelCopies() {
        let project: [String: Any] = [
            "key": "p", "eventName": "userPromptSubmit", "handlerType": "command", "source": "project",
            "command": "limit-lifeboat-memory-guard.sh", "currentHash": "h", "trustStatus": "untrusted",
        ]
        XCTAssertNil(CodexHookTrust.hook(in: response([project]), scriptFileName: MemoryGuardHookScript.fileName))
    }

    func testManagedPolicyBlocksWriting() {
        XCTAssertFalse(CodexHookTrust.policyBlocks(["id": 4, "result": ["requirements": NSNull()]]))
        XCTAssertFalse(CodexHookTrust.policyBlocks(nil))
        XCTAssertTrue(CodexHookTrust.policyBlocks(["id": 4, "result": ["requirements": ["cliAuthCredentialsStore": "keyring"]]]))
        XCTAssertTrue(CodexHookTrust.policyBlocks(["id": 4, "result": ["requirements": ["allowManagedHooksOnly": true]]]))
        XCTAssertFalse(CodexHookTrust.policyBlocks(["id": 4, "result": ["requirements": ["allowManagedHooksOnly": false]]]))
    }

    func testReapprovesOnlyWhenTheSameHookMoved() {
        let approved = CodexHookTrust.Approval(key: "/u/.codex/hooks.json:user_prompt_submit:1:0", hash: "sha256:ours")
        // Another tool inserted a group ahead of ours: same hook, new key.
        XCTAssertTrue(CodexHookTrust.shouldReapprove(
            current: .init(key: "/u/.codex/hooks.json:user_prompt_submit:2:0", hash: "sha256:ours"),
            lastApproved: approved
        ))
        // Same position, untrusted: the user's decision in Codex.
        XCTAssertFalse(CodexHookTrust.shouldReapprove(current: approved, lastApproved: approved))
        // The hook itself changed (different config): not ours to assume.
        XCTAssertFalse(CodexHookTrust.shouldReapprove(
            current: .init(key: "/u/.codex/hooks.json:user_prompt_submit:2:0", hash: "sha256:other"),
            lastApproved: approved
        ))
        // Never approved by the app: leave it to Codex's own prompt.
        XCTAssertFalse(CodexHookTrust.shouldReapprove(current: approved, lastApproved: nil))
    }

    func testPriorStateMustStillHoldOurApprovalAndNotBeTurnedOff() {
        let approval = CodexHookTrust.Approval(key: "/u/.codex/hooks.json:user_prompt_submit:0:0", hash: "sha256:ours")
        func config(_ state: [String: Any]) -> [String: Any] {
            ["id": 5, "result": ["config": ["hooks": ["state": [approval.key: state]]]]]
        }
        XCTAssertTrue(CodexHookTrust.priorStateConfirms(approval, in: config(["trusted_hash": "sha256:ours"])))
        XCTAssertFalse(CodexHookTrust.priorStateConfirms(approval, in: config(["trusted_hash": "sha256:ours", "enabled": false])))
        XCTAssertFalse(CodexHookTrust.priorStateConfirms(approval, in: config(["trusted_hash": "sha256:other"])))
        XCTAssertFalse(CodexHookTrust.priorStateConfirms(approval, in: ["id": 5, "result": ["config": [:]]]))
        XCTAssertFalse(CodexHookTrust.priorStateConfirms(approval, in: nil))
    }

    /// Talks to the real Codex in ~/.codex. Opt-in only:
    /// LIMIT_LIFEBOAT_CODEX_TRUST_LIVE=1 swift test --filter CodexHookTrustTests
    func testLiveApproveAgainstRealCodex() throws {
        guard ProcessInfo.processInfo.environment["LIMIT_LIFEBOAT_CODEX_TRUST_LIVE"] == "1" else {
            throw XCTSkip("live Codex test is opt-in")
        }
        let codex = try XCTUnwrap(CodexHookTrust.resolveCodexExecutable())
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let outcome = try CodexHookTrust.approve(scriptFileName: MemoryGuardHookScript.fileName, executableURL: codex, codexHome: home)
        XCTAssertEqual(outcome.status, .trusted)
        XCTAssertNotNil(outcome.approval)
    }

    /// End to end in a throwaway CODEX_HOME with the real Codex binary:
    /// approve, let "another tool" insert a group ahead of ours, relaunch.
    /// Opt-in: LIMIT_LIFEBOAT_CODEX_TRUST_LIVE=1
    func testLiveReapprovesAfterAnotherToolShiftsTheHook() throws {
        guard ProcessInfo.processInfo.environment["LIMIT_LIFEBOAT_CODEX_TRUST_LIVE"] == "1" else {
            throw XCTSkip("live Codex test is opt-in")
        }
        let codex = try XCTUnwrap(CodexHookTrust.resolveCodexExecutable())
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ll-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let hooksURL = home.appendingPathComponent("hooks.json")
        let ours: [String: Any] = ["hooks": [["type": "command", "command": "'/x/limit-lifeboat-memory-guard.sh'", "timeout": 5]]]
        try JSONSerialization.data(withJSONObject: ["hooks": ["UserPromptSubmit": [ours]]]).write(to: hooksURL)

        let first = try CodexHookTrust.approve(scriptFileName: MemoryGuardHookScript.fileName, executableURL: codex, codexHome: home)
        XCTAssertEqual(first.status, .trusted)
        let approval = try XCTUnwrap(first.approval)

        let theirs: [String: Any] = ["hooks": [["type": "command", "command": "other-tool.sh"]]]
        try JSONSerialization.data(withJSONObject: ["hooks": ["UserPromptSubmit": [theirs, ours]]]).write(to: hooksURL)
        XCTAssertEqual(
            try CodexHookTrust.status(scriptFileName: MemoryGuardHookScript.fileName, executableURL: codex, codexHome: home),
            .needsApproval,
            "Codex resets trust when the key moves"
        )

        let relaunch = try CodexHookTrust.refresh(
            scriptFileName: MemoryGuardHookScript.fileName,
            executableURL: codex,
            codexHome: home,
            lastApproved: approval
        )
        XCTAssertEqual(relaunch.status, .trusted)
        XCTAssertNotEqual(relaunch.approval?.key, approval.key)

        // Turned off in Codex at the old position, then shifted again: the
        // user's "off" must survive the move.
        let shifted = try XCTUnwrap(relaunch.approval)
        // Codex keeps one table per key; set enabled = false on it in place,
        // as its /hooks "turn off" does.
        var configText = try String(contentsOf: home.appendingPathComponent("config.toml"))
        configText = configText.replacingOccurrences(
            of: "trusted_hash = \"\(shifted.hash)\"",
            with: "trusted_hash = \"\(shifted.hash)\"\nenabled = false"
        )
        try configText.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let third: [String: Any] = ["hooks": [["type": "command", "command": "third-tool.sh"]]]
        try JSONSerialization.data(withJSONObject: ["hooks": ["UserPromptSubmit": [third, theirs, ours]]]).write(to: hooksURL)
        let afterOff = try CodexHookTrust.refresh(
            scriptFileName: MemoryGuardHookScript.fileName,
            executableURL: codex,
            codexHome: home,
            lastApproved: shifted
        )
        XCTAssertEqual(afterOff.status, .needsApproval, "a hook turned off before the shift is not re-approved")
        XCTAssertNil(afterOff.approval)
    }
}
