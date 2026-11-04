import Foundation
import QuestmasterCore

struct ProjectOrderTests {
    static func run() {
        ordersByTheSnapshotsProjectOrder()
        unlistedAndEmptyIDsRankLast()
        firstListingOfAnIDWins()
        sortedItemsFollowTheOrderThenTitle()
        questSectionsFollowTheProjectOrder()
        questSectionsUseTheProjectsEffectiveName()
        questSectionsFallBackToTheStoredNameForAnUnlistedProject()
        projectDecodesDefaultNameAndDefaultsToName()
        print("ProjectOrderTests: all tests passed")
    }

    private static let projects = [
        TrackerProject(id: "repo-b", name: "Beta"),
        TrackerProject(id: "repo-a", name: "Alpha"),
        TrackerProject(id: "repo-c", name: "Gamma"),
    ]

    private static func ordersByTheSnapshotsProjectOrder() {
        let order = ProjectOrder(projects: projects)
        expect(order.rank(of: "repo-b") == 0, "the first listed project should rank first")
        expect(order.rank(of: "repo-a") == 1 && order.rank(of: "repo-c") == 2, "listed projects should rank by position")
        expect(order.project(for: "repo-a")?.name == "Alpha", "project(for:) should return the listed project")
    }

    private static func unlistedAndEmptyIDsRankLast() {
        let order = ProjectOrder(projects: projects)
        expect(order.rank(of: "repo-missing") == Int.max, "an unlisted project should rank last")
        expect(order.rank(of: "") == Int.max, "the empty ID should rank last")
        expect(order.project(for: "repo-missing") == nil, "project(for:) should be nil for an unlisted ID")
        expect(ProjectOrder(projects: []).rank(of: "repo-a") == Int.max, "with no projects every ID ranks last")
    }

    private static func firstListingOfAnIDWins() {
        let order = ProjectOrder(projects: [
            TrackerProject(id: "repo-a", name: "First"),
            TrackerProject(id: "repo-b", name: "Second"),
            TrackerProject(id: "repo-a", name: "Repeated"),
        ])
        expect(order.rank(of: "repo-a") == 0, "a repeated ID should keep its first position")
        expect(order.project(for: "repo-a")?.name == "First", "a repeated ID should keep its first listing")
    }

    private static func sortedItemsFollowTheOrderThenTitle() {
        let items: [(id: String, title: String)] = [
            (id: "repo-z", title: "Aardvark"),
            (id: "repo-c", title: "Zebra"),
            (id: "repo-a", title: "Mouse"),
            (id: "repo-missing", title: "Beaver"),
            (id: "repo-b", title: "Lion"),
        ]
        let sorted = ProjectOrder(projects: projects).sorted(items, id: \.id, title: \.title)
        expect(
            sorted.map(\.id) == ["repo-b", "repo-a", "repo-c", "repo-z", "repo-missing"],
            "items should follow the project order with unlisted ones last by title; got \(sorted.map(\.id))"
        )
    }

    private static func questSectionsFollowTheProjectOrder() {
        let quests = [
            QuestItem(id: "qst-a", content: "A", projectID: "repo-a", projectName: "Alpha", updatedAt: "2026-07-03T01:00:00Z"),
            QuestItem(id: "qst-x", content: "X", projectID: "repo-x", projectName: "Xray", updatedAt: "2026-07-03T02:00:00Z"),
            QuestItem(id: "qst-b", content: "B", projectID: "repo-b", projectName: "Beta", updatedAt: "2026-07-03T03:00:00Z"),
            QuestItem(id: "qst-none", content: "None", updatedAt: "2026-07-03T04:00:00Z"),
        ]
        let sections = QuestDisplayState.sections(quests: quests, repos: [], projects: projects)
        expect(
            sections.map(\.id) == ["repo-b", "repo-a", "repo-x", "no-project"],
            "sections should follow the project order, then the unlisted project, then no project; got \(sections.map(\.id))"
        )
        expect(
            sections.map(\.title) == ["Beta", "Alpha", "Xray", "No project"],
            "section titles should follow the same order; got \(sections.map(\.title))"
        )
    }

    private static func questSectionsUseTheProjectsEffectiveName() {
        let quests = [
            QuestItem(id: "qst-a", content: "A", projectID: "repo-a", projectName: "Old Name", updatedAt: "2026-07-03T01:00:00Z"),
        ]
        let renamed = [
            TrackerProject(id: "repo-a", name: "Renamed", defaultName: "alpha-folder", path: "/tmp/alpha-folder"),
        ]
        let sections = QuestDisplayState.sections(
            quests: quests,
            repos: [TrackerRepo(id: "repo-a", name: "alpha-folder", sessions: [])],
            projects: renamed
        )
        expect(sections.first?.title == "Renamed", "a section should show the project's effective name; got \(sections.first?.title ?? "nil")")
    }

    private static func questSectionsFallBackToTheStoredNameForAnUnlistedProject() {
        let quests = [
            QuestItem(id: "qst-x", content: "X", projectID: "repo-x", projectName: "Stored Name", updatedAt: "2026-07-03T01:00:00Z"),
        ]
        let sections = QuestDisplayState.sections(quests: quests, repos: [], projects: projects)
        expect(sections.first?.title == "Stored Name", "an unlisted project should show the quest's stored name; got \(sections.first?.title ?? "nil")")
    }

    private static func projectDecodesDefaultNameAndDefaultsToName() {
        do {
            let withDefault = try JSONDecoder().decode(TrackerProject.self, from: Data(#"""
            {"id":"repo-a","name":"Renamed","default_name":"alpha","path":"/tmp/alpha","color":"green"}
            """#.utf8))
            expect(withDefault.name == "Renamed" && withDefault.defaultName == "alpha", "default_name should decode as defaultName")
            expect(withDefault.path == "/tmp/alpha" && withDefault.color == "green", "path and color should still decode")

            let withoutDefault = try JSONDecoder().decode(TrackerProject.self, from: Data(#"""
            {"id":"repo-b","name":"Beta"}
            """#.utf8))
            expect(withoutDefault.defaultName == "Beta", "a missing default_name should fall back to the name")
        } catch {
            fail("project decode threw \(error)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("ProjectOrderTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
