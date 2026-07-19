import XCTest
@testable import LimitLifeboatCore

final class ApplicationCodeSignatureTests: XCTestCase {
    func testAdHocSignatureNeverClaimsDurability() {
        let status = ApplicationCodeSignatureInspector.classify(
            signatureFlags: 0x0002,
            teamIdentifier: "3DQ7YC2YH2",
            leafSubject: "Apple Development: Example"
        )

        XCTAssertEqual(status, .adHoc)
        XCTAssertFalse(status.supportsDurableAuthorization(for: .development))
        XCTAssertFalse(status.supportsDurableAuthorization(for: .distribution))
    }

    func testDevelopmentRequiresAppleDevelopmentIdentity() {
        let development = ApplicationCodeSignatureInspector.classify(
            signatureFlags: 0,
            teamIdentifier: "3DQ7YC2YH2",
            leafSubject: "Apple Development: Example"
        )
        let developerID = ApplicationCodeSignatureInspector.classify(
            signatureFlags: 0,
            teamIdentifier: "3DQ7YC2YH2",
            leafSubject: "Developer ID Application: Example"
        )

        XCTAssertTrue(development.supportsDurableAuthorization(for: .development))
        XCTAssertFalse(developerID.supportsDurableAuthorization(for: .development))
        XCTAssertTrue(developerID.supportsDurableAuthorization(for: .distribution))
    }

    func testUnknownOrMissingSignerIsUnsupported() {
        XCTAssertEqual(
            ApplicationCodeSignatureInspector.classify(
                signatureFlags: 0,
                teamIdentifier: nil,
                leafSubject: nil
            ),
            .unsupported
        )
    }
}
