// Core.app's front door. Points dyld (and, through __XPC_, WebKit's own
// XPC services) at the WebKit inside the bundle, then becomes the app.
// Without this the system WebKit would be loaded, and none of the engine's
// protections with it.
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
    if (!realpath(frameworks, resolved))
        return 1;

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
