// Implements the fork-and-exec the Mac execution launcher needs: the child becomes a session leader, sets every
// limit as soft and hard, restores default signals, closes inherited descriptors and execs sandbox-exec. It reports a failed step through a close-on-exec pipe.

#include "AstralExecSpawn.h"

#include <TargetConditionals.h>

#if TARGET_OS_OSX

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>

extern int sandbox_check(pid_t pid, const char *operation, int type, ...);

enum { SANDBOX_FILTER_NONE = 0 };

enum {
    STEP_SESSION = 1,
    STEP_LIMIT = 2,
    STEP_SIGNALS = 3,
    STEP_STDIO = 4,
    STEP_CHDIR = 5,
    STEP_EXEC = 6,
};

static int set_limit(int resource, uint64_t value) {
    struct rlimit limit;
    limit.rlim_cur = (rlim_t)value;
    limit.rlim_max = (rlim_t)value;
    return setrlimit(resource, &limit);
}

static void fail(int status_fd, int step, int code) {
    int report[2] = {step, code};
    ssize_t ignored = write(status_fd, report, sizeof report);
    (void)ignored;
    _exit(127);
}

static int move_above_stdio(int fd) {
    if (fd > 2) {
        return fd;
    }
    int moved = fcntl(fd, F_DUPFD_CLOEXEC, 3);
    close(fd);
    return moved;
}

int astral_exec_spawn(
    const char *path, char *const argv[], char *const envp[], const char *cwd, int stdin_fd, int stdout_fd,
    int stderr_fd, const astral_exec_limits *limits, pid_t *pid_out, int *step_out) {
    int status[2];
    if (pipe(status) != 0) {
        return errno;
    }
    status[0] = move_above_stdio(status[0]);
    status[1] = move_above_stdio(status[1]);
    if (status[0] < 0 || status[1] < 0) {
        int code = errno;
        close(status[0]);
        close(status[1]);
        return code;
    }
    fcntl(status[0], F_SETFD, FD_CLOEXEC);
    fcntl(status[1], F_SETFD, FD_CLOEXEC);
    pid_t pid = fork();
    if (pid < 0) {
        int code = errno;
        close(status[0]);
        close(status[1]);
        return code;
    }
    if (pid == 0) {
        close(status[0]);
        if (setsid() < 0) {
            fail(status[1], STEP_SESSION, errno);
        }
        int table = getdtablesize();
        int sources[3] = {stdin_fd, stdout_fd, stderr_fd};
        for (int index = 0; index < 3; index++) {
            int moved = fcntl(sources[index], F_DUPFD, 3);
            if (moved < 0) {
                fail(status[1], STEP_STDIO, errno);
            }
            sources[index] = moved;
        }
        for (int target = 0; target < 3; target++) {
            if (dup2(sources[target], target) < 0) {
                fail(status[1], STEP_STDIO, errno);
            }
        }
        for (int fd = 3; fd < table; fd++) {
            if (fd != status[1]) {
                close(fd);
            }
        }
        if (set_limit(RLIMIT_CORE, limits->core_bytes) != 0 || set_limit(RLIMIT_FSIZE, limits->file_bytes) != 0
            || set_limit(RLIMIT_NOFILE, limits->open_files) != 0 || set_limit(RLIMIT_CPU, limits->cpu_seconds) != 0
            || (limits->apply_process_limit && set_limit(RLIMIT_NPROC, limits->process_limit) != 0)) {
            fail(status[1], STEP_LIMIT, errno);
        }
        for (int number = 1; number < NSIG; number++) {
            if (number != SIGKILL && number != SIGSTOP) {
                signal(number, SIG_DFL);
            }
        }
        sigset_t none;
        sigemptyset(&none);
        if (sigprocmask(SIG_SETMASK, &none, NULL) != 0) {
            fail(status[1], STEP_SIGNALS, errno);
        }
        if (chdir(cwd) != 0) {
            fail(status[1], STEP_CHDIR, errno);
        }
        execve(path, argv, envp);
        fail(status[1], STEP_EXEC, errno);
    }
    close(status[1]);
    int report[2];
    ssize_t got;
    do {
        got = read(status[0], report, sizeof report);
    } while (got < 0 && errno == EINTR);
    close(status[0]);
    *pid_out = pid;
    if (got == (ssize_t)sizeof report) {
        int ignored;
        waitpid(pid, &ignored, 0);
        *step_out = report[0];
        return report[1] != 0 ? report[1] : EINVAL;
    }
    if (got != 0) {
        kill(pid, SIGKILL);
        int ignored;
        waitpid(pid, &ignored, 0);
        *step_out = 0;
        return EIO;
    }
    return 0;
}

int astral_exec_app_sandboxed(void) {
    return sandbox_check(getpid(), NULL, SANDBOX_FILTER_NONE) != 0;
}

#else

int astral_exec_spawn(
    const char *path, char *const argv[], char *const envp[], const char *cwd, int stdin_fd, int stdout_fd,
    int stderr_fd, const astral_exec_limits *limits, pid_t *pid_out, int *step_out) {
    (void)path;
    (void)argv;
    (void)envp;
    (void)cwd;
    (void)stdin_fd;
    (void)stdout_fd;
    (void)stderr_fd;
    (void)limits;
    (void)pid_out;
    *step_out = 0;
    return 78;
}

int astral_exec_app_sandboxed(void) {
    return 1;
}

#endif
