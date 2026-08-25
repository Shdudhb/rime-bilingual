-- Non-blocking Rime side of the V0.3 translation bridge.  Loading and
-- configuration happen only from component init.  Every typing callback is
-- limited to bounded in-memory work plus bridge try_submit/try_poll calls.

local M = {}

local PROTOCOL_VERSION = 2
local MAX_PAGE_SIZE = 20
local DEFAULT_ENDPOINT = "http://127.0.0.1:18081"
local DEFAULT_TIMEOUT_MS = 3000
local DEFAULT_RIME_SHA256 =
  "2D8F1BC3737635A11D9FB1BFCA4DC9E70533633930A8A0142A81CA879C39C45B"

-- A filter and a processor receive different env objects.  Keying the shared
-- state by engine gives both components one generation counter and page pair.
local states = setmetatable({}, { __mode = "k" })

local function configured_bool(config, path, default_value)
  local value = config:get_bool(path)
  if value == nil then
    return default_value
  end
  return value
end

local function configured_int(config, path, default_value)
  local value = config:get_int(path)
  if type(value) ~= "number" then
    return default_value
  end
  return value
end

local function warn_once(state, message)
  if state.warned then
    return
  end
  state.warned = true
  if log and log.warning then
    log.warning(message)
  end
end

local function disable(state, reason)
  state.enabled = false
  state.bridge = nil
  warn_once(state, "rime-bilingual async disabled: " .. reason)
end

local function clear_refs(state)
  state.refs_generation = nil
  state.refs_fingerprint = nil
  state.refs = {}
end

local function load_bridge(user_data_dir)
  if type(user_data_dir) ~= "string" or user_data_dir == "" then
    return nil, "user_data_dir_unavailable"
  end
  local base = user_data_dir:gsub("[\\/]$", "")
  local path = base .. "/rime-bilingual/native/rime_bilingual_bridge.dll"
  local ok, loader, load_error = pcall(
    package.loadlib,
    path,
    "luaopen_rime_bilingual_bridge"
  )
  if not ok or type(loader) ~= "function" then
    return nil, tostring(load_error or loader or "load_failed")
  end
  local opened, bridge = pcall(loader)
  if not opened or type(bridge) ~= "table" then
    return nil, "module_open_failed"
  end
  if type(bridge.configure) ~= "function"
      or type(bridge.try_submit) ~= "function"
      or type(bridge.try_poll) ~= "function" then
    return nil, "module_api_invalid"
  end
  return bridge
end

local function new_state(env)
  local config = env.engine.schema.config
  local state = {
    enabled = configured_bool(config, "rime_bilingual/async_enabled", true),
    bridge = nil,
    generation = 0,
    signature = nil,
    composition_input = nil,
    has_composition = nil,
    page = nil,
    expected_generation = nil,
    expected_fingerprint = nil,
    refs_generation = nil,
    refs_fingerprint = nil,
    refs = {},
    diagnostic_signature = nil,
    preserve_existing_comment = true,
    comment_prefix = "",
    comment_separator = " · ",
    dictionary = nil,
    cache = nil,
    update_connection = nil,
    skip_next_filter = false,
    warned = false,
  }
  states[env.engine] = state

  if not state.enabled then
    return state
  end
  local bridge, load_error = load_bridge(rime_api:get_user_data_dir())
  if bridge == nil then
    disable(state, "bridge_load_failed:" .. tostring(load_error))
    return state
  end
  local options = {
    protocol_version = PROTOCOL_VERSION,
    helper_endpoint = config:get_string("rime_bilingual/helper_endpoint")
      or DEFAULT_ENDPOINT,
    request_timeout_ms = configured_int(
      config,
      "rime_bilingual/request_timeout_ms",
      DEFAULT_TIMEOUT_MS
    ),
    queue_capacity = 8,
    completion_capacity = 32,
    expected_rime_sha256 = config:get_string(
      "rime_bilingual/expected_rime_sha256"
    ) or DEFAULT_RIME_SHA256,
  }
  local ok, result = pcall(bridge.configure, options)
  if not ok or type(result) ~= "table" or result.status ~= "ready" then
    disable(state, "bridge_configure_failed")
    return state
  end
  state.bridge = bridge
  return state
end

local function state_for(env)
  return states[env.engine] or new_state(env)
end

local function bounded_string(value)
  if type(value) ~= "string" or #value == 0 or #value > 256 then
    return false
  end
  for index = 1, #value do
    local byte = string.byte(value, index)
    if byte < 0x20 or byte == 0x7f then
      return false
    end
  end
  return true
end

