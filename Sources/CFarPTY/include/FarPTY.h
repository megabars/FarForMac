#ifndef FAR_PTY_H
#define FAR_PTY_H
#include <sys/types.h>
#ifdef __cplusplus
extern "C" {
#endif
/// Fork/exec boundary: the child runs C syscalls only and never returns to Swift.
/// The caller owns the PTY descriptors. Returns zero or an errno value.
int far_pty_fork_exec(int master, int slave, const char *shell,
                      char *const argv[], char *const envp[],
                      const char *directory, pid_t *child_pid);
/// Enumerate process groups belonging to the isolated terminal session.
int far_pty_session_groups(pid_t session, pid_t *groups, int capacity);
#ifdef __cplusplus
}
#endif
#endif
