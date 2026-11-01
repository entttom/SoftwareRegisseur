import Foundation
import Testing
@testable import SoftwareRegisseurDomain

/// Expected tables are written out independently of the production tables (ADR-0012 verification).
private func table<S: StateMachineState & RawRepresentable>(_ raw: [String: [String]], as _: S.Type) -> [S: Set<S>] where S.RawValue == String {
    var result: [S: Set<S>] = [:]
    for (from, targets) in raw {
        result[S(rawValue: from)!] = Set(targets.map { S(rawValue: $0)! })
    }
    return result
}

private func verifyAllPairs<S: StateMachineState>(_ expected: [S: Set<S>]) {
    #expect(Set(expected.keys) == Set(S.allCases), "Expected table must list every state")
    for from in S.allCases {
        for to in S.allCases {
            let allowed = expected[from]?.contains(to) ?? false
            #expect(from.canTransition(to: to) == allowed, "\(from) → \(to) expected \(allowed ? "allowed" : "forbidden")")
            var state = from
            if allowed {
                #expect(throws: Never.self) { try state.transition(to: to) }
                #expect(state == to)
            } else {
                #expect(throws: InvalidStateTransition(from: from, to: to)) { try state.transition(to: to) }
                #expect(state == from)
            }
        }
    }
}

@Suite("ProjectStatus state machine")
struct ProjectStatusTests {
    static let expected = table([
        "pendingMacSetup": ["ready", "unavailable", "needsAttention", "archived"],
        "ready": ["unavailable", "needsAttention", "archived"],
        "unavailable": ["ready", "needsAttention", "archived"],
        "needsAttention": ["ready", "unavailable", "archived"],
        "archived": ["pendingMacSetup", "ready", "unavailable", "needsAttention"],
    ], as: ProjectStatus.self)

    @Test func allAllowedAndForbiddenTransitions() {
        verifyAllPairs(Self.expected)
    }

    @Test func rawValuesMatchSpecE2() {
        #expect(ProjectStatus.allCases.map(\.rawValue) == ["pendingMacSetup", "ready", "unavailable", "needsAttention", "archived"])
    }

    @Test func projectTransitionBumpsRevision() throws {
        var project = Project(name: "Demo", repositoryKind: .gitRepository, settingsId: ProjectSettingsID(), createdAt: referenceDate)
        try project.transition(to: .ready, at: referenceDate.addingTimeInterval(1))
        #expect(project.status == .ready)
        #expect(project.revision == 2)
        #expect(throws: InvalidStateTransition(from: ProjectStatus.ready, to: .pendingMacSetup)) {
            try project.transition(to: .pendingMacSetup, at: referenceDate)
        }
    }
}

@Suite("WorkItemStatus state machine")
struct WorkItemStatusTests {
    static let expected = table([
        "inbox": ["queued", "scheduled", "in_progress", "blocked", "open", "paused", "cancelled", "done"],
        "open": ["queued", "scheduled", "in_progress", "blocked", "inbox", "paused", "cancelled", "done"],
        "queued": ["inbox", "open", "blocked", "failed", "paused", "implementation_finished", "review",
                   "scheduled", "in_progress", "cancelled"],
        "scheduled": ["inbox", "open", "blocked", "failed", "paused", "implementation_finished", "review",
                      "queued", "in_progress", "cancelled"],
        "in_progress": ["inbox", "open", "blocked", "failed", "paused", "implementation_finished", "review",
                        "scheduled", "waiting_approval", "cancelled"],
        "waiting_approval": ["inbox", "open", "blocked", "failed", "paused", "implementation_finished", "review",
                             "in_progress", "cancelled"],
        "blocked": ["inbox", "open", "failed", "paused", "implementation_finished", "review",
                    "queued", "scheduled", "in_progress", "cancelled"],
        "paused": ["inbox", "open", "blocked", "failed", "implementation_finished", "review",
                   "queued", "scheduled", "in_progress", "cancelled"],
        "implementation_finished": ["queued", "scheduled", "in_progress", "blocked", "review", "open", "failed", "cancelled"],
        "review": ["queued", "scheduled", "in_progress", "blocked", "integrated", "open", "cancelled"],
        "integrated": ["done"],
        "done": ["open"],
        "failed": ["queued", "scheduled", "in_progress", "blocked", "open", "cancelled"],
        "cancelled": ["inbox", "open"],
    ], as: WorkItemStatus.self)

