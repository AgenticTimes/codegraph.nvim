-- codegraph.nvim: thin Neovim UI over the codegraph CLI (JSON → picker → jump)
local M = {}

local defaults = {
  cmd = "codegraph",
  --- Pin index root (absolute). nil = auto: nearest .codegraph upward from buffer.
  path = nil,
  --- If auto-detect finds no index, fall back here (e.g. "~/source").
  default_path = nil,
  limit = 40,
  impact_depth = 2,
  --- "telescope" | "select" | "auto"
  picker = "auto",
}

local opts = vim.deepcopy(defaults)

function M.setup(user)
  opts = vim.tbl_deep_extend("force", defaults, user or {})
end

local function normalize_path(p)
  return vim.fn.fnamemodify(p, ":p"):gsub("/$", "")
end

local function project_root()
  if opts.path and opts.path ~= "" then
    return normalize_path(opts.path)
  end
  local buf = vim.api.nvim_buf_get_name(0)
  local start = (buf ~= "" and vim.fs.dirname(buf)) or vim.fn.getcwd()
  local found = vim.fs.find(".codegraph", { upward = true, path = start, type = "directory" })[1]
  if found then
    return vim.fs.dirname(found)
  end
  if opts.default_path and opts.default_path ~= "" then
    return normalize_path(opts.default_path)
  end
  return vim.fn.getcwd()
end

local function abs_file(root, rel)
  if not rel or rel == "" then
    return nil
  end
  if rel:match("^/") or rel:match("^%a:[/\\]") then
    return rel
  end
  return root .. "/" .. rel
end

local hl_ns = vim.api.nvim_create_namespace("codegraph_nvim_needle")

---@class codegraph.Item
---@field label string
---@field file string
---@field line integer
---@field kind? string
---@field name? string
---@field needle? string  -- symbol to highlight (e.g. callee when listing callers)

--- Find word-ish occurrence of needle in line; returns 1-based byte cols [s, e]
local function find_needle_cols(line, needle)
  if not needle or needle == "" or not line then
    return nil
  end
  local init = 1
  while true do
    local s, e = line:find(needle, init, true)
    if not s then
      return nil
    end
    local before_ok = s == 1 or not line:sub(s - 1, s - 1):match("[%w_]")
    local after_ok = e == #line or not line:sub(e + 1, e + 1):match("[%w_]")
    if before_ok and after_ok then
      return s, e
    end
    init = s + 1
  end
end

--- From start_line, find first needle; returns line (1-based), col_start, col_end (1-based inclusive)
local function locate_needle(bufnr, start_line, needle, max_lines)
  max_lines = max_lines or 2000
  local last = vim.api.nvim_buf_line_count(bufnr)
  local from = math.max(1, start_line or 1)
  local to = math.min(last, from + max_lines - 1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, from - 1, to, false)
  for i, line in ipairs(lines) do
    local s, e = find_needle_cols(line, needle)
    if s then
      return from + i - 1, s, e
    end
  end
  return nil
end

local function clear_needle_hl(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, hl_ns, 0, -1)
  end
end

local function apply_needle_hl(bufnr, line, col_s, col_e, hl_group)
  clear_needle_hl(bufnr)
  -- 0-based end-exclusive for nvim_buf_set_extmark
  pcall(vim.api.nvim_buf_set_extmark, bufnr, hl_ns, line - 1, col_s - 1, {
    end_row = line - 1,
    end_col = col_e,
    hl_group = hl_group or "Search",
    priority = 200,
  })
end

local function node_item(root, n, needle)
  if type(n) ~= "table" then
    return nil
  end
  local file = abs_file(root, n.filePath or n.file_path)
  local line = n.startLine or n.start_line or n.line or 1
  if not file or not line then
    return nil
  end
  local name = n.name or n.qualifiedName or "?"
  local kind = n.kind or ""
  local rel = vim.fn.fnamemodify(file, ":.")
  local label
  if needle and needle ~= "" and needle ~= name then
    label = string.format("%-10s %s:%d  %s → %s", kind, rel, line, name, needle)
  else
    label = string.format("%-10s %s:%d  %s", kind, rel, line, name)
  end
  return {
    label = label,
    file = file,
    line = tonumber(line) or 1,
    kind = kind,
    name = name,
    needle = needle,
  }
