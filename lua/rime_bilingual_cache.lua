-- V0.2 cache-snapshot loader.
--
-- Snapshots are data, not programs. An empty Lua _ENV does not make executing
-- an arbitrary chunk safe: a chunk can still loop forever or allocate a very
-- large table. This loader parses only the canonical publisher syntax.
--
-- Called once from rime_bilingual.init. Candidate processing only reads the
-- returned table and performs no file I/O.

local M = {}

local MAX_ENTRIES = 10000
local MAX_STRING_BYTES = 4096
local MAX_FILE_BYTES = 16 * 1024 * 1024
local MAX_LAYOUT_FILE_BYTES = 1024 * 1024
local MAX_REVISION = 2147483647

M.MAX_ENTRIES = MAX_ENTRIES
M.MAX_STRING_BYTES = MAX_STRING_BYTES
M.MAX_FILE_BYTES = MAX_FILE_BYTES
M.MAX_LAYOUT_FILE_BYTES = MAX_LAYOUT_FILE_BYTES

local function emit_warning(warn, message)
  if type(warn) == "function" then
    pcall(warn, message)
    return
  end
  if log and log.warning then
    pcall(log.warning, message)
  end
end

local function invalid_cache(warn, message)
  emit_warning(warn, "[rime_bilingual] cache snapshot ignored: " .. message)
  return {}
end

local function read_bounded_file(path)
  if type(io) ~= "table" or type(io.open) ~= "function" then
    return nil, "file access is unavailable in this Lua runtime"
  end
  local opened, file = pcall(io.open, path, "rb")
  if not opened or not file then
    return nil, "snapshot file is missing or unreadable"
  end

  local seek_ok, size = pcall(file.seek, file, "end")
  if not seek_ok or type(size) ~= "number" or size < 0 then
    pcall(file.close, file)
    return nil, "snapshot size is unavailable"
  end
  if size > MAX_FILE_BYTES then
    pcall(file.close, file)
    return nil, "snapshot file is too large"
  end
  if not pcall(file.seek, file, "set", 0) then
    pcall(file.close, file)
    return nil, "snapshot file cannot be rewound"
  end

  -- Read a numeric maximum instead of "*a" so a file that grows after the
  -- seek cannot make this process allocate beyond the declared limit.
  local read_ok, text = pcall(file.read, file, MAX_FILE_BYTES + 1)
  pcall(file.close, file)
  if not read_ok or type(text) ~= "string" or #text ~= size then
    return nil, "snapshot file cannot be read completely"
  end
  return text
end

local function read_bounded_layout_file(path)
  if type(io) ~= "table" or type(io.open) ~= "function" then
    return nil, "file access is unavailable in this Lua runtime"
  end
  local opened, file = pcall(io.open, path, "rb")
  if not opened or not file then
    return nil, "compiled Weasel config is missing or unreadable"
  end
  local seek_ok, size = pcall(file.seek, file, "end")
  if not seek_ok or type(size) ~= "number" or size < 0 then
    pcall(file.close, file)
    return nil, "compiled Weasel config size is unavailable"
  end
  if size > MAX_LAYOUT_FILE_BYTES then
    pcall(file.close, file)
    return nil, "compiled Weasel config is too large"
  end
  if not pcall(file.seek, file, "set", 0) then
    pcall(file.close, file)
    return nil, "compiled Weasel config cannot be rewound"
  end
  local read_ok, text = pcall(file.read, file, MAX_LAYOUT_FILE_BYTES + 1)
  pcall(file.close, file)
  if not read_ok or type(text) ~= "string" or #text ~= size then
    return nil, "compiled Weasel config cannot be read completely"
  end
  return text
end

