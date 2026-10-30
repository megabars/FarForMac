#ifndef FAR_CNETWORK_H
#define FAR_CNETWORK_H
#include <stdint.h>
#include <stddef.h>
typedef size_t (*far_network_write)(const void *, size_t, void *);
typedef int (*far_network_progress)(int64_t, int64_t, void *);
/* operation: 0 MLSD, 1 download, 2 upload, 3 quote command(s). */
int far_ftp_perform(const char *url, const char *user, const char *password,
                    int tls, double timeout, int operation, const char *local_path,
                    int64_t offset, const char *command1, const char *command2,
                    far_network_write write, far_network_progress progress, void *context,
                    long *response, char *error, size_t error_size);
#endif