    @Test func allAllowedAndForbiddenTransitions() {
        verifyAllPairs(Self.expected)
    }

    @Test func rawValuesMatchFrontmatter() {
        #expect(WorkItemStatus.allCases.map(\.rawValue) == [
            "inbox", "open", "queued", "scheduled", "in_progress", "waiting_approval", "implementation_finished",
            "review", "integrated", "done", "blocked", "failed", "cancelled", "paused",
        ])
    }

    @Test func integratedOnlyFromReviewAndDoneOnlyAfterIntegrationOrManualCompletion() {
        let toIntegrated = WorkItemStatus.allCases.filter { $0.canTransition(to: .integrated) }
        #expect(toIntegrated == [.review])
        let toDone = Set(WorkItemStatus.allCases.filter { $0.canTransition(to: .done) })
        #expect(toDone == [.integrated, .inbox, .open])
    }

    @Test func manualChangeWithActiveJobIsRejected() {
        #expect(throws: WorkItemStatusChangeError.activeJobConflict(current: .inProgress, requested: .open)) {
            try WorkItemStatus.inProgress.validateManualChange(to: .open, hasActiveJob: true)
        }
        #expect(throws: WorkItemStatusChangeError.invalidTransition(InvalidStateTransition(from: .open, to: .integrated))) {
            try WorkItemStatus.open.validateManualChange(to: .integrated, hasActiveJob: false)
        }
        var item = WorkItem(type: .todo, title: "x", status: .open, createdAt: referenceDate)
        #expect(throws: WorkItemError.statusChange(.activeJobConflict(current: .open, requested: .cancelled))) {
            try item.changeStatusManually(to: .cancelled, hasActiveJob: true, at: referenceDate)
        }
        #expect(item.status == .open)
        #expect(throws: Never.self) { try item.changeStatusManually(to: .cancelled, hasActiveJob: false, at: referenceDate) }
        #expect(item.status == .cancelled)
    }
}

@Suite("AgentJobState state machine")
struct AgentJobStateTests {
    static let expected = table([
        "requested": ["pendingMac", "scheduled", "admitted", "needs_configuration", "failed", "cancelled"],
        "pendingMac": ["scheduled", "admitted", "needs_configuration", "failed", "cancelled"],
        "scheduled": ["pendingMac", "admitted", "needs_configuration", "waiting_quota", "paused", "failed", "cancelled"],
        "admitted": ["starting", "scheduled", "needs_configuration", "paused", "failed", "cancelled"],
        "starting": ["running", "needs_configuration", "waiting_quota", "failed", "cancelled"],
        "running": ["finished", "waiting_approval", "waiting_quota", "paused", "failed", "cancelled"],
        "waiting_approval": ["running", "paused", "failed", "cancelled"],
        "waiting_quota": ["scheduled", "admitted", "paused", "failed", "cancelled"],
        "needs_configuration": ["pendingMac", "scheduled", "failed", "cancelled"],
        "paused": ["pendingMac", "scheduled", "running", "failed", "cancelled"],
        "finished": [],
        "failed": [],
        "cancelled": [],
    ], as: AgentJobState.self)

    @Test func allAllowedAndForbiddenTransitions() {
        verifyAllPairs(Self.expected)
    }

    @Test func terminalStates() {
        #expect(Set(AgentJobState.allCases.filter(\.isTerminal)) == [.finished, .failed, .cancelled])
    }

    @Test func happyPathAndTimestamps() throws {
        var job = Fixtures.job(snapshot: try Fixtures.resolvedSnapshot())
        let path: [AgentJobState] = [.pendingMac, .scheduled, .admitted, .starting, .running, .waitingApproval, .running, .finished]
        for (offset, state) in path.enumerated() {
            try job.transition(to: state, at: referenceDate.addingTimeInterval(Double(offset + 1)))
        }
        #expect(job.state == .finished)
        #expect(job.startedAt == referenceDate.addingTimeInterval(4))
        #expect(job.finishedAt == referenceDate.addingTimeInterval(8))
        #expect(throws: AgentJobError.invalidTransition(InvalidStateTransition(from: .finished, to: .running))) {
            try job.transition(to: .running, at: referenceDate)
        }
    }
}

