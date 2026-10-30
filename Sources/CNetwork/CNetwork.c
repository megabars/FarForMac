#include "CNetwork.h"
#include <curl/curl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <limits.h>
static pthread_once_t once = PTHREAD_ONCE_INIT;
static void initialize(void) { curl_global_init(CURL_GLOBAL_DEFAULT); }
struct callbacks { far_network_write write; far_network_progress progress; void *context; int upload; };
static size_t output(char *data, size_t size, size_t count, void *ctx) {
    struct callbacks *c = ctx;
    return c->write ? c->write(data, size * count, c->context) : size * count;
}
static int update(void *ctx, curl_off_t dt, curl_off_t dn, curl_off_t ut, curl_off_t un) {
    struct callbacks *c = ctx;
    return c->progress ? c->progress(c->upload ? un : dn, c->upload ? ut : dt, c->context) : 0;
}
int far_ftp_perform(const char *url, const char *user, const char *password,
                    int tls, double timeout, int operation, const char *local_path,
                    int64_t offset, const char *command1, const char *command2,
                    far_network_write write, far_network_progress progress, void *context,
                    long *response, char *error, size_t error_size) {
    pthread_once(&once, initialize);
    CURL *curl = curl_easy_init();
    if (!curl) { snprintf(error,error_size,"Cannot initialize FTP transport"); return CURLE_FAILED_INIT; }
    struct callbacks cb = {write, progress, context, operation == 2};
    char detail[CURL_ERROR_SIZE] = {0};
    FILE *file = NULL;
    struct curl_slist *commands = NULL;
    curl_easy_setopt(curl, CURLOPT_URL, url);
    curl_easy_setopt(curl, CURLOPT_USERNAME, user);
    curl_easy_setopt(curl, CURLOPT_PASSWORD, password ? password : "");
    curl_easy_setopt(curl, CURLOPT_PROTOCOLS_STR, "ftp");
    curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 0L);
    /* Never consult ambient proxy credentials or send an FTP password to a proxy. */
    curl_easy_setopt(curl, CURLOPT_PROXY, "");
    curl_easy_setopt(curl, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(curl, CURLOPT_CONNECTTIMEOUT_MS, (long)(timeout * 1000));
    curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, (long)(timeout * 1000));
    curl_easy_setopt(curl, CURLOPT_FTP_RESPONSE_TIMEOUT, (long)timeout);
    curl_easy_setopt(curl, CURLOPT_USE_SSL, tls ? (long)CURLUSESSL_ALL : (long)CURLUSESSL_NONE);
    curl_easy_setopt(curl, CURLOPT_FTPSSLAUTH, (long)CURLFTPAUTH_TLS);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 2L);
    curl_easy_setopt(curl, CURLOPT_SSLVERSION, (long)CURL_SSLVERSION_TLSv1_2);
    curl_easy_setopt(curl, CURLOPT_ERRORBUFFER, detail);
    curl_easy_setopt(curl, CURLOPT_XFERINFOFUNCTION, update);
    curl_easy_setopt(curl, CURLOPT_XFERINFODATA, &cb);
    curl_easy_setopt(curl, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, output);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &cb);
    if (operation == 0) curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "MLSD");
    if (operation == 1 && offset) curl_easy_setopt(curl, CURLOPT_RESUME_FROM_LARGE, (curl_off_t)offset);
    if (operation == 2) {
        file = fopen(local_path, "rb");
        if (!file) { snprintf(error,error_size,"Cannot open upload source"); curl_easy_cleanup(curl); return CURLE_READ_ERROR; }
        struct stat info;
        if (fstat(fileno(file), &info) != 0 || !S_ISREG(info.st_mode)) {
            fclose(file); curl_easy_cleanup(curl); snprintf(error,error_size,"Upload source must be a regular file"); return CURLE_READ_ERROR;
        }
        curl_easy_setopt(curl, CURLOPT_UPLOAD, 1L);
        curl_easy_setopt(curl, CURLOPT_READDATA, file);
        curl_easy_setopt(curl, CURLOPT_INFILESIZE_LARGE, (curl_off_t)info.st_size);
    }
    if (operation == 3) {
        curl_easy_setopt(curl, CURLOPT_NOBODY, 1L);
        if (command1) commands = curl_slist_append(commands, command1);
        if (command2) commands = curl_slist_append(commands, command2);
        curl_easy_setopt(curl, CURLOPT_QUOTE, commands);
    }
    CURLcode result = curl_easy_perform(curl);
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, response);
    if (result) snprintf(error,error_size,"%s", detail[0] ? detail : curl_easy_strerror(result));
    curl_slist_free_all(commands);
    if (file) fclose(file);
    curl_easy_cleanup(curl);
    return (int)result;
}
