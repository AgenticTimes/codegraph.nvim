-- codegraph.nvim: thin Neovim UI over the codegraph CLI (JSON → picker → jump)
local M = {}

local defaults = {
  cmd = "codegraph",
  --- Project root containing .codegraph/; nil = auto (upward search from buffer/cwd)
  path = nil,
  limit = 40,
  impact_depth = 2,
  --- "telescope" | "select" | "auto"
  picker = "auto",
}

local opts = vim.deepcopy(defaults)

function M.setup(user)
  opts = vim.tbl_deep_extend("force", defaults, user or {})
end

local function project_root()
  if opts.path and opts.path ~= "" then
    return vim.fn.fnamemodify(opts.path, ":p"):gsub("/$", "")
  end
  local buf = vim.api.nvim_buf_get_name(0)
  local start = (buf ~= "" and vim.fs.dirname(buf)) or vim.fn.getcwd()
  local found = vim.fs.find(".codegraph", { upward = true, path = start, type = "directory" })[1]
  if found then
    return vim.fs.dirname(found)
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

---@class codegraph.Item
---@field label string
---@field file string
---@field line integer
---@field kind? string

local function node_item(root, n)
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
  return {
    label = string.format("%-10s %s:%d  %s", kind, vim.fn.fnamemodify(file, ":."), line, name),
    file = file,
    line = tonumber(line) or 1,
    kind = kind,
  }
end

local function jump(item)
  if not item or not item.file then
    return
  end
  vim.cmd.edit(vim.fn.fnameescape(item.file))
  local line = math.max(1, item.line or 1)
  local last = vim.api.nvim_buf_line_count(0)
  pcall(vim.api.nvim_win_set_cursor, 0, { math.min(line, last), 0 })
  vim.cmd("normal! zz")
end

local function pick(title, items)
  if #items == 0 then
    vim.notify("codegraph: no results", vim.log.levels.INFO)
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
          previewer = conf.grep_previewer({}),
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

--- Fuzzy-ish symbol search
function M.query(q)
  q = q or ""
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
      local item = node_item(root, n)
      if item then
        items[#items + 1] = item
      end
    end
    pick("codegraph query: " .. q, items)
  end)
end

local function list_from_field(root, data, field)
  local items = {}
  local list = type(data) == "table" and data[field] or nil
  if type(list) ~= "table" then
    return items
  end
  for _, n in ipairs(list) do
    local item = node_item(root, n)
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
    pick("callers ← " .. sym, list_from_field(root, data, "callers"))
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
    pick("callees → " .. sym, list_from_field(root, data, "callees"))
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
    pick("impact: " .. sym, list_from_field(root, data, "affected"))
  end)
end

function M.sync()
  local root = project_root()
  vim.notify("codegraph: syncing " .. root .. "…", vim.log.levels.INFO)
  run({ "sync", "-p", root }, function()
    vim.notify("codegraph: sync done", vim.log.levels.INFO)
  end)
end

return M