@Suite("ADR status state machine")
struct ADRStatusTests {
    @Test func allAllowedAndForbiddenTransitions() {
        verifyAllPairs(table([
            "proposed": ["accepted", "deprecated"],
            "accepted": ["deprecated", "superseded"],
            "deprecated": [],
            "superseded": [],
        ], as: ADRStatus.self))
    }
}

@Suite("ADR-0012 job → work item mapping")
struct JobStatusMappingTests {
    static let expectedMapping: [(AgentJobState, WorkItemStatus?)] = [
        (.requested, .queued),
        (.pendingMac, .queued),
        (.scheduled, .scheduled),
        (.waitingQuota, .scheduled),
        (.admitted, .inProgress),
        (.starting, .inProgress),
        (.running, .inProgress),
        (.waitingApproval, .waitingApproval),
        (.needsConfiguration, .blocked),
        (.paused, .paused),
        (.finished, .implementationFinished),
        (.failed, .failed),
        (.cancelled, nil), // nil: status before the job
    ]

    @Test func mappingCoversEveryJobState() {
        #expect(Set(Self.expectedMapping.map(\.0)) == Set(AgentJobState.allCases))
    }

    @Test(arguments: WorkItemStatus.jobStartable.sorted { $0.rawValue < $1.rawValue })
    func fullMappingTable(previous: WorkItemStatus) {
        for (jobState, expected) in Self.expectedMapping {
            let derived = WorkItemStatus.derived(from: jobState, previous: previous)
            #expect(derived == (expected ?? previous), "\(jobState) with previous \(previous)")
        }
    }

    @Test func cancelledReturnsToStatusBeforeJob() {
        #expect(WorkItemStatus.derived(from: .cancelled, previous: .open) == .open)
        #expect(WorkItemStatus.derived(from: .cancelled, previous: .review) == .review)
        #expect(WorkItemStatus.derived(from: .cancelled, previous: .failed) == .failed)
    }

    @Test func integratedAndDoneAreNeverDerivedFromAJob() {
        for previous in WorkItemStatus.jobStartable {
            for jobState in AgentJobState.allCases {
                let derived = WorkItemStatus.derived(from: jobState, previous: previous)
                #expect(derived != .integrated && derived != .done)
            }
        }
        #expect(!WorkItemStatus.integrated.canStartAgentJob)
        #expect(!WorkItemStatus.done.canStartAgentJob)
    }

    /// Every status change the host derives while a job moves through allowed transitions must itself
    /// be an allowed WorkItem transition.
    @Test func derivedTransitionsAreAllowedByWorkItemMachine() {
        let initialJobStates: [AgentJobState] = [.requested, .pendingMac, .scheduled, .admitted, .needsConfiguration]
        for previous in WorkItemStatus.jobStartable {
            for initial in initialJobStates {
                let derived = WorkItemStatus.derived(from: initial, previous: previous)
                #expect(derived == previous || previous.canTransition(to: derived), "start \(previous) → \(derived)")
            }
            for from in AgentJobState.allCases {
                for to in from.allowedNextStates {
                    let a = WorkItemStatus.derived(from: from, previous: previous)
                    let b = WorkItemStatus.derived(from: to, previous: previous)
                    #expect(a == b || a.canTransition(to: b), "job \(from)→\(to) derives \(a)→\(b) (previous \(previous))")
                }
            }
        }
        #expect(WorkItemStatus.implementationFinished.canTransition(to: .review))
    }

    @Test func workItemFollowsJobThroughCancel() throws {
        var item = WorkItem(type: .feature, title: "x", status: .review, createdAt: referenceDate)
        var job = Fixtures.job(snapshot: try Fixtures.resolvedSnapshot(), before: item.status)
        try item.applyDerivedStatus(from: job, at: referenceDate)
        #expect(item.status == .queued)
        try job.transition(to: .admitted, at: referenceDate)
        try item.applyDerivedStatus(from: job, at: referenceDate)
        #expect(item.status == .inProgress)
        try job.transition(to: .cancelled, at: referenceDate)
        try item.applyDerivedStatus(from: job, at: referenceDate)
        #expect(item.status == .review)
    }
}
