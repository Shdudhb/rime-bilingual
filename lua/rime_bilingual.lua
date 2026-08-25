-- Adds an English annotation from the local dictionary/snapshot first, then
-- from a matching V0.3 async completion. Cache/DLL loading happens only in
-- init; typing callbacks perform bounded memory work and native try_* calls.

local dictionary = require("rime_bilingual_dictionary")
local cache_loader = require("rime_bilingual_cache")
local async = require("rime_bilingual_async")

local M = {}

local function configured_bool(config, path, default_value)
  local value = config:get_bool(path)
  if value == nil then
    return default_value
  end
  return value
end

function M.init(env)
  local config = env.engine.schema.config
  local namespace = env.name_space:gsub("^%*", "")

  local function warn(message)
    if log and log.warning then
      log.warning(message)
    end
  end

  local user_data_dir = rime_api:get_user_data_dir()
  local requested_enabled = configured_bool(config, namespace .. "/enabled", true)

  env.bilingual_dictionary = dictionary
  env.bilingual_cache_enabled = configured_bool(
    config,
    namespace .. "/cache_enabled",
    true
  )
  env.bilingual_vertical_layout = cache_loader.is_vertical_layout(user_data_dir, warn)
  env.bilingual_enabled = requested_enabled and env.bilingual_vertical_layout
  env.bilingual_preserve_comment = configured_bool(
    config,
    namespace .. "/preserve_existing_comment",
    true
  )
  env.bilingual_prefix = config:get_string(namespace .. "/comment_prefix") or ""
  env.bilingual_separator = config:get_string(namespace .. "/comment_separator") or " · "

  env.bilingual_cache = {}
  if env.bilingual_enabled and env.bilingual_cache_enabled then
    local cache_path
    if type(user_data_dir) == "string" and user_data_dir ~= "" then
      cache_path = user_data_dir:gsub("[\\/]$", "") .. "/rime-bilingual/cache_snapshot.lua"
    end
    env.bilingual_cache = cache_loader.load(cache_path, warn)
  end
  async.filter_init(env, {
    enabled = env.bilingual_enabled,
    preserve_existing_comment = env.bilingual_preserve_comment,
    comment_prefix = env.bilingual_prefix,
    comment_separator = env.bilingual_separator,
    dictionary = env.bilingual_dictionary,
    cache = env.bilingual_cache,
  })
end

local function annotated_comment(candidate, translation, env)
  local english = env.bilingual_prefix .. translation
  local existing = candidate.comment or ""

  if env.bilingual_preserve_comment and existing ~= "" then
    local suffix = env.bilingual_separator .. english
    if existing == english or existing:sub(-#suffix) == suffix then
      return existing
    end
    return existing .. suffix
  end

  return english
end

function M.func(input, env)
  if not env.bilingual_enabled then
    for candidate in input:iter() do
      yield(candidate)
    end
    return
  end

  local page_size = env.engine.schema.page_size
  if type(page_size) ~= "number" or page_size < 1 or page_size > 20 then
    page_size = 5
  end
  local target_page_start
  do
    local context = env.engine.context
    local composition = context and context.composition
    if composition ~= nil and not composition:empty() then
      local segment = composition:back()
      local selected_index = segment and segment.selected_index
      if type(selected_index) == "number" and selected_index >= 0 then
        target_page_start = math.floor(selected_index / page_size) * page_size
      end
    end
  end
  local buffered = {}
  local absolute_index = 0
  local submitted = false

  local function finish_page()
    if submitted or #buffered == 0 or target_page_start == nil then
      return
    end
    -- Do not pre-read the upstream iterator: librime-lua filters are lazy and
    -- must keep yielding as they consume input. Once the final candidate of a
    -- bounded page has been observed, submit the complete page before yielding
    -- that final candidate. segment.menu is the same Menu evaluating this
    -- filter, so never call segment.menu:prepare() from here either.
    local page, ai_translations, misses = async.prepare_filter(
      env,
      buffered,
      target_page_start,
      env.bilingual_dictionary,
      env.bilingual_cache
    )
    async.finish_filter(env, page, misses)

    for slot, candidate in ipairs(buffered) do
      local translation = env.bilingual_dictionary[candidate.text]
      if translation == nil then
        translation = env.bilingual_cache[candidate.text]
      end
      if translation == nil and page ~= nil then
        local identity = page.candidates[slot]
        if identity ~= nil and candidate.text == identity.text
            and candidate.type == identity.type and candidate.start == identity.start
            and candidate._end == identity["end"] then
          local zero_slot = slot - 1
          async.remember_candidate(env, page, zero_slot, candidate)
          local ai_translation = ai_translations and ai_translations[zero_slot]
          if ai_translation ~= nil then
            candidate:get_genuine().comment = annotated_comment(
              candidate,
              ai_translation,
              env
            )
          end
        end
      end
    end
    submitted = true
    buffered = {}
  end

  for candidate in input:iter() do
    local translation = env.bilingual_dictionary[candidate.text]
    if translation == nil then
      translation = env.bilingual_cache[candidate.text]
    end
    if translation ~= nil then
      -- Mutating only comment preserves the candidate's text, type, quality,
      -- range, ordering, and selection behavior.
      candidate:get_genuine().comment = annotated_comment(candidate, translation, env)
    end
    if target_page_start ~= nil and not submitted
        and absolute_index >= target_page_start
        and absolute_index < target_page_start + page_size then
      buffered[#buffered + 1] = candidate
      if #buffered >= page_size then
        finish_page()
      end
    end
    yield(candidate)
    absolute_index = absolute_index + 1
  end
  -- If the selected page is the final short page, iterator exhaustion proves
  -- that the buffered candidates are the complete visible page.
  finish_page()
end

function M.fini(env)
  async.fini(env)
end

return M
