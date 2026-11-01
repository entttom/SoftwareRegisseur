import Foundation
import SoftwareRegisseurAgents
import SoftwareRegisseurDomain
import SoftwareRegisseurGit
import SoftwareRegisseurJobs
import SoftwareRegisseurPersistence
import Testing

/// ADR-0024 at orchestration level: the project's document folders are exempt from the dirty check of
/// the main working tree, but never overwritten; the collision is shown in the review (German).
@Suite("Integration with uncommitted request/ADR files (ADR-0024)")
struct DocumentPathsIntegrationTests {
    func finishedReview(_ env: TestEnvironment, _ orchestrator: JobOrchestrator, script: @escaping FakeScript) async throws -> (WorkItem, Review) {
        let item = try await env.addWorkItem("Dokumente")
        env.codex.enqueue(script)
        let job = try await env.request(orchestrator, item)
        await orchestrator.tick(now: t0)
        await orchestrator.waitUntilSessionEnds(job.jobId)
        let review = try #require(try await env.database.reviews.reviews(jobId: job.jobId).first)
        try await orchestrator.approveReview(review.reviewId, by: env.user)
        return (item, review)
    }

    @Test func uncommittedRequestFilesDoNotBlockIntegration() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator()
        let (item, review) = try await finishedReview(env, orchestrator, script: Scripts.writeAndCommit(commitWith: env.git))
        // The Mac service wrote a new request and an ADR without committing them (default layout).
        try FileManager.default.createDirectory(at: env.repo.appending(path: "docs/requests/open"), withIntermediateDirectories: true)
        try Data("---\nid: FR-0002\n---\n".utf8).write(to: env.repo.appending(path: "docs/requests/open/FR-0002-neu.md"))
        try FileManager.default.createDirectory(at: env.repo.appending(path: "docs/adr"), withIntermediateDirectories: true)
        try Data("# ADR\n".utf8).write(to: env.repo.appending(path: "docs/adr/0001-x.md"))

