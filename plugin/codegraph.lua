if vim.g.loaded_codegraph then
  return
end
vim.g.loaded_codegraph = true

vim.api.nvim_create_user_command("CodegraphQuery", function(opts)
  require("codegraph").query(opts.args)
end, { nargs = "?", desc = "codegraph query symbols" })

vim.api.nvim_create_user_command("CodegraphCallers", function(opts)
  require("codegraph").callers(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "codegraph callers of symbol (default: <cword>)" })

vim.api.nvim_create_user_command("CodegraphCallees", function(opts)
  require("codegraph").callees(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "codegraph callees of symbol (default: <cword>)" })

vim.api.nvim_create_user_command("CodegraphImpact", function(opts)
  require("codegraph").impact(opts.args ~= "" and opts.args or nil)
end, { nargs = "?", desc = "codegraph impact of symbol (default: <cword>)" })

vim.api.nvim_create_user_command("CodegraphSync", function()
  require("codegraph").sync()
end, { desc = "codegraph sync index for current project" })
