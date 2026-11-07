#ifndef CFARLUA_H
#define CFARLUA_H

#include <stddef.h>
#include <stdint.h>

typedef struct far_lua far_lua;

far_lua *far_lua_create(const uint8_t *bootstrap, size_t length);
void far_lua_destroy(far_lua *runtime);
int far_lua_call(far_lua *runtime, const char *operation, const uint8_t *input, size_t length);
const uint8_t *far_lua_output(const far_lua *runtime);
size_t far_lua_output_length(const far_lua *runtime);
const char *far_lua_error(const far_lua *runtime);

#endif
