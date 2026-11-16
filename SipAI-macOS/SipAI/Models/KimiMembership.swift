import Foundation

/// The membership a Kimi Code login is on, in kimi's own words.
///
/// `GET /api/v1/oauth/userinfo` on kimi's local server answers
/// `{"code":0,"data":{"kind":"ok","userInfo":{…}}}` — kimi's parse of the
/// account behind the login. Its `userLevelName` is the membership's
/// name, the one kimi's own web UI shows beside the account; Moonshot
/// names its plans (and reshuffles them), so the name is shown as kimi
/// gives it and never mapped to anything of SipAI's.
///
/// Nothing else of the answer is read: the same object carries the
/// account's nickname, e-mail address and phone number.
enum KimiMembership {
    nonisolated static func levelName(userInfoBody body: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              (root["code"] as? NSNumber)?.intValue == 0,
              let data = root["data"] as? [String: Any],
              (data["kind"] as? String) == "ok",
              let info = data["userInfo"] as? [String: Any],
              let name = (info["userLevelName"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return name
    }
}
