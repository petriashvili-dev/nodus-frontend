import Foundation
import Testing
@testable import nodus

struct AIAccessTests {
    @Test func missingFeaturesFieldMeansNoFeatures() {
        let access = AIAccess(featureKeys: nil, consentAt: nil)

        #expect(access.features.isEmpty)
        #expect(!access.hasAnyFeature)
    }

    @Test func unknownFeatureKeysAreIgnored() {
        let access = AIAccess(featureKeys: ["ai_drafts", "ai_future_thing"], consentAt: nil)

        #expect(access.features == [.drafts])
    }

    @Test(arguments: AIFeature.allCases)
    func eachServerKeyMapsToItsFeature(_ feature: AIFeature) {
        let access = AIAccess(featureKeys: [feature.rawValue], consentAt: nil)

        #expect(access.isAvailable(feature))
        #expect(AIFeature.allCases.filter(access.isAvailable) == [feature])
    }

    @Test func consentComesOnlyFromTheServerTimestamp() {
        let consentAt = Date(timeIntervalSince1970: 1_792_000_000)

        #expect(AIAccess(featureKeys: ["ai_drafts"], consentAt: consentAt).hasConsent)
        #expect(!AIAccess(featureKeys: ["ai_drafts"], consentAt: nil).hasConsent)
    }
}

@MainActor
struct AIAccessStoreTests {
    private let defaults: UserDefaults

    init() throws {
        let suiteName = "AIAccessStoreTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    @Test func startsEmptyWhenNothingWasReported() {
        let store = AIAccessStore(defaults: defaults)

        #expect(store.access == .none)
    }

    @Test func appliedAccessIsVisibleToTheSiriIntentRead() {
        let consentAt = Date(timeIntervalSince1970: 1_792_000_000)
        let store = AIAccessStore(defaults: defaults)

        store.apply(AIAccess(features: [.drafts, .fileImport], consentAt: consentAt))

        let loaded = AIAccessStore.load(from: defaults)
        #expect(loaded.features == [.drafts, .fileImport])
        #expect(loaded.consentAt == consentAt)
        #expect(AIAccessStore(defaults: defaults).access == loaded)
    }

    @Test func revokingHidesTheFeatureImmediately() {
        let store = AIAccessStore(defaults: defaults)
        store.apply(AIAccess(features: [.drafts], consentAt: nil))

        store.apply(.none)

        #expect(!store.access.isAvailable(.drafts))
        #expect(AIAccessStore.load(from: defaults) == .none)
    }
}
