/* Stands in for Cyberpunk2077. Sleeps for ARCHIVE_LOADER_FAKE_SLEEP seconds
   (default 0) and exits with ARCHIVE_LOADER_FAKE_EXIT (default 0), so one
   binary covers clean exit, failure, and a session long enough to signal. */
#include <stdlib.h>
#include <unistd.h>

int main(void) {
    const char *sleep_for = getenv("ARCHIVE_LOADER_FAKE_SLEEP");
    const char *exit_with = getenv("ARCHIVE_LOADER_FAKE_EXIT");
    if (sleep_for != NULL) {
        sleep((unsigned int)atoi(sleep_for));
    }
    return exit_with != NULL ? atoi(exit_with) : 0;
}