local function candidate_identity(candidate, absolute_index)
  local text = candidate.text
  local kind = candidate.type
  local start_pos = candidate.start
  local end_pos = candidate._end
  if not bounded_string(text) or not bounded_string(kind)
      or type(start_pos) ~= "number" or type(end_pos) ~= "number"
      or start_pos < 0 or end_pos < start_pos then
    return nil
  end
  return {
    absolute_index = absolute_index,
    text = text,
    type = kind,
    start = start_pos,
    ["end"] = end_pos,
  }
end

local function frame_number(parts, value)
  parts[#parts + 1] = tostring(value)
  parts[#parts + 1] = ":"
end

local function frame_string(parts, value)
  frame_number(parts, #value)
  parts[#parts + 1] = value
  parts[#parts + 1] = ";"
end

local function page_signature(page)
  local parts = {}
  frame_number(parts, page.page_start)
  frame_number(parts, #page.candidates)
  for _, candidate in ipairs(page.candidates) do
    frame_number(parts, candidate.absolute_index)
    frame_string(parts, candidate.text)
    frame_string(parts, candidate.type)
    frame_number(parts, candidate.start)
    frame_number(parts, candidate["end"])
  end
  return table.concat(parts)
end

local function buffered_page(env, candidates, page_start)
  if type(candidates) ~= "table" or #candidates == 0
      or #candidates > MAX_PAGE_SIZE or type(page_start) ~= "number"
      or page_start < 0 then
    return nil, env.engine.context, false
  end
  local context = env.engine.context
  local composition = context and context.composition
  local has_composition = composition ~= nil and not composition:empty()
  local page = { page_start = page_start, candidates = {} }
  for slot, candidate in ipairs(candidates) do
    local identity = candidate_identity(candidate, page_start + slot - 1)
    if identity == nil then
      return nil, context, has_composition
    end
    page.candidates[#page.candidates + 1] = identity
  end
  return page, context, has_composition
end

local function menu_page(engine, context, page_start)
  local composition = context and context.composition
  if composition == nil or composition:empty() then
    return nil
  end
  local segment = composition:back()
  local menu = segment and segment.menu
  local page_size = engine.schema.page_size
  if menu == nil or type(page_size) ~= "number" or page_size < 1
      or page_size > MAX_PAGE_SIZE or type(page_start) ~= "number"
      or page_start < 0 then
    return nil
  end
  -- Page navigation in librime prepares the destination page before it updates
  -- selected_index.  This notifier path therefore only observes already
  -- materialized candidates; it must never call menu:prepare() itself.
  local available = menu:candidate_count()
  if type(available) ~= "number" or available <= page_start then
    return nil
  end
  local last = math.min(available, page_start + page_size) - 1
  local candidates = {}
  for absolute_index = page_start, last do
    local candidate = menu:get_candidate_at(absolute_index)
    if candidate == nil then
      return nil
    end
    candidates[#candidates + 1] = candidate
  end
  return candidates
end

local function update_generation(state, page, context, has_composition)
  local input = context.input or ""
  if page == nil then
    if state.signature ~= "no-page" or state.composition_input ~= input
        or state.has_composition ~= has_composition then
      state.generation = state.generation + 1
      state.signature = "no-page"
      state.composition_input = input
      state.has_composition = has_composition
      state.expected_generation = nil
      state.expected_fingerprint = nil
      clear_refs(state)
    end
    state.page = nil
    return
  end
  local signature = page_signature(page)
  if signature ~= state.signature or state.composition_input ~= input
      or state.has_composition ~= has_composition then
    state.generation = state.generation + 1
    state.signature = signature
    state.composition_input = input
    state.has_composition = has_composition
    state.expected_generation = nil
    state.expected_fingerprint = nil
    clear_refs(state)
  end
  page.generation = state.generation
  state.page = page
end

local function bridge_call(state, method, value)
  if not state.enabled or state.bridge == nil then
    return nil
  end
  local ok, result = pcall(state.bridge[method], value)
  if not ok or type(result) ~= "table" then
    disable(state, "bridge_runtime_failure")
    return nil
  end
  return result
end

local function log_poll_terminal(state, result)
  if result == nil or (result.status ~= "ready" and result.status ~= "failed") then
    return
  end
  local signature = table.concat({
    tostring(result.status),
    tostring(result.error or ""),
    tostring(result.generation or ""),
    tostring(result.fingerprint or ""),
  }, ":")
  if state.diagnostic_signature == signature then
    return
  end
  state.diagnostic_signature = signature
  if log and log.info then
    log.info(
      "[rime_bilingual] poll status=" .. tostring(result.status)
        .. " error=" .. tostring(result.error or "none")
        .. " generation=" .. tostring(result.generation or "none")
    )
  end
end

local function poll(state, page)
  if page == nil then
    return nil
  end
  local result = bridge_call(state, "try_poll", page)
  log_poll_terminal(state, result)
  if result == nil or result.status ~= "ready" then
    return nil
  end
  if result.generation ~= state.expected_generation
      or result.fingerprint ~= state.expected_fingerprint then
    return nil
  end
  if type(result.translations) ~= "table" then
    return nil
  end
  local translations = {}
  local previous_slot = -1
  for _, item in ipairs(result.translations) do
    if type(item) ~= "table" or type(item.slot) ~= "number"
        or item.slot <= previous_slot or item.slot < 0
        or item.slot >= #page.candidates or not bounded_string(item.text) then
      return nil
    end
    translations[item.slot] = item.text
    previous_slot = item.slot
  end
  return translations
end

local function translated_comment(existing, translation, state)
  local english = state.comment_prefix .. translation
  if state.preserve_existing_comment and existing ~= "" then
    local suffix = state.comment_separator .. english
    if existing == english or existing:sub(-#suffix) == suffix then
      return existing
    end
    return existing .. suffix
  end
  return english
end

local function apply_ready(state, page, translations)
  if translations == nil or state.refs_generation ~= page.generation
      or state.refs_generation ~= state.expected_generation
      or state.refs_fingerprint ~= state.expected_fingerprint then
    return
  end
  for slot, translation in pairs(translations) do
    local entry = state.refs[slot]
    local identity = entry and entry.identity
    local genuine = entry and entry.genuine
    if identity ~= nil and genuine ~= nil
        and page.candidates[slot + 1] == identity
        and genuine.text == identity.text and genuine.type == identity.type
        and genuine.start == identity.start and genuine._end == identity["end"] then
      local comment = translated_comment(entry.base_comment, translation, state)
      -- Repeated non-destructive polls must not append the same English again.
      if entry.applied_comment ~= comment or entry.genuine.comment ~= comment then
        entry.genuine.comment = comment
        entry.applied_comment = comment
      end
    end
  end
end

local function prepare_page(state, env, candidates, page_start, dictionary, cache)
  local ok, page, context, has_composition = pcall(
    buffered_page,
    env,
    candidates,
    page_start
  )
  if not ok then
    disable(state, "rime_page_api_failure")
    return nil, nil, nil
  end
  update_generation(state, page, context, has_composition)
  if page == nil then
    return nil, nil, nil
  end

  local translations = poll(state, page)
  local misses = {}
  for slot, candidate in ipairs(page.candidates) do
    if dictionary[candidate.text] == nil and cache[candidate.text] == nil then
      misses[#misses + 1] = { slot = slot - 1, text = candidate.text }
    end
  end
  return page, translations, misses
end

local function submit_page(state, page, misses)
  if page == nil or misses == nil or #misses == 0 then
    clear_refs(state)
    return false
  end
  local request = {
    generation = page.generation,
    page_start = page.page_start,
    candidates = page.candidates,
    misses = misses,
  }
  local result = bridge_call(state, "try_submit", request)
  if result ~= nil and (result.status == "accepted" or result.status == "duplicate")
      and result.generation == page.generation
      and type(result.fingerprint) == "string" then
    state.expected_generation = result.generation
    state.expected_fingerprint = result.fingerprint
    state.refs_generation = result.generation
    state.refs_fingerprint = result.fingerprint
    state.refs = {}
    return true
  end
  clear_refs(state)
  return false
end

local function remember_candidate(state, page, slot, candidate)
  if state.refs_generation ~= page.generation
      or state.refs_fingerprint ~= state.expected_fingerprint
      or type(slot) ~= "number" then
    return
  end
  local identity = page.candidates[slot + 1]
  if identity == nil or candidate.text ~= identity.text
      or candidate.type ~= identity.type or candidate.start ~= identity.start
      or candidate._end ~= identity["end"] then
    return
  end
  local genuine = candidate:get_genuine()
  if genuine == nil then
    return
  end
  state.refs[slot] = {
    genuine = genuine,
    identity = identity,
    base_comment = candidate.comment or "",
    applied_comment = nil,
  }
end

local function handle_context_update(state, env, context)
  if not state.enabled or state.bridge == nil or state.dictionary == nil
      or state.cache == nil or context == nil then
    return
  end
  local input = context.input or ""
  -- Input edits are handled by the normal filter pass.  This callback is only
  -- for highlight/page changes after the current composition has already been
  -- observed by the filter.
  if state.composition_input == nil or state.composition_input ~= input then
    return
  end
  local composition = context.composition
  if composition == nil or composition:empty() then
    return
  end
  local segment = composition:back()
  local selected_index = segment and segment.selected_index
  local page_size = env.engine.schema.page_size
  if type(selected_index) ~= "number" or selected_index < 0
      or type(page_size) ~= "number" or page_size < 1
      or page_size > MAX_PAGE_SIZE then
    return
  end
  local page_start = math.floor(selected_index / page_size) * page_size

  if state.page ~= nil and state.page.page_start == page_start then
    -- A highlight within the same page is also a natural UI update. The
    -- patched Weasel server owns active refresh publication; Lua only polls
    -- and applies to candidates produced by the current Rime callback.
    local translations = poll(state, state.page)
    if translations ~= nil then
      apply_ready(state, state.page, translations)
    end
    return
  end

  local candidates = menu_page(env.engine, context, page_start)
  if candidates == nil or #candidates == 0 then
    return
  end
  local page, translations, misses = prepare_page(
    state,
    env,
    candidates,
    page_start,
    state.dictionary,
    state.cache
  )
  if page == nil then
    return
  end
  if not submit_page(state, page, misses) then
    return
  end
  for slot, candidate in ipairs(candidates) do
    if state.dictionary[candidate.text] == nil and state.cache[candidate.text] == nil then
      remember_candidate(state, page, slot - 1, candidate)
    end
  end
  apply_ready(state, page, translations)
end

function M.filter_init(env, options)
  local state = state_for(env)
  if type(options) == "table" then
    if options.enabled == false then
      state.enabled = false
      clear_refs(state)
      state.page = nil
      state.expected_generation = nil
      state.expected_fingerprint = nil
      state.dictionary = options.dictionary
      state.cache = options.cache
      return
    end
    state.preserve_existing_comment = options.preserve_existing_comment ~= false
    state.comment_prefix = options.comment_prefix or ""
    state.comment_separator = options.comment_separator or " · "
    state.dictionary = options.dictionary
    state.cache = options.cache
  end
  if not state.enabled then
    return
  end
  if state.update_connection == nil then
    local notifier = env.engine.context and env.engine.context.update_notifier
    if notifier ~= nil and type(notifier.connect) == "function" then
      local ok, connection = pcall(function()
        return notifier:connect(function(context)
          handle_context_update(state, env, context)
        end)
      end)
      if ok then
        state.update_connection = connection
      end
    end
  end
end

function M.prepare_filter(env, candidates, page_start, dictionary, cache)
  local state = states[env.engine]
  if state == nil or not state.enabled then
    return nil, nil
  end
  if state.skip_next_filter then
    state.skip_next_filter = false
    state.generation = state.generation + 1
    state.signature = "backspace-skip"
    local context = env.engine.context
    state.composition_input = (context and context.input) or ""
    state.has_composition = nil
    state.page = nil
    state.expected_generation = nil
    state.expected_fingerprint = nil
    clear_refs(state)
    return nil, nil
  end
  local page, translations, misses = prepare_page(
    state,
    env,
    candidates,
    page_start,
    dictionary,
    cache
  )
  return page, translations, misses
end

function M.finish_filter(env, page, misses)
  local state = states[env.engine]
  if state == nil then
    return
  end
  submit_page(state, page, misses)
end

function M.remember_candidate(env, page, slot, candidate)
  local state = states[env.engine]
  if state == nil then
    return
  end
  remember_candidate(state, page, slot, candidate)
end

function M.init(env)
  state_for(env)
end

function M.fini(env)
  local state = states[env.engine]
  if state ~= nil then
    if state.update_connection ~= nil and type(state.update_connection.disconnect) == "function" then
      pcall(function()
        state.update_connection:disconnect()
      end)
    end
    state.update_connection = nil
    clear_refs(state)
    state.page = nil
    state.expected_generation = nil
    state.expected_fingerprint = nil
    states[env.engine] = nil
  end
end

function M.func(key_event, env)
  local state = states[env.engine]
  if state ~= nil and state.enabled and key_event ~= nil then
    local ok, representation = pcall(function()
      return key_event:repr()
    end)
    if ok and representation == "BackSpace" then
      -- Backspace is latency-sensitive because Rime is already rebuilding the
      -- composition/menu. Do not poll the old page and skip the very next
      -- async page materialization; dictionary/cache filtering still runs.
      state.skip_next_filter = true
      clear_refs(state)
      state.page = nil
      state.expected_generation = nil
      state.expected_fingerprint = nil
      return 2
    end
  end
  if state ~= nil and state.enabled and state.page ~= nil then
    -- commit/cancel notifications are not assumed. On the very next real key,
    -- observe the now-empty composition before consulting the old completion.
    local context = env.engine.context
    local composition = context and context.composition
    if composition == nil or composition:empty() then
      clear_refs(state)
      state.page = nil
      state.expected_generation = nil
      state.expected_fingerprint = nil
      return 2
    end
    local translations = poll(state, state.page)
    if translations ~= nil then
      apply_ready(state, state.page, translations)
    end
  end
  -- kNoop: observe every key, including PageUp/PageDown, without consuming it.
  return 2
end

return M
