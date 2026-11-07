#include "CFarLua.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

#include <math.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

extern int luaopen_lpeg(lua_State *);

enum {
    MEMORY_LIMIT = 32 * 1024 * 1024,
    WIRE_LIMIT = 4 * 1024 * 1024,
    VALUE_LIMIT = 32768,
    MAX_DEPTH = 24,
    HOOK_INTERVAL = 1000,
    INSTRUCTION_LIMIT = 4000000,
    REFERENCE_LIMIT = 8192
};

enum wire_tag { W_NIL, W_FALSE, W_TRUE, W_INT, W_NUMBER, W_STRING, W_ARRAY, W_TABLE, W_REF };

struct far_lua {
    lua_State *state;
    size_t memory;
    uint8_t *output;
    size_t capacity;
    size_t length;
    char error[4096];
    const uint8_t *input;
    size_t remaining;
    unsigned nodes;
    unsigned reference_count;
    uint32_t created_references[REFERENCE_LIMIT];
    unsigned created_count;
    int packed_sizes;
    int action_instructions;
    uint64_t action_time;
    int references;
    int reference_ids;
    int dispatch;
    int instructions;
    bool exhausted;
    uint64_t deadline;
    const char *operation;
};

static const char reference_marker;
static _Atomic uint64_t next_reference = 0;
static const char moon_compiler[] =
#include "Vendor/moonscript/Compiler.inc"
;

static uint64_t now_ns(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

static void *allocate(void *ud, void *ptr, size_t old_size, size_t size) {
    far_lua *runtime = ud;
    if (!ptr) old_size = 0;
    if (size == 0) {
        free(ptr);
        runtime->memory -= old_size;
        return NULL;
    }
    if (size > MEMORY_LIMIT - runtime->memory + old_size) return NULL;
    void *result = realloc(ptr, size);
    if (result) runtime->memory = runtime->memory - old_size + size;
    return result;
}

static far_lua *runtime_for(lua_State *L) {
    void *ud = NULL;
    lua_getallocf(L, &ud);
    return ud;
}

// Some native pattern loops run without executing Lua instructions.
void far_lua_check_native_budget(lua_State *L) {
    far_lua *runtime = runtime_for(L);
    if (runtime->deadline && (runtime->exhausted || now_ns() >= runtime->deadline)) {
        runtime->exhausted = true;
        luaL_error(L, "Lua execution budget exceeded");
    }
}

static void instruction_hook(lua_State *L, lua_Debug *ar) {
    (void)ar;
    far_lua *runtime = runtime_for(L);
    runtime->instructions -= HOOK_INTERVAL;
    if (runtime->exhausted || runtime->instructions <= 0 || now_ns() >= runtime->deadline) {
        runtime->exhausted = true;
        luaL_error(L, "Lua execution budget exceeded");
    }
}

static int check_budget(lua_State *L) {
    if (runtime_for(L)->exhausted) return luaL_error(L, "Lua execution budget exceeded");
    return 0;
}

static void take(lua_State *L, far_lua *runtime, void *output, size_t size) {
    if (size > runtime->remaining) luaL_error(L, "Truncated Lua bridge input");
    if (size) {
        memcpy(output, runtime->input, size);
        runtime->input += size;
        runtime->remaining -= size;
    }
}

static uint64_t read_unsigned(lua_State *L, far_lua *runtime, size_t size) {
    uint8_t bytes[8];
    take(L, runtime, bytes, size);
    uint64_t result = 0;
    for (size_t i = 0; i < size; i++) result |= (uint64_t)bytes[i] << (8 * i);
    return result;
}

static void check_node(lua_State *L, far_lua *runtime, unsigned depth) {
    if (depth >= MAX_DEPTH || ++runtime->nodes > VALUE_LIMIT || !lua_checkstack(L, 8)) {
        luaL_error(L, "Lua bridge value is too deeply nested or large");
    }
}

static void record_packed_size(lua_State *L, far_lua *runtime, lua_Integer count) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, runtime->packed_sizes);
    lua_pushvalue(L, -2);
    lua_pushinteger(L, count);
    lua_rawset(L, -3);
    lua_pop(L, 1);
}