end

local function focus_item(bufnr, item, winid, hl_group)
  local line = math.max(1, item.line or 1)
  local last = vim.api.nvim_buf_line_count(bufnr)
  line = math.min(line, last)
  local col0 = 0
  if item.needle and item.needle ~= "" then
    local found_line, s, e = locate_needle(bufnr, line, item.needle)
    if found_line then
      line, col0 = found_line, s - 1
      apply_needle_hl(bufnr, found_line, s, e, hl_group)
    else
      clear_needle_hl(bufnr)
    end
  else
    clear_needle_hl(bufnr)
  end
  winid = winid or 0
  pcall(vim.api.nvim_win_set_cursor, winid, { line, math.max(0, col0) })
end

local function jump(item)
  if not item or not item.file then
    return
  end
  vim.cmd.edit(vim.fn.fnameescape(item.file))
  focus_item(0, item, 0, "Search")
  vim.cmd("normal! zz")
end

local function make_telescope_previewer()
  local previewers = require("telescope.previewers")
  local conf = require("telescope.config").values
  return previewers.new_buffer_previewer({
    title = "codegraph",
    get_buffer_by_name = function(_, entry)
      return entry.value and entry.value.file
    end,
    define_preview = function(self, entry)
      local item = entry.value
      if not item or not item.file then
        return
      end
      conf.buffer_previewer_maker(item.file, self.state.bufnr, {
        bufname = self.state.bufname,
        winid = self.state.winid,
        callback = function(bufnr)
          if not vim.api.nvim_buf_is_valid(bufnr) then
            return
          end
          focus_item(bufnr, item, self.state.winid, "TelescopePreviewMatch")
          pcall(vim.api.nvim_win_call, self.state.winid, function()
            vim.cmd("normal! zz")
          end)
        end,
      })
    end,
  })
end

local function pick(title, items)
  if #items == 0 then
    vim.notify(title .. " — no results", vim.log.levels.INFO)
    return
  end
  local use_telescope = opts.picker == "telescope"
    or (opts.picker == "auto" and pcall(require, "telescope.pickers"))

  if use_telescope then
    local ok = pcall(function()
      local pickers = require("telescope.pickers")
      local finders = require("telescope.finders")
      local conf = require("telescope.config").values
      local actions = require("telescope.actions")
      local action_state = require("telescope.actions.state")
      pickers
        .new({}, {
          prompt_title = title,
          finder = finders.new_table({
            results = items,
            entry_maker = function(item)
              return {
                value = item,
                display = item.label,
                ordinal = item.label,
                path = item.file,
                lnum = item.line,
              }
            end,
          }),
          sorter = conf.generic_sorter({}),
          previewer = make_telescope_previewer(),
          attach_mappings = function(prompt_bufnr)
            actions.select_default:replace(function()
              local sel = action_state.get_selected_entry()
              actions.close(prompt_bufnr)
              if sel and sel.value then
                jump(sel.value)
              end
            end)
            return true
          end,
        })
        :find()
    end)
    if ok then
      return
    end
  end

  vim.ui.select(items, {
    prompt = title,
    format_item = function(i)
      return i.label
    end,
  }, function(choice)
    jump(choice)
  end)
end

local function run(args, on_ok)
  local cmd = { opts.cmd }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, function(obj)
    vim.schedule(function()
      if obj.code ~= 0 then
        local err = (obj.stderr or obj.stdout or ""):gsub("%s+$", "")
        vim.notify("codegraph failed: " .. (err ~= "" and err or ("exit " .. tostring(obj.code))), vim.log.levels.ERROR)
        return
      end
      local raw = obj.stdout or ""
      local ok, data = pcall(vim.json.decode, raw)
      if not ok then
        vim.notify("codegraph: invalid JSON", vim.log.levels.ERROR)
        return
      end
      on_ok(data)
    end)
  end)
end

