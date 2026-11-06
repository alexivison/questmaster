import Foundation
import QuestmasterCore

struct ProjectMutationRequestTests {
    static func run() {
        projectAddEncodesPathNameAndColor()
        projectAddOmitsBlankNameAndColor()
        projectAddRequiresPath()
        projectUpdateOmitsUnchangedFields()
        projectUpdateSendsEmptyStringToClear()
        projectUpdateRequiresProjectID()
        projectReorderEncodesIDsAsAnArray()
        projectReorderRequiresIDs()
        print("ProjectMutationRequestTests: all tests passed")
    }

    private static func projectAddEncodesPathNameAndColor() {
        do {
            let request = try ServeMutationRequests.projectAdd(path: " ~/Code/alpha ", name: " Alpha ", color: " Violet ")
            let object = request.jsonObject(id: "project-add") as NSDictionary
            let data = object["data"] as? NSDictionary
            expect(request.method == "project.add", "project add method mismatch: \(request.method)")
            expect(object["method"] as? String == "project.add", "project add should send the project.add method")
            expect(data?["path"] as? String == "~/Code/alpha", "project add path should be trimmed and passed through")
            expect(data?["name"] as? String == "Alpha", "project add name should be trimmed")
            expect(data?["color"] as? String == "violet", "project add color should be trimmed and lowercased")
        } catch {
            fail("project add request threw \(error)")
        }
    }

    private static func projectAddOmitsBlankNameAndColor() {
        do {
            let request = try ServeMutationRequests.projectAdd(path: "/tmp/alpha", name: "   ", color: nil)
            let data = request.jsonObject(id: "project-add-bare")["data"] as? NSDictionary
            expect(data?["path"] as? String == "/tmp/alpha", "project add path should be sent")
            expect(data?["name"] == nil, "a blank project add name should be omitted")
            expect(data?["color"] == nil, "a missing project add color should be omitted")
        } catch {
            fail("bare project add request threw \(error)")
        }
    }

    private static func projectAddRequiresPath() {
        do {
            _ = try ServeMutationRequests.projectAdd(path: "  ")
            fail("a blank project add path should throw")
        } catch ServeMutationRequestError.missing(let field) {
            expect(field == "path", "blank project add path missing field was \(field)")
        } catch {
            fail("blank project add path threw wrong error \(error)")
        }
    }

    private static func projectUpdateOmitsUnchangedFields() {
        do {
            let request = try ServeMutationRequests.projectUpdate(projectID: " repo-a ")
            let object = request.jsonObject(id: "project-update-none") as NSDictionary
            let data = object["data"] as? NSDictionary
            expect(request.method == "project.update", "project update method mismatch: \(request.method)")
            expect(data?["project_id"] as? String == "repo-a", "project update id should be trimmed")
            expect(data?["name"] == nil, "an unchanged name should be omitted, not cleared")
            expect(data?["color"] == nil, "an unchanged color should be omitted, not cleared")
        } catch {
            fail("project update request threw \(error)")
        }
    }

    private static func projectUpdateSendsEmptyStringToClear() {
        do {
            let renamed = try ServeMutationRequests.projectUpdate(projectID: "repo-a", name: " Renamed ", color: "")
            let renamedData = renamed.jsonObject(id: "project-rename")["data"] as? NSDictionary
            expect(renamedData?["name"] as? String == "Renamed", "a new name should be trimmed and sent")
            expect(renamedData?["color"] as? String == "", "an empty color should be sent to clear it")

            let cleared = try ServeMutationRequests.projectUpdate(projectID: "repo-a", name: "")
            let clearedData = cleared.jsonObject(id: "project-clear-name")["data"] as? NSDictionary
            expect(clearedData?["name"] as? String == "", "an empty name should be sent to clear the override")
            expect(clearedData?["color"] == nil, "a color left nil should still be omitted")

            let recolored = try ServeMutationRequests.projectUpdate(projectID: "repo-a", color: " Teal ")
            let recoloredData = recolored.jsonObject(id: "project-recolor")["data"] as? NSDictionary
            expect(recoloredData?["color"] as? String == "teal", "a new color should be trimmed and lowercased")
            expect(recoloredData?["name"] == nil, "a name left nil should be omitted when only the color changes")
        } catch {
            fail("project update clear request threw \(error)")
        }
    }

    private static func projectUpdateRequiresProjectID() {
        do {
            _ = try ServeMutationRequests.projectUpdate(projectID: " ", name: "Renamed")
            fail("a blank project update id should throw")
        } catch ServeMutationRequestError.missing(let field) {
            expect(field == "project_id", "blank project update id missing field was \(field)")
        } catch {
            fail("blank project update id threw wrong error \(error)")
        }
    }

    private static func projectReorderEncodesIDsAsAnArray() {
        do {
            let request = try ServeMutationRequests.projectReorder(projectIDs: [" repo-b ", "repo-a"])
            let object = request.jsonObject(id: "project-reorder") as NSDictionary
            let data = object["data"] as? NSDictionary
            expect(request.method == "project.reorder", "project reorder method mismatch: \(request.method)")
            expect(data?["project_ids"] as? [String] == ["repo-b", "repo-a"], "project ids should be sent as an ordered array")

            let encoded = try request.jsonData(id: "project-reorder")
            let decoded = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            let decodedData = decoded?["data"] as? [String: Any]
            expect(
                decodedData?["project_ids"] as? [String] == ["repo-b", "repo-a"],
                "project ids should survive JSON serialization as an array"
            )
            expect(decodedData?["project_ids"] as? String == nil, "project ids should not be a string")
        } catch {
            fail("project reorder request threw \(error)")
        }
    }

    private static func projectReorderRequiresIDs() {
        do {
            _ = try ServeMutationRequests.projectReorder(projectIDs: [])
            fail("an empty project reorder should throw")
        } catch ServeMutationRequestError.missing(let field) {
            expect(field == "project_ids", "empty project reorder missing field was \(field)")
        } catch {
            fail("empty project reorder threw wrong error \(error)")
        }

        do {
            _ = try ServeMutationRequests.projectReorder(projectIDs: ["repo-a", " "])
            fail("a blank project id in a reorder should throw")
        } catch ServeMutationRequestError.missing(let field) {
            expect(field == "project_ids", "blank project id in reorder missing field was \(field)")
        } catch {
            fail("blank project id in reorder threw wrong error \(error)")
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fail(message)
        }
    }

    private static func fail(_ message: String) -> Never {
        fputs("ProjectMutationRequestTests failed: \(message)\n", stderr)
        Foundation.exit(1)
    }
}
