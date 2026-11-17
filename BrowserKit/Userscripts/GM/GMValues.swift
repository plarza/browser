import Foundation

/// GM_setValue and GM_deleteValue, one value at a time or many. A copy of
/// a script reads the values it was given as it started; what it writes
/// comes here, to be kept and passed on.
@MainActor
final class GMValues {
    private static let grants: Set<String> = ["setvalue", "setvalues", "deletevalue", "deletevalues"]

    private let values: UserscriptValues
    private let pages: UserscriptPages

    init(_ values: UserscriptValues, pages: UserscriptPages) {
        self.values = values
        self.pages = pages
    }

    /// Keeps the value (or deletes it, when there is none), and tells every
    /// other running copy of the script, in this tab or another, so their
    /// change listeners hear it.
    func set(_ call: UserscriptCall) throws(UserscriptRefusal) {
        guard !call.grants.isDisjoint(with: GMValues.grants), let key = call.string("key") else { throw .notGranted }
        let value = call.string("value")
        values.set(value, for: key, of: call.script.id)
        for instance in pages.instances(of: call.script.id) where instance.id != call.instance.id {
            Task { await instance.push(["type": "value", "key": key, "value": value ?? NSNull()]) }
        }
    }
}
