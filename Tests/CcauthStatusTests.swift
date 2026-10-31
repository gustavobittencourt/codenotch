import XCTest
@testable import Codenotch

/// A amostra real do `ccauth status --json` (schema 2), sem dados pessoais:
/// as mesmas 5 contas que o plano descreve.
enum CcauthFixture {
    static let statusJSON = #"""
{
 "schema": 2,
 "ok": true,
 "generated_at": "2026-10-31T05:31:19Z",
 "warnings": [],
 "claude": {
  "ok": true,
  "active": "Gustavo",
  "live_matches_active": true,
  "accounts": [
   {
    "alias": "Allan",
    "email": "allan@example.com",
    "email_confirmed": false,
    "active": false,
    "in_use": false,
    "login_expires_at": "2026-10-27T23:56:17Z",
    "versions": 3,
    "quota": {
     "session": {
      "used_percent": 0.0,
      "resets_at": null
     },
     "week": {
      "used_percent": 17.0,
      "resets_at": "2026-11-01T14:00:00Z"
     },
     "fable": {
      "used_percent": 2.0,
      "resets_at": "2026-11-01T14:00:00Z"
     },
     "fetched_at": "2026-10-28T04:48:05Z",
     "stale": true,
     "stale_reason": "refresh falhou — `ccauth claude login` de novo"
    }
   },
   {
    "alias": "Gustavo",
    "email": "gustavo@example.com",
    "email_confirmed": true,
    "active": true,
    "in_use": true,
    "login_expires_at": "2026-11-25T04:05:18Z",
    "versions": 1,
    "quota": {
     "session": {
      "used_percent": 7.0,
      "resets_at": "2026-10-31T09:59:59Z"
     },
     "week": {
      "used_percent": 68.0,
      "resets_at": "2026-11-02T23:59:59Z"
     },
     "fable": {
      "used_percent": 3.0,
      "resets_at": "2026-11-02T23:59:59Z"
     },
     "fetched_at": "2026-10-31T05:29:05Z",
     "stale": false
    }
   }
  ]
 },
 "opencode": {
  "ok": true,
  "available": true,
  "unavailable_reason": null,
  "active": "Personal",
  "accounts": [
   {
    "alias": "Personal",
    "credential_id": "cred_personal",
    "kind": "oauth",
    "email": "personal@example.com",
    "workspace": "Personal",
    "active": true,
    "login_expires_at": "2026-11-28T06:12:43Z",
    "key_invalid": false,
    "quota": {
     "rolling": {
      "used_percent": 0.0,
      "resets_at": "2026-10-31T09:57:12Z",
      "exhausted": false
     },
     "weekly": {
      "used_percent": 43.0,
      "resets_at": "2026-11-02T00:00:00Z",
      "exhausted": false
     },
     "monthly": {
      "used_percent": 21.0,
      "resets_at": "2026-11-29T06:04:38Z",
      "exhausted": false
     },
     "fetched_at": "2026-10-31T05:29:05Z",
     "stale": false,
     "stale_reason": null
    }
   },
   {
    "alias": "Default",
    "credential_id": "cred_default",
    "kind": "oauth",
    "email": "default@example.com",
    "workspace": "Default",
    "active": false,
    "login_expires_at": "2026-11-20T15:40:40Z",
    "key_invalid": false,
    "quota": {
     "rolling": {
      "used_percent": 0.0,
      "resets_at": "2026-10-31T10:29:06Z",
      "exhausted": false
     },
     "weekly": {
      "used_percent": 0.0,
      "resets_at": "2026-11-02T00:00:00Z",
      "exhausted": false
     },
     "monthly": {
      "used_percent": 100.0,
      "resets_at": "2026-11-09T01:01:20Z",
      "exhausted": true
     },
     "fetched_at": "2026-10-31T05:29:05Z",
     "stale": false,
     "stale_reason": null
    }
   },
   {
    "alias": "API key",
    "credential_id": "cred_apikey",
    "kind": "key",
    "email": null,
    "workspace": null,
    "active": false,
    "login_expires_at": null,
    "key_invalid": true,
    "quota": {
     "rolling": null,
     "weekly": null,
     "monthly": null,
     "fetched_at": null,
     "stale": true,
     "stale_reason": "opencode.ai respondeu HTTP 401"
    }
   }
  ]
 }
}
"""#

    static var statusData: Data { Data(statusJSON.utf8) }

    static func status() throws -> CcauthStatus {
        try CcauthStatus.decode(statusData)
    }

    static func claude(_ alias: String) throws -> CcauthClaudeAccount {
        try XCTUnwrap(status().claude?.accounts?.first { $0.alias == alias })
    }

    static func opencode(_ alias: String) throws -> CcauthOpenCodeAccount {
        try XCTUnwrap(status().opencode?.accounts?.first { $0.alias == alias })
    }
}

final class CcauthStatusTests: XCTestCase {
    private func date(_ text: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: text))
    }

    // MARK: - Decoding

    func testDecodesTheSchema2Sample() throws {
        let status = try CcauthFixture.status()
        XCTAssertEqual(status.schema, 2)
        XCTAssertEqual(status.claude?.active, "Gustavo")
        XCTAssertEqual(status.claude?.accounts?.map(\.alias), ["Allan", "Gustavo"])
        XCTAssertEqual(status.opencode?.active, "Personal")
        XCTAssertEqual(status.opencode?.accounts?.map(\.alias), ["Personal", "Default", "API key"])
        XCTAssertEqual(try CcauthFixture.claude("Allan").email, "allan@example.com")
        XCTAssertEqual(try CcauthFixture.claude("Gustavo").quota?.fetchedAt, try date("2026-10-31T05:29:05Z"))
        XCTAssertEqual(try CcauthFixture.opencode("Default").quota?.monthly?.exhausted, true)
    }

    func testDecodesStatusWithoutQuotaAsProducedByNoUsage() throws {
        let json = #"""
        {"schema":2,"ok":true,"claude":{"ok":true,"active":"A","accounts":[{"alias":"A","email":"a@example.com","active":true}]},
         "opencode":{"ok":true,"available":false,"unavailable_reason":"sem opencode","accounts":[]}}
        """#
        let status = try CcauthStatus.decode(Data(json.utf8))
        XCTAssertNil(status.claude?.accounts?.first?.quota)
        XCTAssertEqual(status.opencode?.unavailableReason, "sem opencode")
    }

    func testDecodesFractionalSecondDates() throws {
        let json = #"{"schema":2,"ok":true,"generated_at":"2026-10-31T05:31:19.250Z"}"#
        let status = try CcauthStatus.decode(Data(json.utf8))
        XCTAssertEqual(try XCTUnwrap(status.generatedAt).timeIntervalSince1970,
                       try date("2026-10-31T05:31:19Z").timeIntervalSince1970 + 0.25, accuracy: 0.001)
    }

    // MARK: - Claude windows

    func testClaudeWindowsKeepNativeIDsLabelsAndDurations() throws {
        let snapshot = try CcauthFixture.claude("Gustavo").snapshot(providerID: "ccauth-claude-gustavo")
        XCTAssertEqual(snapshot.windows.map(\.id), ["session", "weekly_all", "weekly_fable"])
        XCTAssertEqual(snapshot.windows.map(\.label), [L10n.t("Current session"), L10n.t("All models"), "Fable"])
        XCTAssertEqual(snapshot.windows.map(\.usedFraction), [0.07, 0.68, 0.03])
        XCTAssertEqual(snapshot.windows.map(\.duration), [5 * 3600, 7 * 86400, 7 * 86400])
        XCTAssertEqual(snapshot.windows[0].resetsAt, try date("2026-10-31T09:59:59Z"))
        XCTAssertEqual(snapshot.headlineID, "session")
        XCTAssertEqual(snapshot.weeklyID, "weekly_all")
        XCTAssertEqual(snapshot.glyph, .claude)
        XCTAssertEqual(snapshot.fidelity, .official)
        XCTAssertEqual(snapshot.status, .ok)
    }

    func testClaudeWindowWithNullResetStaysWithoutResetDate() throws {
        let snapshot = try CcauthFixture.claude("Allan").snapshot(providerID: "ccauth-claude-allan")
        let session = try XCTUnwrap(snapshot.windows.first { $0.id == "session" })
        XCTAssertEqual(session.usedFraction, 0)
        XCTAssertNil(session.resetsAt)
    }

    func testClaudeStaleQuotaBecomesStaleSinceFetchTime() throws {
        let snapshot = try CcauthFixture.claude("Allan").snapshot(providerID: "ccauth-claude-allan")
        XCTAssertEqual(snapshot.status, .stale(since: try date("2026-10-28T04:48:05Z")))
        XCTAssertEqual(snapshot.windows.count, 3)
    }

    func testNullOrPercentlessWindowIsOmitted() throws {
        let json = #"""
        {"alias":"A","active":false,"quota":{"session":{"used_percent":10,"resets_at":null},
         "week":{"resets_at":"2026-11-01T14:00:00Z"},"fable":null,"fetched_at":"2026-10-31T05:29:05Z","stale":false}}
        """#
        let account = try CcauthStatus.makeDecoder().decode(CcauthClaudeAccount.self, from: Data(json.utf8))
        let snapshot = try account.snapshot(providerID: "ccauth-claude-a")
        XCTAssertEqual(snapshot.windows.map(\.id), ["session"])
    }

    func testClaudeAccountWithoutAnyWindowThrowsBadResponse() throws {
        let account = CcauthClaudeAccount(alias: "A", email: nil, active: false, quota: nil)
        XCTAssertThrowsError(try account.snapshot(providerID: "ccauth-claude-a")) { error in
            guard case UsageProviderError.badResponse(let status) = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
            XCTAssertEqual(status, 0)
        }
    }

    // MARK: - OpenCode windows

    func testOpenCodeWindowsKeepNativeIDsLabelsAndDurations() throws {
        let snapshot = try CcauthFixture.opencode("Personal").snapshot(providerID: "ccauth-opencode-personal")
        XCTAssertEqual(snapshot.windows.map(\.id), ["rolling", "weekly", "monthly"])
        XCTAssertEqual(snapshot.windows.map(\.label),
                       [L10n.t("5h limit"), L10n.t("Weekly limit"), L10n.t("Monthly limit")])
        XCTAssertEqual(snapshot.windows.map(\.usedFraction), [0, 0.43, 0.21])
        XCTAssertEqual(snapshot.windows.map(\.duration), [5 * 3600, 7 * 86400, nil])
        XCTAssertEqual(snapshot.headlineID, "rolling")
        XCTAssertEqual(snapshot.weeklyID, "weekly")
        XCTAssertEqual(snapshot.glyph, .opencode)
        XCTAssertEqual(snapshot.fidelity, .official)
        XCTAssertEqual(snapshot.status, .ok)
    }

    func testOpenCodeDefaultHasMonthlyWindowSpent() throws {
        let snapshot = try CcauthFixture.opencode("Default").snapshot(providerID: "ccauth-opencode-default")
        let monthly = try XCTUnwrap(snapshot.windows.first { $0.id == "monthly" })
        XCTAssertEqual(monthly.usedFraction, 1.0)
        XCTAssertEqual(monthly.resetsAt, try date("2026-11-09T01:01:20Z"))
    }

    func testOpenCodeInvalidKeyWithoutWindowsNeedsAuth() throws {
        let account = try CcauthFixture.opencode("API key")
        XCTAssertThrowsError(try account.snapshot(providerID: "ccauth-opencode-api-key")) { error in
            guard case UsageProviderError.needsAuth = error else {
                return XCTFail("expected needsAuth, got \(error)")
            }
        }
    }

    func testOpenCodeWithoutWindowsAndValidKeyThrowsBadResponse() throws {
        let account = CcauthOpenCodeAccount(alias: "X", email: nil, active: false, keyInvalid: false, quota: nil)
        XCTAssertThrowsError(try account.snapshot(providerID: "ccauth-opencode-x")) { error in
            guard case UsageProviderError.badResponse = error else {
                return XCTFail("expected badResponse, got \(error)")
            }
        }
    }

    func testOpenCodeStaleQuotaBecomesStaleSinceFetchTime() throws {
        let json = #"""
        {"alias":"S","active":false,"quota":{"rolling":{"used_percent":5,"resets_at":null,"exhausted":false},
         "fetched_at":"2026-10-30T10:00:00Z","stale":true,"stale_reason":"x"}}
        """#
        let account = try CcauthStatus.makeDecoder().decode(CcauthOpenCodeAccount.self, from: Data(json.utf8))
        XCTAssertEqual(try account.snapshot(providerID: "ccauth-opencode-s").status,
                       .stale(since: try date("2026-10-30T10:00:00Z")))
    }

    // MARK: - Plan (the tooltip says which account is active, not only the colour)

    func testPlanSaysWhichAccountIsActive() throws {
        XCTAssertEqual(try CcauthFixture.claude("Gustavo").snapshot(providerID: "g").plan, "Ativa")
        XCTAssertNil(try CcauthFixture.claude("Allan").snapshot(providerID: "a").plan)
        XCTAssertEqual(try CcauthFixture.opencode("Personal").snapshot(providerID: "p").plan, "Go · Ativa")
        XCTAssertEqual(try CcauthFixture.opencode("Default").snapshot(providerID: "d").plan, "Go")
    }

    // MARK: - Ids

    func testProviderIDUsesLowercaseSlugOfTheAlias() {
        XCTAssertEqual(CcauthAccountProvider.providerID(family: .claude, alias: "Gustavo"), "ccauth-claude-gustavo")
        XCTAssertEqual(CcauthAccountProvider.providerID(family: .opencode, alias: "API key"), "ccauth-opencode-api-key")
        XCTAssertEqual(CcauthAccountProvider.providerID(family: .claude, alias: "  Work / Ana_2 "), "ccauth-claude-work-ana-2")
    }
}
