/* Announces that dyld loaded it, by writing the path in
   ARCHIVE_LOADER_PROBE_MARKER. Each process under test sets a different
   value, so one probe distinguishes "loaded into the wrapper" from
   "loaded into the game". */
#include <stdio.h>
#include <stdlib.h>

__attribute__((constructor))
static void probe_loaded(void) {
    const char *marker = getenv("ARCHIVE_LOADER_PROBE_MARKER");
    if (marker == NULL) {
        return;
    }
    FILE *file = fopen(marker, "w");
    if (file != NULL) {
        fputs("loaded\n", file);
        fclose(file);
    }
}
