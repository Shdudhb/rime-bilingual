-- Adds an English annotation to candidates found in the V0.1 local dictionary
-- or the V0.2 local cache snapshot.  Cache loading happens once in init; the
-- candidate loop performs only two in-memory lookups and no I/O or networking.

local dictionary = require("rime_bilingual_dictionary")
local cache_loader = require("rime_bilingual_cache")

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

  env.bilingual_dictionary = dictionary
  env.bilingual_cache_enabled = configured_bool(
    config,
    namespace .. "/cache_enabled",
    true
  )
  env.bilingual_enabled = configured_bool(config, namespace .. "/enabled", true)
  env.bilingual_preserve_comment = configured_bool(
    config,
    namespace .. "/preserve_existing_comment",
    true
  )
  env.bilingual_prefix = config:get_string(namespace .. "/comment_prefix") or ""
  env.bilingual_separator = config:get_string(namespace .. "/comment_separator") or " · "

  local function warn(message)
    if log and log.warning then
      log.warning(message)
    end
  end

  env.bilingual_cache = {}
  if env.bilingual_cache_enabled then
    local user_data_dir = rime_api:get_user_data_dir()
    local cache_path
    if type(user_data_dir) == "string" and user_data_dir ~= "" then
      cache_path = user_data_dir:gsub("[\\/]$", "") .. "/rime-bilingual/cache_snapshot.lua"
    end
    env.bilingual_cache = cache_loader.load(cache_path, warn)
  end
end

local function annotated_comment(candidate, translation, env)
  local english = env.bilingual_prefix .. translation
  local existing = candidate.comment or ""

  if env.bilingual_preserve_comment and existing ~= "" then
    return existing .. env.bilingual_separator .. english
  end

  return english
end

function M.func(input, env)
  for candidate in input:iter() do
    if env.bilingual_enabled then
      local translation = env.bilingual_dictionary[candidate.text]
      if translation == nil then
        translation = env.bilingual_cache[candidate.text]
      end
      if translation ~= nil then
        -- Mutating only comment preserves the candidate's text, type, quality,
        -- range, ordering, and selection behavior.
        candidate:get_genuine().comment = annotated_comment(candidate, translation, env)
      end
    end
    yield(candidate)
  end
end

return M
