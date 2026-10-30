import Foundation
import QuestmasterCore

/// The bard's `animation.json`, read from the app's resources, for the class avatar's tests.
enum AvatarAnimationFixture {
    /// The bard's file as a JSON object, so a test can edit it before it is decoded.
    static func bardJSON() -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Resources/Sprites/bard/animation.json")
        guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fputs("AvatarAnimationFixture: the bard's animation.json should read as a JSON object at \(url.path)\n", stderr)
            exit(1)
        }
        return json
    }

    static func decode(_ json: [String: Any]) throws -> TrackerAvatarAnimation {
        try TrackerAvatarAnimation(data: JSONSerialization.data(withJSONObject: json))
    }

    static func bard() -> TrackerAvatarAnimation {
        guard let animation = try? decode(bardJSON()) else {
            fputs("AvatarAnimationFixture: the bard's animation.json should decode\n", stderr)
            exit(1)
        }
        return animation
    }

    /// A catalog that gives the bard `animation`.
    static func catalog(_ animation: TrackerAvatarAnimation = bard()) -> TrackerAvatarCatalog {
        TrackerAvatarCatalog(animations: ["bard": animation])
    }

    /// The bard's catalog with every finish taken out, for a class whose casts never finish.
    static func catalogWithoutFinishes() -> TrackerAvatarCatalog {
        var json = bardJSON()
        var poses = json["poses"] as? [String: Any] ?? [:]
        for name in poses.keys {
            guard var pose = poses[name] as? [String: Any] else {
                continue
            }
            pose.removeValue(forKey: "finish")
            poses[name] = pose
        }
        json["poses"] = poses
        guard let animation = try? decode(json) else {
            fputs("AvatarAnimationFixture: the bard's file without finishes should decode\n", stderr)
            exit(1)
        }
        return catalog(animation)
    }
}
