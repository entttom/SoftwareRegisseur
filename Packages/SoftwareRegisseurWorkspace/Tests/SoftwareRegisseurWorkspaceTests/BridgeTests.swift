import Foundation
import SoftwareRegisseurDomain
import SoftwareRegisseurMarkdown
import Testing
@testable import SoftwareRegisseurWorkspace

@Suite("Markdown ↔ Domain bridge")
struct BridgeTests {
    @Test func statusPriorityTypeRoundTripLosslessly() {
        for status in SoftwareRegisseurDomain.WorkItemStatus.allCases {
            let markdown = MarkdownDomainBridge.markdown(status)
            #expect(markdown.rawValue == status.rawValue)
            #expect(MarkdownDomainBridge.domain(markdown) == status)
        }
        #expect(SoftwareRegisseurMarkdown.WorkItemStatus.allCases.count == SoftwareRegisseurDomain.WorkItemStatus.allCases.count)
        for priority in Priority.allCases {
            #expect(MarkdownDomainBridge.domain(MarkdownDomainBridge.markdown(priority)) == priority)
            #expect(MarkdownDomainBridge.markdown(priority).rawValue == priority.rawValue)
        }
        for type in WorkItemType.allCases {
            let requestType = MarkdownDomainBridge.markdown(type)
            #expect(MarkdownDomainBridge.domain(requestType) == type)
            #expect(requestType.idPrefix.rawValue == type.humanIDPrefix)
        }
    }

    @Test func humanIDsRoundTripAndRejectZero() throws {
        for type in WorkItemType.allCases {
            for number in [1, 7, 9999, 12345] {
                let id = try SoftwareRegisseurDomain.HumanID(type: type, number: number)
                let markdown = MarkdownDomainBridge.markdown(id)
                #expect(markdown.description == id.formatted)
                #expect(try MarkdownDomainBridge.domain(markdown) == id)
            }
        }
        // Imported short form keeps the number; canonical form on output.
        let parsedShort: MarkdownHumanID? = MarkdownHumanID("FR-7")
        let short = try #require(parsedShort)
        #expect(try MarkdownDomainBridge.domain(short).formatted == "FR-0007")
        #expect(throws: BridgeError.self) { try MarkdownDomainBridge.domain(MarkdownHumanID(prefix: .bug, number: 0)) }
    }

    @Test func adrStatusMapping() {
        for status in SoftwareRegisseurDomain.ADRStatus.allCases {
            #expect(MarkdownDomainBridge.domain(MarkdownDomainBridge.markdown(status)) == status)
        }
        #expect(MarkdownDomainBridge.domain(SoftwareRegisseurMarkdown.ADRStatus.rejected) == .deprecated)
    }

    @Test func folderLayoutFromSettingsSupportsCustomGermanFolders() throws {
        let settings = ProjectSettings(adrPath: "architektur/entscheidungen", requestsRoot: "ideen", openPath: "offen",
                                       activePath: "in-arbeit", reviewPath: "pruefung", donePath: "erledigt", updatedAt: .now)
        let layout = try MarkdownDomainBridge.folderLayout(settings)
        #expect(layout.folder(for: .open)?.string == "ideen/offen")
        #expect(layout.folder(for: .queued)?.string == "ideen/offen")
        #expect(layout.folder(for: .waitingApproval)?.string == "ideen/in-arbeit")
        #expect(layout.folder(for: .implementationFinished)?.string == "ideen/pruefung")
        #expect(layout.folder(for: .integrated)?.string == "ideen/erledigt")
        #expect(layout.folder(for: .blocked) == nil)
        #expect(layout.adrPath.string == "architektur/entscheidungen")
        let defaults = try MarkdownDomainBridge.folderLayout(ProjectSettings(updatedAt: .now))
        #expect(defaults == FolderLayout.default)

        let bad = ProjectSettings(requestsRoot: "../aussen", updatedAt: .now)
        #expect(throws: BridgeError.self) { try MarkdownDomainBridge.folderLayout(bad) }
    }

    /// ADR-0024: document folders exempt from the integration dirty check (never the whole repository).
    @Test func documentPathsOfEffectiveLayout() throws {
        #expect(WorkspaceEnvironment.documentPaths(.default) == ["docs/adr", "docs/requests"])
        let custom = ProjectSettings(adrPath: "architektur/entscheidungen", requestsRoot: "ideen", updatedAt: .now)
        #expect(WorkspaceEnvironment.documentPaths(try MarkdownDomainBridge.folderLayout(custom)) == ["architektur/entscheidungen", "ideen"])
        let atRoot = ProjectSettings(adrPath: "adr", requestsRoot: ".", openPath: "offen", activePath: "aktiv",
                                     reviewPath: "pruefen", donePath: "fertig", updatedAt: .now)
        #expect(WorkspaceEnvironment.documentPaths(try MarkdownDomainBridge.folderLayout(atRoot))
                == ["adr", "offen", "aktiv", "pruefen", "fertig"])
    }
}