        let result = try await orchestrator.integrate(reviewId: review.reviewId, approvedBy: env.user)
        #expect(try await env.output(["rev-parse", "main"]) == result.commitSHA)
        #expect(try await env.item(item.uuid).status == .integrated)
        let status = try await env.git.status(of: env.repo)
        #expect(Set(status.untrackedPaths) == ["docs/requests/open/FR-0002-neu.md", "docs/adr/0001-x.md"])
        #expect(try await env.output(["diff", "--name-only", result.previousDefaultBranchCommit, "main"]) == "feature.txt")
    }

    @Test func collisionIsReportedInReviewAndNothingChanges() async throws {
        let env = try await TestEnvironment()
        let orchestrator = try env.orchestrator()
        let (item, review) = try await finishedReview(env, orchestrator, script: Scripts.writeAndCommit(
            file: "docs/requests/open/FR-0001-dokumente.md", content: "status: done\n", commitWith: env.git))
        try FileManager.default.createDirectory(at: env.repo.appending(path: "docs/requests/open"), withIntermediateDirectories: true)
        try Data("status: review\n".utf8).write(to: env.repo.appending(path: "docs/requests/open/FR-0001-dokumente.md"))
        let mainBefore = try await env.output(["rev-parse", "main"])

        do {
            _ = try await orchestrator.integrate(reviewId: review.reviewId, approvedBy: env.user)
            Issue.record("Expected the integration to be refused")
        } catch let JobOrchestratorError.integrationRefused(text) {
            #expect(text.hasPrefix("Übernahme abgebrochen: 1 nicht committete Request-/ADR-Datei(en)"))
            #expect(text.contains("docs/requests/open/FR-0001-dokumente.md"))
        }
        #expect(try await env.output(["rev-parse", "main"]) == mainBefore)
        #expect(try String(contentsOf: env.repo.appending(path: "docs/requests/open/FR-0001-dokumente.md"), encoding: .utf8)
                == "status: review\n")
        #expect(try await env.item(item.uuid).status == .review)
        let stored = try #require(try await env.database.reviews.fetch(review.reviewId))
        #expect(stored.integrationCommit == nil)
        #expect(stored.conflict?.files == ["docs/requests/open/FR-0001-dokumente.md"])
        #expect(stored.conflict?.message.contains("Bitte zuerst committen oder sichern; nichts wurde übernommen.") == true)
        let details = try #require(await orchestrator.reviewDetails(review.reviewId))
        #expect(details.integrationConflictFiles == ["docs/requests/open/FR-0001-dokumente.md"])
        #expect(details.integrationProblem?.hasPrefix("Übernahme abgebrochen") == true)
        let events = try await env.database.events.events(forWorkItem: item.uuid)
        #expect(events.contains { $0.kind == .conflictDetected && $0.payload["reason"] == "uncommittedDocuments" })

        // Once the user resolved it (here: discarded the uncommitted file), the retry integrates and
        // clears the review conflict.
        try await env.git.run(["clean", "-fdq", "--", "docs"], in: env.repo)
        let result = try await orchestrator.integrate(reviewId: review.reviewId, approvedBy: env.user)
        #expect(try await env.output(["rev-parse", "main"]) == result.commitSHA)
        #expect(try await env.database.reviews.fetch(review.reviewId)?.conflict == nil)
    }

    @Test func nonDocumentChangesStillBlockAndCustomPathsAreUsed() async throws {
        let env = try await TestEnvironment()
        // Service-provided effective layout (custom folder names).
        let orchestrator = try env.orchestrator(documentPaths: { _ in ["architektur", "ideen"] })
        let (_, review) = try await finishedReview(env, orchestrator, script: Scripts.writeAndCommit(commitWith: env.git))
        try FileManager.default.createDirectory(at: env.repo.appending(path: "docs/requests"), withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: env.repo.appending(path: "docs/requests/FR-0003.md"))
        let mainBefore = try await env.output(["rev-parse", "main"])
        // docs/requests is not a document folder of this project → blocks.
        await #expect(throws: JobOrchestratorError.self) {
            _ = try await orchestrator.integrate(reviewId: review.reviewId, approvedBy: env.user)
        }
        #expect(try await env.output(["rev-parse", "main"]) == mainBefore)
        try FileManager.default.removeItem(at: env.repo.appending(path: "docs"))

        try FileManager.default.createDirectory(at: env.repo.appending(path: "ideen/offen"), withIntermediateDirectories: true)
        try Data("x\n".utf8).write(to: env.repo.appending(path: "ideen/offen/FR-0003.md"))
        try Data("Benutzer\n".utf8).write(to: env.repo.appending(path: "README.md"))
        await #expect(throws: JobOrchestratorError.self) {
            _ = try await orchestrator.integrate(reviewId: review.reviewId, approvedBy: env.user)
        }
        #expect(try await env.output(["rev-parse", "main"]) == mainBefore)
        try await env.git.run(["checkout", "--quiet", "--", "README.md"], in: env.repo)
        let result = try await orchestrator.integrate(reviewId: review.reviewId, approvedBy: env.user)
        #expect(try await env.output(["rev-parse", "main"]) == result.commitSHA)
        #expect(FileManager.default.fileExists(atPath: env.repo.appending(path: "ideen/offen/FR-0003.md").path(percentEncoded: false)))
    }

    @Test func documentPathsFromSettings() {
        #expect(JobOrchestrator.documentPaths(settings: ProjectSettings(updatedAt: t0)) == ["docs/adr", "docs/requests"])
        let custom = ProjectSettings(adrPath: "./architektur/adr/", requestsRoot: "aufgaben", updatedAt: t0)
        #expect(JobOrchestrator.documentPaths(settings: custom) == ["architektur/adr", "aufgaben"])
        // Requests at the repository root: only the status folders are exempt, never the whole repository.
        let atRoot = ProjectSettings(adrPath: "adr", requestsRoot: ".", openPath: "offen", activePath: "aktiv",
                                     reviewPath: "pruefen", donePath: "fertig", updatedAt: t0)
        #expect(JobOrchestrator.documentPaths(settings: atRoot) == ["adr", "offen", "aktiv", "pruefen", "fertig"])
    }
}