local function parse_vertical_layout(text)
  local in_style = false
  local style_indent = nil
  local in_layout = false
  local layout_indent = nil
  local horizontal = nil
  local layout_type = nil

  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    local leading, content = line:match("^(%s*)(.-)%s*$")
    if leading and not leading:find("\t", 1, true) then
      local indent = #leading
      content = content:gsub("%s+#.*$", "")
      if content ~= "" and content:sub(1, 1) ~= "#" then
        if not in_style then
          if indent == 0 and content == "style:" then
            in_style = true
            style_indent = indent
          end
        else
          if indent <= style_indent then
            break
          end
          if in_layout and indent <= layout_indent then
            in_layout = false
            layout_indent = nil
          end
          if indent == style_indent + 2 then
            local value = content:match("^horizontal:%s*(%a+)%s*$")
            if value == "true" or value == "false" then
              horizontal = value == "true"
            elseif content == "layout:" then
              in_layout = true
              layout_indent = indent
            end
          elseif in_layout and indent == layout_indent + 2 then
            local value = content:match("^type:%s*([%w_+%-]+)%s*$")
            if value ~= nil then
              layout_type = value
            end
          end
        end
      end
    end
  end

  if layout_type ~= nil then
    return layout_type == "vertical"
  end
  if horizontal ~= nil then
    return horizontal == false
  end
  return false
end

local function is_vertical_layout(user_data_dir, warn)
  if type(user_data_dir) ~= "string" or user_data_dir == "" then
    emit_warning(warn, "[rime_bilingual] translation disabled: Rime user data directory is unavailable")
    return false
  end
  local base = user_data_dir:gsub("[\\/]$", "")
  local path = base .. "/build/weasel.yaml"
  local text, read_error = read_bounded_layout_file(path)
  if not text then
    emit_warning(warn, "[rime_bilingual] translation disabled: " .. read_error)
    return false
  end
  if not parse_vertical_layout(text) then
    emit_warning(warn, "[rime_bilingual] translation disabled: Weasel candidate layout is not vertical")
    return false
  end
  return true
end

local function valid_utf8(value)
  local index = 1
  while index <= #value do
    local first = string.byte(value, index)
    if first <= 0x7f then
      index = index + 1
    elseif first >= 0xc2 and first <= 0xdf then
      local second = string.byte(value, index + 1)
      if not second or second < 0x80 or second > 0xbf then return false end
      index = index + 2
    elseif first >= 0xe0 and first <= 0xef then
      local second = string.byte(value, index + 1)
      local third = string.byte(value, index + 2)
      if not second or not third
        or second < 0x80 or second > 0xbf
        or third < 0x80 or third > 0xbf
        or (first == 0xe0 and second < 0xa0)
        or (first == 0xed and second > 0x9f) then
        return false
      end
      index = index + 3
    elseif first >= 0xf0 and first <= 0xf4 then
      local second = string.byte(value, index + 1)
      local third = string.byte(value, index + 2)
      local fourth = string.byte(value, index + 3)
      if not second or not third or not fourth
        or second < 0x80 or second > 0xbf
        or third < 0x80 or third > 0xbf
        or fourth < 0x80 or fourth > 0xbf
        or (first == 0xf0 and second < 0x90)
        or (first == 0xf4 and second > 0x8f) then
        return false
      end
      index = index + 4
    else
      return false
    end
  end
  return true
end

local function new_parser(text)
  return { text = text, position = 1, newline = nil }
end

local function consume(parser, literal)
  local last = parser.position + #literal - 1
  if string.sub(parser.text, parser.position, last) ~= literal then
    return false
  end
  parser.position = last + 1
  return true
end

local function consume_newline(parser)
  local newline
  if string.sub(parser.text, parser.position, parser.position + 1) == "\r\n" then
    newline = "\r\n"
  elseif string.sub(parser.text, parser.position, parser.position) == "\n" then
    newline = "\n"
  else
    return false
  end
  if parser.newline and parser.newline ~= newline then return false end
  parser.newline = newline
  parser.position = parser.position + #newline
  return true
end

