// Core.app's front door. Points dyld (and, through __XPC_, WebKit's own
// XPC services) at the WebKit inside the bundle, then becomes the app.
// Missing frameworks are a hard failure; CoreApp also verifies the loaded
// engine before it can create a browser window.
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[])
{
    char raw[PATH_MAX], self[PATH_MAX];
    uint32_t size = sizeof(raw);
    if (_NSGetExecutablePath(raw, &size) != 0 || !realpath(raw, self))
        return 1;
    char macos[PATH_MAX];
    strlcpy(macos, dirname(self), sizeof(macos));

    char frameworks[PATH_MAX], app[PATH_MAX];
    snprintf(frameworks, sizeof(frameworks), "%s/../Frameworks", macos);
    snprintf(app, sizeof(app), "%s/CoreApp", macos);
    char resolved[PATH_MAX];
    if (!realpath(frameworks, resolved)) {
        fprintf(stderr, "Core cannot start: its bundled engine is missing.\n");
        return 78;
    }

    const char *required[] = { "JavaScriptCore", "WebCore", "WebKit" };
    for (size_t i = 0; i < sizeof(required) / sizeof(required[0]); ++i) {
        char binary[PATH_MAX];
        snprintf(binary, sizeof(binary), "%s/%s.framework/Versions/A/%s", resolved, required[i], required[i]);
        if (access(binary, R_OK) != 0) {
            fprintf(stderr, "Core cannot start: its bundled %s framework is missing.\n", required[i]);
            return 78;
        }
    }

    setenv("DYLD_FRAMEWORK_PATH", resolved, 1);
    setenv("DYLD_LIBRARY_PATH", resolved, 1);
    setenv("__XPC_DYLD_FRAMEWORK_PATH", resolved, 1);
    setenv("__XPC_DYLD_LIBRARY_PATH", resolved, 1);
    setenv("WEBKIT_UNSET_DYLD_FRAMEWORK_PATH", "YES", 1);

    argv[0] = app;
    execv(app, argv);
    perror("Core: exec");
    return 1;
}
