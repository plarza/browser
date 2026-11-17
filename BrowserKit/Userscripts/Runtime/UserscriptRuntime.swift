/// The JavaScript that runs a script in a page: a function that goes in
/// before anything else, once per script. It takes the script's own
/// function and its settings, checks the address, builds the GM APIs the
/// script was granted, and calls it at its @run-at.
///
/// It is one function, written here a part at a time. The parts share its
/// scope: what one declares, the ones after it use.
enum UserscriptRuntime {
    static let source = "function (run, C) {\n" + parts.joined(separator: "\n") + "\n}"

    private static let parts = [
        start, values, resources, elements, requests, menuCommands, tabs, notifications, clipboard, downloads, apis, launch,
    ]
}