static lua_Integer get_packed_size(lua_State *L, far_lua *runtime, int index) {
    index = lua_absindex(L, index);
    lua_rawgeti(L, LUA_REGISTRYINDEX, runtime->packed_sizes);
    lua_pushvalue(L, index);
    lua_rawget(L, -2);
    lua_Integer size = lua_isinteger(L, -1) ? lua_tointeger(L, -1) : -1;
    lua_pop(L, 2);
    return size;
}

static void read_value(lua_State *L, far_lua *runtime, unsigned depth) {
    check_node(L, runtime, depth);
    uint64_t tag = read_unsigned(L, runtime, 1);
    switch (tag) {
        case W_NIL: lua_pushnil(L); break;
        case W_FALSE: case W_TRUE: lua_pushboolean(L, tag == W_TRUE); break;
        case W_INT: {
            uint64_t bits = read_unsigned(L, runtime, 8);
            int64_t integer;
            memcpy(&integer, &bits, sizeof(integer));
            lua_pushinteger(L, integer);
            break;
        }
        case W_NUMBER: {
            uint64_t bits = read_unsigned(L, runtime, 8);
            double number;
            memcpy(&number, &bits, sizeof(number));
            lua_pushnumber(L, number);
            break;
        }
        case W_STRING: {
            size_t length = read_unsigned(L, runtime, 4);
            if (length > runtime->remaining) luaL_error(L, "Truncated Lua bridge string");
            lua_pushlstring(L, (const char *)runtime->input, length);
            runtime->input += length;
            runtime->remaining -= length;
            break;
        }
        case W_ARRAY: case W_TABLE: {
            uint64_t count = read_unsigned(L, runtime, 4);
            if (count > VALUE_LIMIT) luaL_error(L, "Lua bridge collection is too large");
            lua_createtable(L, tag == W_ARRAY ? (int)count : 0, tag == W_TABLE ? (int)count : 0);
            for (uint64_t i = 0; i < count; i++) {
                if (tag == W_ARRAY) {
                    read_value(L, runtime, depth + 1);
                    lua_rawseti(L, -2, (lua_Integer)i + 1);
                } else {
                    read_value(L, runtime, depth + 1);
                    if (lua_type(L, -1) != LUA_TSTRING) luaL_error(L, "Expected Lua table field name");
                    read_value(L, runtime, depth + 1);
                    lua_rawset(L, -3);
                }
            }
            if (tag == W_ARRAY) {
                // Payload arrays preserve trailing nils for calls and returns.
                record_packed_size(L, runtime, (lua_Integer)count);
            }
            break;
        }
        case W_REF: {
            lua_Integer reference = (lua_Integer)read_unsigned(L, runtime, 4);
            lua_rawgeti(L, LUA_REGISTRYINDEX, runtime->references);
            lua_rawgeti(L, -1, reference);
            lua_remove(L, -2);
            if (lua_isnil(L, -1)) luaL_error(L, "Invalid or released Lua reference");
            break;
        }
        default: luaL_error(L, "Unknown Lua bridge type");
    }
}

static void write_bytes(lua_State *L, far_lua *runtime, const void *data, size_t length) {
    if (length > WIRE_LIMIT - runtime->length) luaL_error(L, "Lua bridge result is too large");
    size_t needed = runtime->length + length;
    if (needed > runtime->capacity) {
        size_t capacity = runtime->capacity ? runtime->capacity : 1024;
        while (capacity < needed) capacity *= 2;
        uint8_t *output = realloc(runtime->output, capacity);
        if (!output) luaL_error(L, "Could not allocate Lua bridge result");
        runtime->output = output;
        runtime->capacity = capacity;
    }
    if (length) memcpy(runtime->output + runtime->length, data, length);
    runtime->length = needed;
}

static void write_unsigned(lua_State *L, far_lua *runtime, uint64_t value, size_t size) {
    uint8_t bytes[8];
    for (size_t i = 0; i < size; i++) bytes[i] = (uint8_t)(value >> (8 * i));
    write_bytes(L, runtime, bytes, size);
}

