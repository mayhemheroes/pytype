/*
 * run_tests.c — ELF wrapper for pytype's build_scripts/run_tests.py oracle.
 *
 * Routes the suite through a NON-system binary so the gate's anti-reward-hack
 * sabotage check (LD_PRELOAD neuter of project binaries) perturbs the run.
 *
 * argv forwarded to: python3 build_scripts/run_tests.py <args...>
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#ifndef PYTHON
#define PYTHON "python3"
#endif
#ifndef RUN_TESTS
#define RUN_TESTS "/mayhem/build_scripts/run_tests.py"
#endif

int main(int argc, char **argv) {
    char **a = (char **)calloc((size_t)argc + 3, sizeof(char *));
    if (!a) {
        perror("calloc");
        return 1;
    }
    int n = 0;
    a[n++] = (char *)PYTHON;
    a[n++] = (char *)RUN_TESTS;
    for (int i = 1; i < argc; i++) {
        a[n++] = argv[i];
    }
    a[n] = NULL;
    execvp(PYTHON, a);
    perror("execvp " PYTHON);
    return 127;
}
