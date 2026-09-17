import Foundation
@testable import LimitLifeboat
import LimitLifeboatCore
import XCTest

final class WebDataStoreFactoryTests: XCTestCase {
    private func profile(
        webDataStoreKind: WebDataStoreKind = .isolated,
        webDataStoreID: UUID
    ) -> AccountProfile {
        AccountProfile(
            provider: .claude,
            label: "Account",
            webDataStoreKind: webDataStoreKind,
            webDataStoreID: webDataStoreID
        )
    }

    func testKeepsStoresClaimedByIsolatedProfiles() {
        let kept = UUID()
        XCTAssertEqual(
            WebDataStoreFactory.orphanedDataStoreIdentifiers(
                existing: [kept],
                profiles: [profile(webDataStoreID: kept)]
            ),
            []
        )
    }

    func testCollectsTheStoreOfARemovedProfile() {
        let kept = UUID()
        let removed = UUID()
        XCTAssertEqual(
            WebDataStoreFactory.orphanedDataStoreIdentifiers(
                existing: [kept, removed],
                profiles: [profile(webDataStoreID: kept)]
            ),
            [removed]
        )
    }

    func testCollectsTheStoreOfAProfileUsingTheDefaultStore() {
        // The profile still carries an identifier, but nothing is using the
        // store behind it any more.
        let unused = UUID()
        XCTAssertEqual(
            WebDataStoreFactory.orphanedDataStoreIdentifiers(
                existing: [unused],
                profiles: [profile(webDataStoreKind: .appDefault, webDataStoreID: unused)]
            ),
            [unused]
        )
    }

    func testAProfileCreatedAfterTheFetchStillClaimsItsStore() {
        // The sweep re-reads the profiles per removal precisely so a store
        // created while it was suspended is not deleted out from under a live
        // web view.
        let late = UUID()
        XCTAssertTrue(
            WebDataStoreFactory.isClaimed(late, by: [profile(webDataStoreID: late)])
        )
        XCTAssertFalse(WebDataStoreFactory.isClaimed(late, by: []))
    }

    func testCollectsEveryStoreWhenNoProfilesRemain() {
        let first = UUID()
        let second = UUID()
        XCTAssertEqual(
            WebDataStoreFactory.orphanedDataStoreIdentifiers(
                existing: [first, second],
                profiles: []
            ),
            [first, second]
        )
    }
}