static bool valid_utf8(const unsigned char *bytes, size_t length) {
    size_t index = 0;
    while (index < length) {
        unsigned first = bytes[index++];
        if (first < 0x80) continue;
        unsigned rest, minimum = 0x80, maximum = 0xbf;
        if (first >= 0xc2 && first <= 0xdf) {
            rest = 1;
        } else if (first >= 0xe0 && first <= 0xef) {
            rest = 2;
            if (first == 0xe0) minimum = 0xa0;
            if (first == 0xed) maximum = 0x9f;
        } else if (first >= 0xf0 && first <= 0xf4) {
            rest = 3;
            if (first == 0xf0) minimum = 0x90;
            if (first == 0xf4) maximum = 0x8f;
        } else {
            return false;
        }
        if (rest > length - index || bytes[index] < minimum || bytes[index] > maximum) return false;
        index++;
        for (unsigned i = 1; i < rest; i++) {
            if (bytes[index] < 0x80 || bytes[index] > 0xbf) return false;
            index++;
        }
    }
    return true;
}

static void write_value(lua_State *L, far_lua *runtime, int index, unsigned depth);

static void write_table(lua_State *L, far_lua *runtime, int index, unsigned depth) {
    lua_rawgetp(L, index, &reference_marker);
    if (lua_isinteger(L, -1)) {
        write_unsigned(L, runtime, W_REF, 1);
        write_unsigned(L, runtime, (uint64_t)lua_tointeger(L, -1), 4);
        lua_pop(L, 1);
        return;
    }
    lua_pop(L, 1);

    lua_Integer explicit_count = get_packed_size(L, runtime, index);
    bool packed = explicit_count >= 0;

    lua_Integer length = packed ? explicit_count : (lua_Integer)lua_rawlen(L, index);
    bool array = packed || length > 0;
    bool dictionary = true;
    size_t count = 0;
    if (!packed) {
        lua_pushnil(L);
        while (lua_next(L, index)) {
            int type = lua_type(L, -2);
            lua_Integer key = lua_tointeger(L, -2);
            array = array && lua_isinteger(L, -2) && key > 0 && key <= length;
            dictionary = dictionary && type == LUA_TSTRING;
            lua_pop(L, 1);
            if (++count > VALUE_LIMIT) luaL_error(L, "Lua result table is too large");
        }
        array = array && length == (lua_Integer)count;
    }
    if (array) {
        if (length > VALUE_LIMIT) luaL_error(L, "Lua result array is too large");
        write_unsigned(L, runtime, W_ARRAY, 1);
        write_unsigned(L, runtime, (uint64_t)length, 4);
        for (lua_Integer i = 1; i <= length; i++) {
            lua_rawgeti(L, index, i);
            write_value(L, runtime, -1, depth + 1);
            lua_pop(L, 1);
        }
    } else if (dictionary) {
        write_unsigned(L, runtime, W_TABLE, 1);
        write_unsigned(L, runtime, count, 4);
        lua_pushnil(L);
        while (lua_next(L, index)) {
            write_value(L, runtime, -2, depth + 1);
            write_value(L, runtime, -1, depth + 1);
            lua_pop(L, 1);
        }
    } else {
        luaL_error(L, "Lua result table requires string fields or consecutive array indexes");
    }
}

