import Foundation
import Testing
@testable import SoftwareRegisseurDomain

@Suite("Human IDs and ADR numbers (ADR-0018)")
struct HumanIDTests {
    @Test func parsesCanonicalFeatureID() throws {
        let id = try HumanID(parsing: "FR-0007")
        #expect(id.type == .feature)
        #expect(id.number == 7)
        #expect(id.formatted == "FR-0007")
        #expect(id.description == "FR-0007")
    }

    @Test(arguments: [
        ("FR-0001", WorkItemType.feature, 1),
        ("BUG-0042", .bug, 42),
        ("TODO-0100", .todo, 100),
        ("IMP-9999", .improvement, 9999),
        ("NOTE-0003", .note, 3),
        ("FR-10000", .feature, 10000),
        ("BUG-123456", .bug, 123_456),
    ])
    func roundTripsAllPrefixes(text: String, type: WorkItemType, number: Int) throws {
        let id = try HumanID(parsing: text)
        #expect(id.type == type)
        #expect(id.number == number)
        #expect(id.formatted == text)
        #expect(try HumanID(type: type, number: number).formatted == text)
    }

    @Test func formatsWithZeroPadding() throws {
        #expect(try HumanID(type: .improvement, number: 5).formatted == "IMP-0005")
        #expect(try HumanID(type: .note, number: 12345).formatted == "NOTE-12345")
    }

    @Test(arguments: [
        ("", HumanIDError.empty),
        ("FR0007", .missingSeparator("FR0007")),
        ("XX-0001", .unknownPrefix("XX")),
        ("fr-0001", .unknownPrefix("fr")),
        (" FR-0001", .unknownPrefix(" FR")),
        ("ADR-0001", .unknownPrefix("ADR")),
        ("FR-", .invalidDigits("")),
        ("FR-00a1", .invalidDigits("00a1")),
        ("FR--001", .invalidDigits("-001")),
        ("FR-+001", .invalidDigits("+001")),
        ("FR-0001 ", .invalidDigits("0001 ")),
        ("FR-007", .nonCanonicalPadding("007")),
        ("FR-00007", .nonCanonicalPadding("00007")),
        ("FR-0000", .numberOutOfRange(0)),
        ("FR-99999999999999999999", .invalidDigits("99999999999999999999")),
    ])
    func rejectsInvalidInput(text: String, expected: HumanIDError) {
        #expect(throws: expected) { try HumanID(parsing: text) }
        #expect(HumanID(text) == nil)
    }

    @Test func rejectsNonPositiveNumbers() {
        #expect(throws: HumanIDError.numberOutOfRange(0)) { try HumanID(type: .bug, number: 0) }
        #expect(throws: HumanIDError.numberOutOfRange(-3)) { try HumanID(type: .bug, number: -3) }
    }

    @Test func codableAsPlainString() throws {
        let id = try HumanID(parsing: "BUG-0042")
        #expect(try jsonString([id]) == #"["BUG-0042"]"#)
        #expect(try roundTrip(id) == id)
        let bad = Data(#"["BUG-42"]"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode([HumanID].self, from: bad) }
    }

    @Test func nextIDUsesSeparateRangePerPrefixAndNeverReuses() throws {
        let existing = try ["FR-0003", "FR-0001", "BUG-0010", "TODO-0002"].map { try HumanID(parsing: $0) }
        #expect(HumanID.next(for: .feature, existing: existing).formatted == "FR-0004")
        #expect(HumanID.next(for: .bug, existing: existing).formatted == "BUG-0011")
        #expect(HumanID.next(for: .improvement, existing: existing).formatted == "IMP-0001")
        // Gap from a deleted FR-0002 is not refilled.
        #expect(HumanID.next(for: .feature, existing: existing).number == 4)
    }

    @Test func workItemAcceptsHumanIDOnceAndOnlyMatchingType() throws {
        var item = WorkItem(type: .bug, title: "Crash", createdAt: referenceDate)
        #expect(item.humanId == nil)
        #expect(throws: WorkItemError.humanIDTypeMismatch(expected: .bug, found: .feature)) {
            try item.assignHumanID(HumanID(parsing: "FR-0001"), at: referenceDate)
        }
        let bug = try HumanID(parsing: "BUG-0002")
        try item.assignHumanID(bug, at: referenceDate)
        #expect(item.humanId == bug)
        #expect(item.revision == 2)
        #expect(throws: WorkItemError.humanIDAlreadyAssigned(bug)) {
            try item.assignHumanID(HumanID(parsing: "BUG-0003"), at: referenceDate)
        }
    }

    @Test func adrNumbers() throws {
        let six = try ADRNumber(parsing: "0006")
        #expect(six.value == 6)
        #expect(six.formatted == "0006")
        #expect(six.displayID == "ADR-0006")
        #expect(try ADRNumber(parsing: "ADR-0012").value == 12)
        #expect(try ADRNumber(parsing: "12345").formatted == "12345")
        #expect(try ADRNumber(parsing: "0000").value == 0)
        #expect(throws: HumanIDError.nonCanonicalPadding("6")) { try ADRNumber(parsing: "6") }
        #expect(throws: HumanIDError.invalidDigits("FR-0006")) { try ADRNumber(parsing: "FR-0006") }
        #expect(ADRNumber.next(after: [six, try ADRNumber(18)]).formatted == "0019")
        #expect(try roundTrip(six) == six)
    }
}

