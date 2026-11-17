// C entry points for the Mac execution launcher: a fork-and-exec that applies resource limits and a new session
// before execve, which posix_spawn cannot do, and the App Sandbox probe. ExecLauncher.swift in AstralCore is the only caller.

#ifndef ASTRAL_EXEC_SPAWN_H
#define ASTRAL_EXEC_SPAWN_H

#include <stdint.h>
#include <sys/types.h>

typedef struct {
    uint64_t file_bytes;
    uint64_t open_files;
    uint64_t core_bytes;
    uint64_t cpu_seconds;
    int apply_process_limit;
    uint64_t process_limit;
} astral_exec_limits;

int astral_exec_spawn(
    const char *path, char *const argv[], char *const envp[], const char *cwd, int stdin_fd, int stdout_fd,
    int stderr_fd, const astral_exec_limits *limits, pid_t *pid_out, int *step_out);

int astral_exec_app_sandboxed(void);

#endif