static void write_value(lua_State *L, far_lua *runtime, int index, unsigned depth) {
    check_node(L, runtime, depth);
    index = lua_absindex(L, index);
    int type = lua_type(L, index);
    if (type == LUA_TTABLE || type == LUA_TUSERDATA || type == LUA_TLIGHTUSERDATA || type == LUA_TFUNCTION) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, runtime->reference_ids);
        lua_pushvalue(L, index);
        lua_rawget(L, -2);
        lua_Integer reference = lua_tointeger(L, -1);
        lua_pop(L, 2);
        if (reference > 0) {
            write_unsigned(L, runtime, W_REF, 1);
            write_unsigned(L, runtime, (uint64_t)reference, 4);
            return;
        }
    }
    switch (type) {
        case LUA_TNIL: write_unsigned(L, runtime, W_NIL, 1); break;
        case LUA_TBOOLEAN: write_unsigned(L, runtime, lua_toboolean(L, index) ? W_TRUE : W_FALSE, 1); break;
        case LUA_TNUMBER:
            if (lua_isinteger(L, index)) {
                write_unsigned(L, runtime, W_INT, 1);
                write_unsigned(L, runtime, (uint64_t)lua_tointeger(L, index), 8);
            } else {
                double number = lua_tonumber(L, index);
                uint64_t bits;
                memcpy(&bits, &number, sizeof(bits));
                write_unsigned(L, runtime, W_NUMBER, 1);
                write_unsigned(L, runtime, bits, 8);
            }
            break;
        case LUA_TSTRING: {
            size_t length;
            const char *value = lua_tolstring(L, index, &length);
            if (length > WIRE_LIMIT) luaL_error(L, "Lua bridge string is too large");
            if (!valid_utf8((const unsigned char *)value, length)) luaL_error(L, "Lua host text must be valid UTF-8");
            write_unsigned(L, runtime, W_STRING, 1);
            write_unsigned(L, runtime, length, 4);
            write_bytes(L, runtime, value, length);
            break;
        }
        case LUA_TTABLE: write_table(L, runtime, index, depth); break;
        default: luaL_error(L, "Unsupported Lua bridge value type: %s", luaL_typename(L, index));
    }
}

static int pack(lua_State *L) {
    int count = lua_gettop(L);
    lua_createtable(L, count, 0);
    for (int i = 1; i <= count; i++) {
        lua_pushvalue(L, i);
        lua_rawseti(L, -2, i);
    }
    record_packed_size(L, runtime_for(L), count);
    return 1;
}

static int packed_count(lua_State *L) {
    luaL_checktype(L, 1, LUA_TTABLE);
    lua_Integer count = get_packed_size(L, runtime_for(L), 1);
    lua_pushinteger(L, count < 0 ? (lua_Integer)lua_rawlen(L, 1) : count);
    return 1;
}

static int reference_value(lua_State *L, bool scalar) {
    far_lua *runtime = runtime_for(L);
    int type = lua_type(L, 1);
    bool complex = type == LUA_TTABLE || type == LUA_TFUNCTION || type == LUA_TUSERDATA;
    if (!complex && (!scalar || !lua_toboolean(L, 1))) {
        lua_settop(L, 1);
        return 1;
    }
    if (runtime->reference_count == REFERENCE_LIMIT || runtime->created_count == REFERENCE_LIMIT) {
        return luaL_error(L, "Too many open Lua references");
    }
    uint64_t reference = atomic_fetch_add_explicit(&next_reference, 1, memory_order_relaxed) + 1;
    if (reference > UINT32_MAX) return luaL_error(L, "Lua reference IDs exhausted");
    runtime->created_references[runtime->created_count++] = (uint32_t)reference;
    lua_rawgeti(L, LUA_REGISTRYINDEX, runtime->references);
    lua_pushvalue(L, 1);
    lua_rawseti(L, -2, reference);
    runtime->reference_count++;
    if (complex) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, runtime->reference_ids);
        lua_pushvalue(L, 1);
        lua_pushinteger(L, reference);
        lua_rawset(L, -3);
        lua_pop(L, 1);
    }
    lua_createtable(L, 0, 1);
    lua_pushinteger(L, reference);
    lua_rawsetp(L, -2, &reference_marker);
    return 1;
}

static int make_reference(lua_State *L) { return reference_value(L, false); }
static int make_open_reference(lua_State *L) { return reference_value(L, true); }

static void release_id(lua_State *L, far_lua *runtime, lua_Integer reference) {
    lua_rawgeti(L, LUA_REGISTRYINDEX, runtime->references);
    lua_rawgeti(L, -1, reference);
    if (!lua_isnil(L, -1)) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, runtime->reference_ids);
        lua_pushvalue(L, -2);
        lua_rawget(L, -2);
        lua_Integer reverse = lua_tointeger(L, -1);
        lua_pop(L, 1);
        if (reverse == reference) {
            lua_pushvalue(L, -2);
            lua_pushnil(L);
            lua_rawset(L, -3);
        }
        lua_pop(L, 2);
        lua_pushnil(L);
        lua_rawseti(L, -2, reference);
        runtime->reference_count--;
    } else {
        lua_pop(L, 1);
    }
    lua_pop(L, 1);
}

