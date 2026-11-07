// The bootstrap runs in Lua. Only its dispatcher and the MoonScript compiler
// can access the full standard environment.
enum FarLuaBootstrap {
    static let source = #"""
local native = ...
local pack, count = native.pack, native.count
local unpack, rawResume = table.unpack, coroutine.resume
local traceback = debug.traceback
local compileMoon = require("moonscript.base").to_lua
local lpeg = require("lpeg")
-- LuaFar also exposes cfind as a method on strings.
string.cfind = string.find
local registry, exports, menuIDs, ids, modules = {}, {}, {}, {}, {}
local pending, loaded, current, phase, active, keyName, hostCalls, startupInfo
local hostYield, hostExit = {}, {}
local areaNames = {
  "Other", "Shell", "Viewer", "Editor", "Dialog", "Search", "Disks", "MainMenu",
  "Menu", "Help", "Info", "QView", "Tree", "FindFolder", "UserMenu",
  "ShellAutoCompletion", "DialogAutoCompletion", "Grabber", "Desktop", "Common"
}
local areaSet, groupSet = {}, {}
for _, name in ipairs(areaNames) do areaSet[name:lower()] = true end
for _, group in ipairs({
  "dialogevent", "editorevent", "editorinput", "exitfar", "viewerevent", "consoleinput", "folderchanged"
}) do groupSet[group] = true end

local function unpackAll(values)
  return unpack(values, 1, count(values))
end

local function checkedResume(thread, ...)
  local results = pack(rawResume(thread, ...))
  native.checkBudget()
  while results[1] and (results[2] == hostYield or results[2] == hostExit) do
    results = pack(rawResume(thread, coroutine.yield(unpack(results, 2, count(results)))))
    native.checkBudget()
  end
  return unpackAll(results)
end

local function checkedCall(call, ...)
  local result = pack(call(...))
  native.checkBudget()
  return unpackAll(result)
end

local function host(name, ...)
  if phase == "condition" or phase == "load" then
    for _, call in ipairs(current.queryCalls or {}) do
      if call.name == name and count(call.arguments) == select("#", ...) then
        local matches = true
        for i = 1, count(call.arguments) do
          if call.arguments[i] ~= select(i, ...) then matches = false; break end
        end
        if matches then return unpackAll(call.results) end
      end
    end
    local result = current.queries[name]
    if result ~= nil then return result end
  end
  if phase ~= "action" then
    error(name .. " is unavailable during Lua registration or condition evaluation", 2)
  end
  hostCalls = hostCalls + 1
  if hostCalls > 100000 then error("Lua host request limit exceeded", 2) end
  local success, results = coroutine.yield(hostYield, { name = name, arguments = pack(...) })
  if not success then error(results, 2) end
  return unpackAll(results)
end

local function keys(...)
  for i = 1, select("#", ...) do
    local s = select(i, ...)
    if type(s) == "string" then
      for token in s:gmatch("%S+") do
        local repetitions, name = token:match("^(%d+)%*(.+)$")
        repetitions, name = tonumber(repetitions) or 1, name or token
        if repetitions > 4096 then error("Lua key repeat limit exceeded", 2) end
        for _ = 1, repetitions do host("Keys", name) end
      end
    end
  end
end

local function words(s, separators)
  local result, seen = {}, {}
  if type(s) == "string" then
    for word in s:gmatch(separators or "%S+") do
      if not seen[word:lower()] then
        seen[word:lower()] = true
        result[#result + 1] = word
      end
    end
  end
  return result
end

local function stringField(value)
  if type(value) == "string" then return value end
end

local function priority(value)
  if type(value) ~= "number" or value ~= value then return 50 end
  return math.max(0, math.min(100, value))
end

local function functionField(value)
  if type(value) == "function" then return value end
end

local function uuid(value)
  if type(value) ~= "string" then return nil end
  value = value:gsub("^{(.*)}$", "%1")
  if #value == 36 and value:match("^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x+$") then
    return value:upper()
  end
end

local function compile(source, name, language, env)
  if source:sub(1, 3) == "\239\187\191" then source = source:sub(4) end
  if source:sub(1, 2) == "#!" then source = source:gsub("^[^\n]*", "", 1) end
  if language == "moonScript" then
    local compiled, err = compileMoon(source)
    if not compiled then return nil, name .. ": " .. err end
    source = compiled
  end
  return load(source, "@" .. name, "t", env)
end

local function register(kind, declaration, env)
  if phase ~= "load" then error(kind .. " can only be registered while loading a script", 2) end
  if type(declaration) ~= "table" then return false end
  local name = pending.name
  local action = functionField(declaration.action)
  local condition = functionField(declaration.condition)
  local rawAreas = words(declaration.area)
  local areas = {}
  for _, area in ipairs(rawAreas) do
    if areaSet[area:lower()] then areas[#areas + 1] = area end
  end
  local data = {
    id = #registry + #pending.entries + 1, kind = kind, name = name,
    description = stringField(declaration.description) or "",
    areas = areas, keys = {}, flags = {}, priority = priority(declaration.priority),
    filemask = stringField(declaration.filemask), scriptID = stringField(declaration.id)
  }
  if kind == "macro" then
    if #areas == 0 then return false end
    local key = stringField(declaration.key)
    if key and key:match("^/.+/$") then data.keys = { key }
    else data.keys = words(key) end
    data.flags = words(declaration.flags, "[^ |%s]+")
    if not action and type(declaration.code) == "string" then
      if declaration.code:sub(1, 1) == "@" then
        error(name .. ": loading a separate macro code file is unavailable", 2)
      end
      local language = declaration.language == "moonscript" and "moonScript" or "lua"
      action = assert(compile(declaration.code, name, language, env))
    end
    action = action or function() end
  elseif kind == "event" then
    local group = stringField(declaration.group)
    if not action or not group or not groupSet[group:lower()] then return false end
    data.group = group:lower()
  else
    data.menu = stringField(declaration.menu)
    data.guid = uuid(declaration.guid)
    data.text = stringField(declaration.text)
    if not action or not data.menu or not data.guid or
       (not data.text and type(declaration.text) ~= "function") or
       menuIDs[data.guid] or pending.menuIDs[data.guid] then return false end
    pending.menuIDs[data.guid] = true
  end
  if data.scriptID and #data.scriptID > 0 then
    local id = data.scriptID:lower()
    if ids[id] or pending.ids[id] then data.scriptID = nil
    else pending.ids[id] = true end
  end
  if #registry + #pending.entries >= 1024 then error("Lua declaration limit exceeded", 2) end
  local fields = {}
  for k, v in pairs(declaration) do fields[k] = v end
  data.areas, data.keys, data.flags = pack(unpack(areas)), pack(unpack(data.keys)), pack(unpack(data.flags))
  pending.entries[#pending.entries + 1] = {
    data = data, fields = fields, condition = condition, action = action,
    text = functionField(declaration.text)
  }
  return true
end

local function copy(source)
  local result = {}
  for k, v in pairs(source) do result[k] = v end
  return result
end

local namespaces = {
  editor = true, panel = true, viewer = true, far = true, Plugin = true, mf = true,
  win = true, Dialog = true, Menu = true, Dlg = true, Object = true, Far = true, Panel = true
}
local editorMethods = {
  DelLine = true, GetStr = true, InsStr = true, Pos = true, Sel = true,
  Set = true, SetStr = true, SetTitle = true, Undo = true
}
local methods = {
  mf = {
    akey = function(mode) return mode == 1 and (keyName or "") or 0 end,
    abs = math.abs, max = math.max, min = math.min, mod = math.fmod,
    asc = function(s) return utf8.codepoint(s) end,
    chr = utf8.char, len = utf8.len, string = tostring, float = tonumber,
    int = function(value) return math.modf(tonumber(value) or 0) end,
    lcase = string.lower, ucase = string.upper,
    iif = function(value, yes, no)
      if value and value ~= 0 and value ~= "" then return yes end
      return no
    end
  },
  win = { Uuid = uuid }
}
local propertyTables = { APanel = true, PPanel = true, CmdLine = true, Area = true,
  Editor = true, Viewer = true, Far = true, Mouse = true, Help = true, Drv = true }

local function foldBits(operation, first, ...)
  local value = math.tointeger(first) or error("bit64 requires integer arguments", 3)
  for i = 1, select("#", ...) do value = operation(value, select(i, ...)) end
  return value
end

local bit64 = {
  band = function(...) return foldBits(function(a, b) return a & b end, ...) end,
  bor = function(...) return foldBits(function(a, b) return a | b end, ...) end,
  bxor = function(...) return foldBits(function(a, b) return a ~ b end, ...) end,
  bnot = function(value) return ~value end,
  lshift = function(value, amount) return value << amount end,
  rshift = function(value, amount) return value >> amount end
}

local function namespace(name)
  local api = copy(methods[name] or {})
  return setmetatable(api, {
    __index = function(_, method)
      local fields = current.globals[name]
      if type(fields) == "table" and fields[method] ~= nil then return fields[method] end
      if name == "far" and (method == "Flags" or method == "Colors") then return {} end
      if type(method) ~= "string" then return nil end
      return function(...) return host(name .. "." .. method, ...) end
    end,
    __metatable = false
  })
end

local function requireModule(name)
  if name == "lpeg" then return copy(lpeg) end
  if name == "bit64" then return copy(bit64) end
  local entry = modules[name]
  if not entry then error("Lua module is not installed: " .. tostring(name), 2) end
  if entry.value ~= nil then return entry.value end
  if entry.loading then error("Circular Lua module dependency: " .. name, 2) end
  entry.loading = true
  local result = pack(pcall(entry.chunk, name))
  entry.loading = false
  native.checkBudget()
  if not result[1] then error(result[2], 2) end
  entry.value = result[2]
  if entry.value == nil then entry.value = true end
  return entry.value
end

local function environment()
  local env = {
    _VERSION = _VERSION, assert = assert, error = error, ipairs = ipairs,
    next = next, pairs = pairs, rawequal = rawequal, rawget = rawget,
    rawlen = rawlen, rawset = rawset, select = select, tonumber = tonumber,
    tostring = tostring, type = type, unpack = unpack,
    setmetatable = setmetatable,
    getmetatable = function(value)
      if type(value) == "table" then return getmetatable(value) end
    end,
    pcall = function(...) return checkedCall(pcall, ...) end,
    xpcall = function(...) return checkedCall(xpcall, ...) end,
    string = copy(string), math = copy(math), table = copy(table), utf8 = copy(utf8),
    coroutine = copy(coroutine), bit64 = copy(bit64), export = {},
    os = { time = os.time, date = os.date, difftime = os.difftime, clock = os.clock },
    require = requireModule, package = { path = "", cpath = "" },
    Keys = keys,
    print = function(...)
      local value = ""
      if select("#", ...) > 0 then value = (...) end
      host("print", tostring(value))
    end,
    exit = function()
      if phase ~= "action" then error("exit is only available in a running Lua action", 2) end
      coroutine.yield(hostExit)
    end
  }
  env.coroutine.resume = checkedResume
  env.coroutine.wrap = function(fn)
    local thread = coroutine.create(fn)
    return function(...)
      local values = pack(checkedResume(thread, ...))
      if not values[1] then error(values[2], 2) end
      return unpack(values, 2, count(values))
    end
  end
  -- Chunks created by a script retain that script's environment and accept
  -- text only, including through the Lua 5.1 spelling loadstring.
  env.loadstring = function(source, name)
    if type(source) ~= "string" then error("Lua source must be text", 2) end
    return load(source, name, "t", env)
  end
  env.load = env.loadstring
  env.Macro = function(t) return register("macro", t, env) end
  env.Event = function(t) return register("event", t, env) end
  env.MenuItem = function(t) return register("menuItem", t, env) end
  env._G = env
  for name in pairs(namespaces) do env[name] = namespace(name) end
  env.far.PluginStartupInfo = function()
    if startupInfo then return copy(startupInfo) end
    return host("far.PluginStartupInfo")
  end
  for name in pairs(propertyTables) do
    if not namespaces[name] then
      env[name] = setmetatable({}, {
        __index = function(_, key)
          local fields = current.globals[name]
          if type(fields) == "table" and fields[key] ~= nil then return fields[key] end
          if name == "Editor" and editorMethods[key] then
            return function(...) return host("Editor." .. key, ...) end
          end
          if name == "Area" then
            if key == "Current" then return current.area end
            if type(key) == "string" and areaSet[key:lower()] then
              return current.area:lower() == key:lower()
            end
          end
        end,
        __metatable = false
      })
    end
  end
  return setmetatable(env, {
    __index = function(_, key) return current.globals[key] end,
    __metatable = false
  })
end

local function runLimited(fn, ...)
  local result = pack(xpcall(fn, function(message) return traceback(tostring(message), 2) end, ...))
  native.checkBudget()
  if not result[1] then error(result[2], 0) end
  return unpack(result, 2, count(result))
end

local function loadScript(payload)
  pending = { name = payload.name, entries = {}, ids = {}, menuIDs = {} }
  phase = "load"
  local env = environment()
  local chunk = assert(compile(payload.source, payload.name, payload.language, env))
  local result = runLimited(chunk, unpackAll(payload.arguments))
  local declarations, exportNames, newExports = {}, {}, copy(exports)
  local export = type(result) == "table" and result or env.export
  if type(export) == "table" then
    for name, action in pairs(export) do
      if type(name) == "string" and type(action) == "function" then
        if #exportNames >= 128 then error("Lua export limit exceeded") end
        newExports[name] = action
        exportNames[#exportNames + 1] = name
      end
    end
  end
  for _, entry in ipairs(pending.entries) do declarations[#declarations + 1] = entry.data end
  local newRegistry, newIDs, newMenuIDs = copy(registry), copy(ids), copy(menuIDs)
  for _, entry in ipairs(pending.entries) do newRegistry[#newRegistry + 1] = entry end
  for id in pairs(pending.ids) do newIDs[id] = true end
  for id in pairs(pending.menuIDs) do newMenuIDs[id] = true end
  loaded = { newRegistry, newIDs, newMenuIDs, newExports }
  return { definitions = pack(unpack(declarations)), exports = pack(unpack(exportNames)) }
end

local function condition(payload)
  local entry = assert(registry[payload.id], "Unknown Lua declaration")
  if not entry.condition then return true end
  phase = "condition"
  keyName = payload.key
  if entry.data.kind == "macro" then return runLimited(entry.condition, payload.key, entry.fields) end
  return runLimited(entry.condition, unpackAll(payload.arguments))
end

local function runCoroutine(...)
  phase = "action"
  local result = pack(rawResume(active, ...))
  native.checkBudget()
  if not result[1] then
    local message = traceback(active, tostring(result[2]))
    active = nil
    error(message, 0)
  end
  if result[2] == hostExit then active = nil; return { status = "finished", values = pack() } end
  if coroutine.status(active) == "dead" then
    active = nil
    return { status = "finished", values = pack(unpack(result, 2, count(result))) }
  end
  if result[2] ~= hostYield then
    active = nil
    error("Lua action yielded without a FAR host request", 0)
  end
  return { status = "request", request = result[3] }
end

local function start(payload, action, transform)
  assert(not active, "A Lua action is already running")
  hostCalls = 0
  keyName = payload.key
  active = coroutine.create(function(...)
    if transform then
      local result = pack(action(...))
      if count(result) > 0 then result[1] = transform(result[1]) end
      return unpackAll(result)
    end
    return action(...)
  end)
  return runCoroutine(unpackAll(payload.arguments))
end

return function(operation, payload)
  current = payload.snapshot
  phase = nil
  if operation == "startupInfo" then
    startupInfo = payload.properties
    return true
  elseif operation == "load" then
    loaded = nil
    local result = pack(pcall(loadScript, payload))
    pending = nil
    native.checkBudget()
    if not result[1] then error(result[2], 0) end
    return result[2]
  elseif operation == "commit" then
    assert(loaded, "No staged Lua script")
    registry, ids, menuIDs, exports = unpack(loaded)
    loaded = nil
    return true
  elseif operation == "discard" then
    loaded = nil
    return true
  elseif operation == "module" then
    local env = environment()
    modules[payload.name] = { chunk = assert(compile(payload.source, payload.name, payload.language, env)) }
    return true
  elseif operation == "condition" then
    local value = condition(payload)
    if type(value) == "number" then return priority(value) end
    return not not value
  elseif operation == "title" then
    local entry = assert(registry[payload.id], "Unknown Lua menu item")
    if entry.text then
      phase = "condition"
      return stringField(runLimited(entry.text, payload.menu, current.area))
    end
    return entry.data.text
  elseif operation == "start" then
    return start(payload, assert(registry[payload.id], "Unknown Lua declaration").action)
  elseif operation == "chunk" then
    local chunk = assert(compile(payload.source, payload.name, payload.language, environment()))
    return start(payload, chunk)
  elseif operation == "export" then
    local name = payload.export
    local transform
    if name == "Open" and payload.arguments[1] == 11 then
      transform = function(value)
        if type(value) == "table" and rawget(value, "type") == "panel" then
          return native.openReference(rawget(value, 1))
        end
        return value
      end
    elseif name == "Open" or name == "OpenFilePlugin" then
      transform = function(value)
        -- PANEL_STOP is an explicit non-macro Open result in LuaFar.
        if value == -1 then return value end
        return native.openReference(value)
      end
    elseif name == "GetFindData" then
      transform = function(value)
        if type(value) ~= "table" then return value end
        local items = {}
        for i = 1, #value do
          local item = value[i]
          if type(item) == "table" then
            local fields = copy(item)
            fields.UserData = native.reference(fields.UserData)
            items[i] = fields
          else items[i] = item end
        end
        return pack(unpack(items))
      end
    end
    return start(payload, assert(exports[name], "Unknown Lua export: " .. name), transform)
  elseif operation == "resume" then
    assert(active, "No Lua action is running")
    if payload.failure then return runCoroutine(false, payload.failure) end
    return runCoroutine(true, payload.arguments)
  elseif operation == "cancel" then
    active = nil
    return true
  elseif operation == "handle" then
    return native.panelHandle()
  elseif operation == "release" then
    native.releaseReference(payload.id)
    return true
  end
  error("Unknown Lua bridge operation: " .. operation)
end
"""#
}
