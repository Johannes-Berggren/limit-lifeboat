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

    /// Talks to the real Codex in ~/.codex. Opt-in only:
    /// LIMIT_LIFEBOAT_CODEX_TRUST_LIVE=1 swift test --filter CodexHookTrustTests
    func testLiveApproveAgainstRealCodex() throws {
        guard ProcessInfo.processInfo.environment["LIMIT_LIFEBOAT_CODEX_TRUST_LIVE"] == "1" else {
            throw XCTSkip("live Codex test is opt-in")
        }
        let codex = try XCTUnwrap(CodexHookTrust.resolveCodexExecutable())
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let status = try CodexHookTrust.approve(scriptFileName: MemoryGuardHookScript.fileName, executableURL: codex, codexHome: home)
        XCTAssertEqual(status, .trusted)
    }
}