static int release_reference(lua_State *L) {
    release_id(L, runtime_for(L), luaL_checkinteger(L, 1));
    return 0;
}

static int rollback_references(lua_State *L) {
    far_lua *runtime = runtime_for(L);
    for (unsigned i = 0; i < runtime->created_count; i++) {
        release_id(L, runtime, runtime->created_references[i]);
    }
    return 0;
}

static int make_panel_handle(lua_State *L) {
    lua_settop(L, 0);
    lua_newuserdatauv(L, 1, 0);
    return make_reference(L);
}

static int initialize(lua_State *L) {
    far_lua *runtime = runtime_for(L);
    luaL_requiref(L, "_G", luaopen_base, 1); lua_pop(L, 1);
    luaL_requiref(L, LUA_LOADLIBNAME, luaopen_package, 1); lua_pop(L, 1);
    luaL_requiref(L, LUA_COLIBNAME, luaopen_coroutine, 1); lua_pop(L, 1);
    luaL_requiref(L, LUA_TABLIBNAME, luaopen_table, 1); lua_pop(L, 1);
    luaL_requiref(L, LUA_STRLIBNAME, luaopen_string, 1); lua_pop(L, 1);
    luaL_requiref(L, LUA_MATHLIBNAME, luaopen_math, 1); lua_pop(L, 1);
    luaL_requiref(L, LUA_UTF8LIBNAME, luaopen_utf8, 1); lua_pop(L, 1);
    luaL_requiref(L, LUA_OSLIBNAME, luaopen_os, 1); lua_pop(L, 1);
    luaL_requiref(L, LUA_DBLIBNAME, luaopen_debug, 1); lua_pop(L, 1);
    luaL_requiref(L, "lpeg", luaopen_lpeg, 0); lua_pop(L, 1);

    // The compiler can resolve only built-in preloads. Remove disk/native
    // package searchers before any MoonScript module executes.
    lua_getglobal(L, "package");
    lua_getfield(L, -1, "searchers");
    for (int i = 2; i <= 4; i++) {
        lua_pushnil(L);
        lua_rawseti(L, -2, i);
    }
    lua_pop(L, 2);
    if (luaL_loadbufferx(L, moon_compiler, sizeof(moon_compiler) - 1, "=MoonScript compiler", "t") != LUA_OK) {
        return lua_error(L);
    }
    lua_call(L, 0, 0);

    if (luaL_loadbufferx(L, (const char *)runtime->input, runtime->remaining, "=FarForMac Lua host", "t") != LUA_OK) {
        return lua_error(L);
    }
    lua_newtable(L);
    lua_pushcfunction(L, pack); lua_setfield(L, -2, "pack");
    lua_pushcfunction(L, packed_count); lua_setfield(L, -2, "count");
    lua_pushcfunction(L, make_reference); lua_setfield(L, -2, "reference");
    lua_pushcfunction(L, make_open_reference); lua_setfield(L, -2, "openReference");
    lua_pushcfunction(L, make_panel_handle); lua_setfield(L, -2, "panelHandle");
    lua_pushcfunction(L, release_reference); lua_setfield(L, -2, "releaseReference");
    lua_pushcfunction(L, check_budget); lua_setfield(L, -2, "checkBudget");
    lua_call(L, 1, 1);
    luaL_checktype(L, -1, LUA_TFUNCTION);
    runtime->dispatch = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_newtable(L);
    runtime->references = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_newtable(L);
    runtime->reference_ids = luaL_ref(L, LUA_REGISTRYINDEX);
    lua_newtable(L);
    lua_newtable(L);
    lua_pushliteral(L, "k");
    lua_setfield(L, -2, "__mode");
    lua_setmetatable(L, -2);
    runtime->packed_sizes = luaL_ref(L, LUA_REGISTRYINDEX);
    return 0;
}