local function read_revision(parser)
  local start = parser.position
  while true do
    local byte = string.byte(parser.text, parser.position)
    if not byte or byte < 0x30 or byte > 0x39 then break end
    parser.position = parser.position + 1
  end
  local digits = string.sub(parser.text, start, parser.position - 1)
  if digits == "" or (#digits > 1 and string.sub(digits, 1, 1) == "0")
    or #digits > 10 then
    return nil
  end
  local value = tonumber(digits)
  if not value or value > MAX_REVISION or value ~= math.floor(value) then
    return nil
  end
  return value
end

local named_escapes = {
  b = "\b", t = "\t", n = "\n", f = "\f", r = "\r",
  ["'"] = "'", ["\\"] = "\\",
}

local function read_lua_string(parser)
  if not consume(parser, "'") then return nil end
  local pieces = {}
  local decoded_bytes = 0

  while parser.position <= #parser.text do
    local byte = string.byte(parser.text, parser.position)
    if byte == 0x27 then
      parser.position = parser.position + 1
      local value = table.concat(pieces)
      if value == "" or not valid_utf8(value) then return nil end
      return value
    end

    local piece
    if byte == 0x5c then
      parser.position = parser.position + 1
      local escaped = string.sub(parser.text, parser.position, parser.position)
      piece = named_escapes[escaped]
      if piece then
        parser.position = parser.position + 1
      else
        local digits = string.sub(parser.text, parser.position, parser.position + 2)
        if not string.match(digits, "^%d%d%d$") then return nil end
        local code = tonumber(digits)
        if not (code < 0x20 or code == 0x7f)
          or code == 0x08 or code == 0x09 or code == 0x0a
          or code == 0x0c or code == 0x0d then
          return nil
        end
        piece = string.char(code)
        parser.position = parser.position + 3
      end
    else
      if byte < 0x20 or byte == 0x7f then return nil end
      piece = string.char(byte)
      parser.position = parser.position + 1
    end

    decoded_bytes = decoded_bytes + #piece
    if decoded_bytes > MAX_STRING_BYTES then return nil end
    pieces[#pieces + 1] = piece
  end
  return nil
end

local function parse_snapshot(text)
  local parser = new_parser(text)
  if not consume(parser, "return {") or not consume_newline(parser)
    or not consume(parser, "  format_version = 1,") or not consume_newline(parser)
    or not consume(parser, "  db_schema_version = 1,") or not consume_newline(parser)
    or not consume(parser, "  revision = ") then
    return nil, "snapshot is not in canonical format"
  end

  local revision = read_revision(parser)
  if revision == nil or not consume(parser, ",") or not consume_newline(parser)
    or not consume(parser, "  source_language = 'zh',") or not consume_newline(parser)
    or not consume(parser, "  target_language = 'en',") or not consume_newline(parser)
    or not consume(parser, "  translation_mode = 'literal',") or not consume_newline(parser)
    or not consume(parser, "  entries = {") or not consume_newline(parser) then
    return nil, "snapshot metadata is not canonical"
  end

  local cache = {}
  local seen = {}
  local previous_source = nil
  local count = 0
  while string.sub(parser.text, parser.position, parser.position + 3) == "    " do
    count = count + 1
    if count > MAX_ENTRIES then return nil, "too many entries" end
    if not consume(parser, "    [") then return nil, "entry syntax is invalid" end
    local source_text = read_lua_string(parser)
    if not source_text or not consume(parser, "] = ") then
      return nil, "entry source_text is invalid"
    end
    local translated_text = read_lua_string(parser)
    if not translated_text or not consume(parser, ",") or not consume_newline(parser) then
      return nil, "entry translated_text is invalid"
    end
    if seen[source_text] then return nil, "entry source_text is duplicated" end
    if previous_source and source_text < previous_source then
      return nil, "entries are not canonically sorted"
    end
    seen[source_text] = true
    cache[source_text] = translated_text
    previous_source = source_text
  end

  if not consume(parser, "  },") or not consume_newline(parser)
    or not consume(parser, "}") or not consume_newline(parser)
    or parser.position ~= #parser.text + 1 then
    return nil, "snapshot has trailing or unexpected tokens"
  end
  return cache
end

local function load_snapshot(path, warn)
  if type(path) ~= "string" or path == "" then
    return invalid_cache(warn, "user data directory is unavailable")
  end
  local text, read_error = read_bounded_file(path)
  if not text then return invalid_cache(warn, read_error) end
  local cache, parse_error = parse_snapshot(text)
  if not cache then return invalid_cache(warn, parse_error) end
  return cache
end

M.load = load_snapshot
M.is_vertical_layout = is_vertical_layout

return M
