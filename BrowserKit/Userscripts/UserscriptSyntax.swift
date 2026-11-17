import JavaScriptCore

/// Whether JavaScriptCore can parse a script, without running it.
enum UserscriptSyntax {
    /// What is wrong with `source` as a userscript's body, or nil. The
    /// body is a function's, as it is when it runs: an async one for a
    /// script with @top-level-await.
    static func error(in source: String, topLevelAwait: Bool = false) -> String? {
        guard let context = JSContext() else { return nil }
        var error: String?
        context.exceptionHandler = { _, exception in
            // The function's own first line comes before the script's.
            let line = Int(exception?.objectForKeyedSubscript("line")?.toInt32() ?? 1) - 1
            error = "Line \(max(line, 1)): \(exception?.toString() ?? "a syntax error")"
        }
        // A function that is never called: parsed, not run.
        context.evaluateScript("(\(topLevelAwait ? "async function" : "function") () {\n" + source + "\n})")
        return error
    }
}