static int dispatch(lua_State *L) {
    far_lua *runtime = runtime_for(L);
    lua_rawgeti(L, LUA_REGISTRYINDEX, runtime->dispatch);
    lua_pushstring(L, runtime->operation);
    read_value(L, runtime, 0);
    if (runtime->remaining != 0) return luaL_error(L, "Unexpected Lua bridge data");
    lua_call(L, 2, 1);
    runtime->nodes = 0;
    write_value(L, runtime, -1, 0);
    return 0;
}

far_lua *far_lua_create(const uint8_t *bootstrap, size_t length) {
    far_lua *runtime = calloc(1, sizeof(*runtime));
    if (!runtime) return NULL;
    runtime->state = lua_newstate(allocate, runtime);
    if (!runtime->state) {
        free(runtime);
        return NULL;
    }
    runtime->input = bootstrap;
    runtime->remaining = length;
    lua_pushcfunction(runtime->state, initialize);
    if (lua_pcall(runtime->state, 0, 0, 0) != LUA_OK) {
        const char *message = lua_type(runtime->state, -1) == LUA_TSTRING ? lua_tostring(runtime->state, -1) : NULL;
        snprintf(runtime->error, sizeof(runtime->error), "%s", message ? message : "Could not initialize Lua");
    }
    runtime->input = NULL;
    lua_settop(runtime->state, 0);
    return runtime;
}

void far_lua_destroy(far_lua *runtime) {
    if (!runtime) return;
    lua_close(runtime->state);
    free(runtime->output);
    free(runtime);
}

int far_lua_call(far_lua *runtime, const char *operation, const uint8_t *input, size_t length) {
    lua_State *L = runtime->state;
    runtime->length = 0;
    runtime->error[0] = '\0';
    runtime->operation = operation;
    runtime->input = input;
    runtime->remaining = length;
    runtime->nodes = 0;
    runtime->created_count = 0;
    bool action = strcmp(operation, "start") == 0 || strcmp(operation, "export") == 0
                  || strcmp(operation, "chunk") == 0;
    bool resume = strcmp(operation, "resume") == 0;
    if (action) {
        runtime->action_instructions = INSTRUCTION_LIMIT;
        runtime->action_time = 500000000;
    }
    runtime->instructions = action || resume ? runtime->action_instructions : INSTRUCTION_LIMIT;
    uint64_t started = now_ns();
    uint64_t time = 250000000;
    if ((action || resume) && runtime->action_time < time) time = runtime->action_time;
    runtime->exhausted = false;
    runtime->deadline = started + time;
    if (time == 0 || runtime->instructions <= 0) {
        snprintf(runtime->error, sizeof(runtime->error), "Lua execution budget exceeded");
        runtime->deadline = 0;
        runtime->input = NULL;
        runtime->operation = NULL;
        return 0;
    }
    lua_sethook(L, instruction_hook, LUA_MASKCOUNT, HOOK_INTERVAL);
    lua_pushcfunction(L, dispatch);
    int status = lua_pcall(L, 0, 0, 0);
    lua_sethook(L, NULL, 0, 0);
    runtime->deadline = 0;
    if (action || resume) {
        uint64_t elapsed = now_ns() - started;
        runtime->action_time = elapsed >= runtime->action_time ? 0 : runtime->action_time - elapsed;
        runtime->action_instructions = runtime->instructions;
    }
    if (status != LUA_OK) {
        const char *message = lua_type(L, -1) == LUA_TSTRING ? lua_tostring(L, -1) : NULL;
        snprintf(runtime->error, sizeof(runtime->error), "%s", message ? message : "Lua execution failed");
        runtime->length = 0;
    }
    lua_settop(L, 0);
    if (status != LUA_OK && runtime->created_count > 0) {
        lua_pushcfunction(L, rollback_references);
        (void)lua_pcall(L, 0, 0, 0);
        lua_settop(L, 0);
    }
    runtime->created_count = 0;
    runtime->input = NULL;
    runtime->operation = NULL;
    return status == LUA_OK;
}

const uint8_t *far_lua_output(const far_lua *runtime) { return runtime->output; }
size_t far_lua_output_length(const far_lua *runtime) { return runtime->length; }
const char *far_lua_error(const far_lua *runtime) { return runtime->error; }
