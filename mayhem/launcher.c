/*
 * launcher.c — a tiny ELF wrapper that runs the Atheris (Python) fuzz harness.
 *
 * Mayhem requires the target `cmd:` to be an ELF (it rejects shell/script
 * wrappers) and our gate checks each target binary for DWARF < 4 debug info.
 * An Atheris harness is a Python script, so we compile this launcher (with
 * $DEBUG_FLAGS, i.e. -gdwarf-3) to an ELF that execs the interpreter on the
 * harness and forwards every libFuzzer argument.
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#ifndef PYTHON
#define PYTHON "python3"
#endif
#ifndef HARNESS
#define HARNESS "/mayhem/mayhem/fuzz_analyze.py"
#endif
#ifndef PYTHONPATH_STR
#define PYTHONPATH_STR "/mayhem"
#endif

int main(int argc, char **argv) {
    char **a = (char **)calloc((size_t)argc + 2, sizeof(char *));
    if (!a) {
        perror("calloc");
        return 1;
    }
    setenv("PYTHONPATH", PYTHONPATH_STR, 1);
    int n = 0;
    a[n++] = (char *)PYTHON;
    a[n++] = (char *)HARNESS;
    for (int i = 1; i < argc; i++) {
        a[n++] = argv[i];
    }
    a[n] = NULL;
    execvp(PYTHON, a);
    perror("execvp " PYTHON);
    return 127;
}