local function ensure_index(root)
  local db = root .. "/.codegraph/codegraph.db"
  if vim.fn.filereadable(db) == 0 then
    vim.notify("codegraph: no index at " .. root .. " (run: codegraph init)", vim.log.levels.WARN)
    return false
  end
  return true
end

--- Current search text: visual selection if any, else <cword>
local function cursor_text()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then -- \22 = CTRL-V
    local s = vim.fn.getpos("v")
    local e = vim.fn.getpos(".")
    local text = table.concat(vim.fn.getregion(s, e, { type = mode }), "\n")
    text = vim.trim(text:gsub("\n", " "))
    if text ~= "" then
      return text
    end
  end
  return vim.fn.expand("<cword>")
end

--- Fuzzy-ish symbol search (default: word / selection under cursor)
function M.query(q)
  q = (q and q ~= "") and q or cursor_text()
  if q == "" then
    vim.ui.input({ prompt = "codegraph query: " }, function(input)
      if input and input:match("%S") then
        M.query(input)
      end
    end)
    return
  end
  local root = project_root()
  if not ensure_index(root) then
    return
  end
  run({ "query", q, "-j", "-l", tostring(opts.limit), "-p", root }, function(data)
    local items = {}
    if type(data) ~= "table" then
      return
    end
    for _, row in ipairs(data) do
      local n = row.node or row
      -- highlight the hit symbol at its definition (name), not the raw query string
      local needle = n.name or n.qualifiedName or q
      local item = node_item(root, n, needle)
      if item then
        -- keep needle even when it equals name (label omits "→", highlight still applies)
        item.needle = needle
        items[#items + 1] = item
      end
    end
    pick(string.format("query %q @ %s", q, root), items)
  end)
end

local function list_from_field(root, data, field, needle)
  local items = {}
  local list = type(data) == "table" and data[field] or nil
  if type(list) ~= "table" then
    return items
  end
  for _, n in ipairs(list) do
    local item = node_item(root, n, needle)
    if item then
      items[#items + 1] = item
    end
  end
  return items
end

function M.callers(sym)
  sym = (sym and sym ~= "") and sym or vim.fn.expand("<cword>")
  if sym == "" then
    vim.notify("codegraph: no symbol", vim.log.levels.WARN)
    return
  end
  local root = project_root()
  if not ensure_index(root) then
    return
  end
  run({ "callers", sym, "-j", "-l", tostring(opts.limit), "-p", root }, function(data)
    pick(string.format("callers ← %s @ %s", sym, root), list_from_field(root, data, "callers", sym))
  end)
end

function M.callees(sym)
  sym = (sym and sym ~= "") and sym or vim.fn.expand("<cword>")
  if sym == "" then
    vim.notify("codegraph: no symbol", vim.log.levels.WARN)
    return
  end
  local root = project_root()
  if not ensure_index(root) then
    return
  end
  run({ "callees", sym, "-j", "-l", tostring(opts.limit), "-p", root }, function(data)
    local items = list_from_field(root, data, "callees", nil)
    for _, it in ipairs(items) do
      it.needle = it.name
    end
    pick(string.format("callees → %s @ %s", sym, root), items)
  end)
end

function M.impact(sym)
  sym = (sym and sym ~= "") and sym or vim.fn.expand("<cword>")
  if sym == "" then
    vim.notify("codegraph: no symbol", vim.log.levels.WARN)
    return
  end
  local root = project_root()
  if not ensure_index(root) then
    return
  end
  run({
    "impact",
    sym,
    "-j",
    "-d",
    tostring(opts.impact_depth),
    "-p",
    root,
  }, function(data)
    pick(string.format("impact %s @ %s", sym, root), list_from_field(root, data, "affected"))
  end)
end

function M.root()
  local root = project_root()
  vim.notify("codegraph root: " .. root, vim.log.levels.INFO)
  return root
end

function M.sync()
  local root = project_root()
  vim.notify("codegraph: syncing " .. root .. "…", vim.log.levels.INFO)
  run({ "sync", "-p", root }, function()
    vim.notify("codegraph: sync done", vim.log.levels.INFO)
  end)
end

return M
