# simple-treesitter.nvim

**WARNING** this is very early stage so don't use this and expect all to work

A minimal Neovim plugin that downloads, compiles, and installs Tree-sitter parsers directly from their git repositories.

Instead of delegating to nvim-treesitter's parser registry, you point this plugin at any parser git repository and pin it to an exact revision. On startup it checks whether the parser is already installed at that revision; if not, it downloads the source archive, optionally runs `tree-sitter generate`, compiles it with `make`, and drops the resulting `.so` into Neovim's parser directory.

## Requirements

- **Neovim** >= 0.11
- **curl** — for downloading source archives
- **tar** — for extracting archives
- **make** and a C compiler (e.g. `gcc` or `clang`) — for compiling parsers
- **tree-sitter CLI** *(optional)* — only needed for parsers that ship a `grammar.js` without a pre-generated `src/parser.c`

## Installation

### lazy.nvim

```lua
{
  "desdic/simple-treesitter.nvim",
  config = function()
    require("simple-treesitter").setup({
      parsers = {
        hlsl = {
          url = "https://github.com/tree-sitter-grammars/tree-sitter-hlsl",
          revision = "bab9111922d53d43668fabb61869bec51bbcb915",
        },
      },
    })
  end,
}
```

## Configuration

Pass a table to `setup()`. All keys are optional and fall back to their defaults.

```lua
require("simple-treesitter").setup({
  -- Map of language name -> parser config.
  -- The language name must match the name Neovim uses for the filetype
  -- (e.g. "hlsl", "lua", "python").
  parsers = {
    hlsl = {
      -- Git repository URL of the parser.
      url = "https://github.com/tree-sitter-grammars/tree-sitter-hlsl",
      -- Branch, tag, or commit SHA to install.
      -- Defaults to "master" when omitted.
      revision = "bab9111922d53d43668fabb61869bec51bbcb915",
    },
    -- Add as many parsers as you need:
    -- glsl = {
    --   url = "https://github.com/tree-sitter-grammars/tree-sitter-glsl",
    --   revision = "some-tag-or-sha",
    -- },
  },

  -- Where compiled .so files are placed.
  -- Must be on Neovim's runtimepath under "parser/".
  -- Default: stdpath("data") .. "/site/parser"
  data_dir = vim.fn.stdpath("data") .. "/site/parser",

  -- Where revision markers (.rev files) are stored.
  -- Default: stdpath("data") .. "/site/parser-info"
  revision_dir = vim.fn.stdpath("data") .. "/site/parser-info",

  -- Scratch directory used during download and extraction.
  -- Default: stdpath("data") .. "/site/parser-src"
  tmp_dir = vim.fn.stdpath("data") .. "/site/parser-src",
})
```

## API

### `require("simple-treesitter").setup(opts)`

Initialises the plugin and installs any configured parser whose installed revision does not match the configured one. Safe to call on every Neovim startup — already up-to-date parsers are skipped instantly.

### `require("simple-treesitter").update()`

Re-checks all configured parsers and installs any that are out of date. Useful to call after editing your config to pick up new parsers or revision changes.

```lua
:lua require("simple-treesitter").update()
```

### `require("simple-treesitter").install(name)`

Force-reinstalls a single parser by name, ignoring the cached revision. Use this when a parser is broken or you want to force a re-download.

```lua
:lua require("simple-treesitter").install("hlsl")
```

## How it works

1. **Revision check** — reads a `.rev` marker file; if it matches the configured revision the parser is already up to date and nothing else happens.
2. **Download** — fetches `<url>/archive/<revision>.tar.gz` with `curl`.
3. **Extract** — unpacks the archive into a temporary directory with `tar`.
4. **Generate** *(conditional)* — if the repo contains `grammar.js` but no `src/parser.c`, runs `tree-sitter generate` to produce the C source.
5. **Compile** — runs `make` inside the source directory, then copies the resulting `.so` into `data_dir`.
6. **Record** — writes the revision to the `.rev` marker so future startups skip the whole pipeline.

## Notes

- Parsers are installed asynchronously; notifications appear via `vim.notify` as each step completes or fails.
- Pinning to a commit SHA is recommended for reproducible setups. Branch names like `master` work but will not re-install when the branch moves unless you delete the `.rev` marker or call `install()`.

## Credits

I'd like to credit the author(s) of [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter) for doing an amazing plugin