@Suite("Typed and open identifiers")
struct OpenIdentifierTests {
    @Test func typedIdentifierEncodesAsPlainUUID() throws {
        let uuid = UUID(uuidString: "6F1A2B3C-0000-4000-8000-000000000001")!
        let id = ProjectID(uuid)
        #expect(try jsonString([id]) == #"["6F1A2B3C-0000-4000-8000-000000000001"]"#)
        #expect(try roundTrip(id) == id)
        #expect(id.shortString == "6f1a2b3c")
        #expect(ProjectID(uuidString: "nope") == nil)
    }

    @Test func providerModelAndEffortAreLossless() throws {
        let provider: ProviderID = "cursor-agent"
        let model: ModelID = "Some Model/2027 · preview"
        let effort: EffortLevel = "ultrathink"
        #expect(try roundTrip(provider) == provider)
        #expect(try roundTrip(model).rawValue == "Some Model/2027 · preview")
        #expect(try roundTrip(effort) == effort)
        #expect(ProviderID.codex.rawValue == "codex")
        #expect(ProviderID.claudeCode.rawValue == "claude-code")
    }

    @Test func emptyOpenIdentifiersAreRejected() {
        #expect(ProviderID(rawValue: "") == nil)
        #expect(ModelID(rawValue: "   ") == nil)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode([EffortLevel].self, from: Data(#"[""]"#.utf8))
        }
    }

    @Test func providerKeyedDictionaryEncodesAsObject() throws {
        let dict: [ProviderID: Int] = [.codex: 1]
        #expect(try jsonString(dict) == #"{"codex":1}"#)
        #expect(try roundTrip(dict) == dict)
    }

    @Test(arguments: [
        (EffortLevel.auto, "Automatisch"),
        (.low, "Niedrig"),
        (.medium, "Mittel"),
        (.high, "Hoch"),
        (.xhigh, "Extra hoch"),
        (.max, "Maximum"),
        ("minimal", "minimal"),
    ])
    func effortGermanDisplayNames(effort: EffortLevel, expected: String) {
        #expect(effort.germanDisplayName == expected)
    }

    @Test func effortKnownLevels() {
        #expect(EffortLevel.knownLevels.map(\.rawValue) == ["auto", "low", "medium", "high", "xhigh", "max"])
        #expect(EffortLevel(rawValue: "minimal")?.isKnown == false)
        #expect(EffortLevel.xhigh.isKnown)
    }
}

@Suite("Entity invariants")
struct EntityTests {
    @Test func providerProfileContainsNoSecretFields() throws {
        let profile = ProviderProfile(
            providerId: .openAI,
            purpose: .transcription,
            model: "gpt-4o-transcribe",
            keychainReference: KeychainReference(service: "SoftwareRegisseur.AI", account: "openai"),
            settings: ["language": "de"]
        )
        let json = try jsonString(profile).lowercased()
        #expect(!json.contains("apikey"))
        #expect(!json.contains("secret"))
        #expect(!json.contains("token"))
        #expect(try roundTrip(profile) == profile)
    }

    @Test func reviewIntegrationRequiresApprovalAndCommit() throws {
        var review = Review(jobId: JobID(), diffSummary: DiffSummary(filesChanged: 1, insertions: 3, deletions: 1))
        #expect(throws: ReviewError.notApproved(.pending)) { try review.recordIntegration(commit: "abc123", strategy: .squash) }
        review.decide(.approved, at: referenceDate)
        #expect(review.approvedAt == referenceDate)
        #expect(throws: ReviewError.emptyCommitHash) { try review.recordIntegration(commit: " ", strategy: .squash) }
        try review.recordIntegration(commit: "abc123", strategy: .squash)
        #expect(review.integrationCommit == "abc123")
        #expect(throws: ReviewError.alreadyIntegrated("abc123")) { try review.recordIntegration(commit: "def", strategy: .squash) }
    }

    @Test func projectSettingsDefaults() throws {
        let settings = ProjectSettings(updatedAt: referenceDate)
        #expect(settings.integrationStrategy == .squash)
        #expect(settings.adrPath == "docs/adr")
        #expect(settings.requestsRoot == "docs/requests")
        #expect(settings.activePath == "in-progress")
        #expect(IntegrationStrategy.allCases.map(\.rawValue) == ["squash", "mergeCommit", "cherryPick"])
        #expect(try roundTrip(settings) == settings)
    }

    @Test func branchNameFollowsConvention() throws {
        let job = Fixtures.job(snapshot: try Fixtures.resolvedSnapshot())
        let name = job.suggestedBranchName(humanId: try HumanID(parsing: "FR-0012"))
        #expect(name == "software-regisseur/FR-0012/\(job.jobId.shortString)")
        #expect(job.suggestedBranchName(humanId: nil).hasPrefix("software-regisseur/\(job.workItemId.shortString)/"))
    }
}
