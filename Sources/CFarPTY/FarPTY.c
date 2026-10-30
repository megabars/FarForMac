#include "FarPTY.h"
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <stdlib.h>
#include <sys/proc_info.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>

static void child_failure(int descriptor, int error) {
    const char *bytes = (const char *)&error;
    size_t remaining = sizeof(error);
    while (remaining) {
        ssize_t count = write(descriptor, bytes, remaining);
        if (count > 0) { bytes += count; remaining -= (size_t)count; }
        else if (count < 0 && errno == EINTR) { continue; }
        else { break; }
    }
    _exit(127);
}

int far_pty_fork_exec(int master, int slave, const char *shell,
                      char *const argv[], char *const envp[],
                      const char *directory, pid_t *child_pid) {
    int errors[2];
    if (pipe(errors) == -1) return errno;
    // Keep the startup-report pipe separate from the three terminal handles.
    for (int index = 0; index < 2; index++) {
        int replacement = fcntl(errors[index], F_DUPFD_CLOEXEC, 3);
        if (replacement == -1) {
            int error = errno;
            close(errors[0]); close(errors[1]);
            return error;
        }
        close(errors[index]);
        errors[index] = replacement;
    }
    const int descriptor_limit = getdtablesize();
    struct sigaction defaults = {0};
    defaults.sa_handler = SIG_DFL;
    sigemptyset(&defaults.sa_mask);
    sigset_t empty_mask;
    sigemptyset(&empty_mask);
    pid_t child = fork();
    if (child == -1) {
        int error = errno;
        close(errors[0]); close(errors[1]);
        return error;
    }
    if (child == 0) {
        // This branch must stay entirely in C and use syscall-only operations:
        // the host is a multithreaded AppKit/Swift application.
        close(errors[0]);
        close(master);
        if (setsid() == -1) child_failure(errors[1], errno);
        if (ioctl(slave, TIOCSCTTY, 0) == -1) child_failure(errors[1], errno);
        for (int descriptor = 0; descriptor < 3; descriptor++) {
            if (dup2(slave, descriptor) == -1) child_failure(errors[1], errno);
        }
        if (chdir(directory) == -1) child_failure(errors[1], errno);
        if (sigprocmask(SIG_SETMASK, &empty_mask, NULL) == -1) child_failure(errors[1], errno);
        for (int signal = 1; signal < NSIG; signal++) {
            if (signal != SIGKILL && signal != SIGSTOP) sigaction(signal, &defaults, NULL);
        }
        for (int descriptor = 3; descriptor < descriptor_limit; descriptor++) {
            if (descriptor != errors[1]) close(descriptor);
        }
        execve(shell, argv, envp);
        child_failure(errors[1], errno);
    }
    close(errors[1]);
    int error = 0;
    char *bytes = (char *)&error;
    size_t received = 0;
    while (received < sizeof(error)) {
        ssize_t count = read(errors[0], bytes + received, sizeof(error) - received);
        if (count > 0) received += (size_t)count;
        else if (count == 0) break; // CLOEXEC closes the pipe on successful exec.
        else if (errno == EINTR) continue;
        else {
            error = errno;
            received = sizeof(error);
            kill(child, SIGKILL); // A failed report read must not block on a live shell.
            break;
        }
    }
    close(errors[0]);
    if (received != 0) {
        if (received != sizeof(error) || error == 0) error = EIO;
        int status;
        while (waitpid(child, &status, 0) == -1 && errno == EINTR) {}
        return error;
    }
    *child_pid = child;
    return 0;
}

int far_pty_session_groups(pid_t session, pid_t *groups, int capacity) {
    if (capacity <= 0 || session <= 1) return 0;
    int needed = proc_listpids(PROC_UID_ONLY, geteuid(), NULL, 0);
    if (needed <= 0) return 0;
    // Bound the snapshot even on a host with an unusually large process table.
    int length = needed > 1044480 ? 1048576 : needed + 4096;
    pid_t *processes = malloc((size_t)length);
    if (!processes) return 0;
    int bytes = proc_listpids(PROC_UID_ONLY, geteuid(), processes, length);
    if (bytes > length) bytes = length;
    int found = 0;
    for (int index = 0; index < bytes / (int)sizeof(pid_t) && found < capacity; index++) {
        pid_t process = processes[index];
        if (process > 1 && getsid(process) == session) {
            pid_t group = getpgid(process);
            if (group > 1) groups[found++] = group;
        }
    }
    free(processes);
    return found;
}
