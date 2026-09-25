# codegraph.nvim

Thin Neovim UI over the [`codegraph`](https://github.com/colbymchenry/codegraph) CLI: query the local `.codegraph` graph and jump to results.

## Requirements

- Neovim ≥ 0.10 (`vim.system`, `vim.fs`)
- `codegraph` on `PATH`
- Project indexed: `codegraph init` (once) / `codegraph sync` after big changes
- Optional: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) for a nicer picker (falls back to `vim.ui.select`)

## Install (lazy.nvim)

```lua
{
  "AgenticTimes/codegraph.nvim",
  dependencies = { "nvim-telescope/telescope.nvim" }, -- optional
  config = function()
    require("codegraph").setup({
      -- path = "/abs/repo", -- optional pin; default: nearest .codegraph upward
      limit = 40,
      impact_depth = 2,
      picker = "auto", -- "telescope" | "select" | "auto"
    })
    -- Prefer keys that don't clash with LSP/Doom <leader>c* (ca/cc/ce/ci/…)
    vim.keymap.set("n", "<leader>cq", function()
      require("codegraph").query()
    end, { desc = "codegraph query" })
    vim.keymap.set("n", "<leader>ch", function()
      require("codegraph").callers()
    end, { desc = "codegraph callers" })
    vim.keymap.set("n", "<leader>cy", function()
      require("codegraph").callees()
    end, { desc = "codegraph callees" })
    vim.keymap.set("n", "<leader>cp", function()
      require("codegraph").impact()
    end, { desc = "codegraph impact" })
    vim.keymap.set("n", "<leader>cu", function()
      require("codegraph").sync()
    end, { desc = "codegraph sync" })
  end,
}
```

## Commands

| Command | Action |
|---------|--------|
| `:CodegraphQuery [name]` | Search symbols (`query -j`) |
| `:CodegraphCallers [sym]` | Who calls symbol (default `<cword>`) |
| `:CodegraphCallees [sym]` | What it calls |
| `:CodegraphImpact [sym]` | Blast radius |
| `:CodegraphSync` | `codegraph sync` for detected root |

Select a row → open file at `startLine`.

## How it works

Does **not** open SQLite itself. Runs:

```text
codegraph <query|callers|callees|impact> … -j -p <root>
```

Root = nearest ancestor with `.codegraph/`, unless `setup { path = … }`.

## Out of scope (v1)

- Drawing call graphs
- Writing the DB directly
- MCP server hosting inside Neovim
