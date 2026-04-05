local M = {}

---@class ParserConfig
---@field url string  URL of the parser's git repository
---@field revision? string  Git ref to install (branch, tag, or commit SHA); defaults to "master"

---@class Config
---@field parsers table<string, ParserConfig>  Map of language name to parser config
---@field data_dir? string  Directory where compiled .so files are placed
---@field revision_dir? string  Directory where installed-revision markers are stored
---@field query_dir? string  Root directory for query files; queries land in {query_dir}/{lang}/
---@field tmp_dir? string  Scratch directory for downloads and source extraction

---@type Config
local defaults = {
	parsers = {},
	data_dir = vim.fn.stdpath("data") .. "/site/parser",
	revision_dir = vim.fn.stdpath("data") .. "/site/parser-info",
	query_dir = vim.fn.stdpath("data") .. "/site/queries",
	tmp_dir = vim.fn.stdpath("data") .. "/site/parser-src",
}

--- Thin wrapper around vim.system that calls on_exit with a synthetic error
--- result when the command cannot even be spawned (e.g. binary not found).
---@param cmd string[]  Command and arguments
---@param opts table  Options forwarded to vim.system
---@param on_exit fun(result: vim.SystemCompleted)  Callback invoked on completion
local function system(cmd, opts, on_exit)
	local ok, err = pcall(vim.system, cmd, opts, on_exit)
	if not ok then
		-- pcall caught a synchronous error (e.g. executable not found); synthesise
		-- a failed result so callers always go through the same error path.
		on_exit({ code = 125, signal = 0, stdout = "", stderr = err })
	end
end

--- Schedule a vim.notify call with the plugin prefix prepended.
---@param msg string  Message text
---@param level? integer  vim.log.levels constant; defaults to INFO
local function notify(msg, level)
	vim.schedule(function()
		vim.notify("[simple-treesitter] " .. msg, level or vim.log.levels.INFO)
	end)
end

--- Read the revision that was recorded when a parser was last installed.
---@param name string  Language name (used as the file stem)
---@param revision_dir string  Directory containing .rev files
---@return string|nil  The stored revision string, or nil if not found
local function get_installed_revision(name, revision_dir)
	local path = revision_dir .. "/" .. name .. ".rev"
	local f = io.open(path, "r")
	if f then
		local rev = f:read("*l")
		f:close()
		return rev
	end
end

--- Persist a revision marker so future runs can skip re-installation.
---@param name string  Language name
---@param revision string  Git ref that was successfully installed
---@param revision_dir string  Directory in which to write the .rev file
local function save_revision(name, revision, revision_dir)
	vim.fn.mkdir(revision_dir, "p")
	local f = io.open(revision_dir .. "/" .. name .. ".rev", "w")
	if f then
		f:write(revision)
		f:close()
	end
end

--- Copy bundled query files (if any) from the extracted source tree into query_dir.
--- Neovim looks for queries at {rtp}/queries/{lang}/*.scm; query_dir must be on the rtp.
---
--- Two layouts are handled:
---   Flat:   queries/*.scm           → {query_dir}/{name}/*.scm
---   Nested: queries/{lang}/*.scm    → {query_dir}/{lang}/*.scm  (multi-language repos)
---@param name string  Language name
---@param src_dir string  Extracted source directory (may contain a queries/ sub-directory)
---@param query_dir string  Root queries directory ({stdpath("data")}/site/queries)
---@param on_done fun()  Called when finished, whether or not queries were present
local function install_queries(name, src_dir, query_dir, on_done)
	local queries_src = src_dir .. "/queries"
	if vim.fn.isdirectory(queries_src) == 0 then
		on_done()
		return
	end

	-- Flat layout: .scm files sit directly inside queries/.
	local scm_files = vim.fn.glob(queries_src .. "/*.scm", false, true)
	if #scm_files > 0 then
		local dest = query_dir .. "/" .. name
		vim.fn.mkdir(dest, "p")
		system({ "cp", "-r", queries_src .. "/.", dest }, {}, function(r)
			vim.schedule(function()
				if r.code ~= 0 then
					notify("query install failed for " .. name .. ": " .. r.stderr, vim.log.levels.WARN)
				end
				on_done()
			end)
		end)
		return
	end

	-- Nested layout: subdirectories are language names (e.g. queries/lua/, queries/vim/).
	local entries = vim.fn.readdir(queries_src)
	local subdirs = {}
	for _, entry in ipairs(entries) do
		if vim.fn.isdirectory(queries_src .. "/" .. entry) == 1 then
			subdirs[#subdirs + 1] = entry
		end
	end
	if #subdirs == 0 then
		on_done()
		return
	end
	local remaining = #subdirs
	for _, lang in ipairs(subdirs) do
		local dest = query_dir .. "/" .. lang
		vim.fn.mkdir(dest, "p")
		system({ "cp", "-r", queries_src .. "/" .. lang .. "/.", dest }, {}, function(r)
			vim.schedule(function()
				if r.code ~= 0 then
					notify("query install failed for " .. lang .. ": " .. r.stderr, vim.log.levels.WARN)
				end
				remaining = remaining - 1
				if remaining == 0 then
					on_done()
				end
			end)
		end)
	end
end

--- Compile parser sources with `make`, then copy the produced .so into data_dir.
--- Assumes the Makefile in src_dir knows how to build a shared library.
---@param name string  Language name (used as the output filename stem)
---@param src_dir string  Directory containing the Makefile and parser sources
---@param data_dir string  Destination directory for the compiled .so
---@param on_done fun(err: string|nil, out: string|nil)  Called with (nil, path) on success or (msg, nil) on failure
local function compile(name, src_dir, data_dir, on_done)
	vim.fn.mkdir(data_dir, "p")
	local out = data_dir .. "/" .. name .. ".so"
	system({ "make" }, { cwd = src_dir }, function(r)
		vim.schedule(function()
			if r.code ~= 0 then
				on_done("make failed: " .. r.stderr)
				return
			end
			local so_files = vim.fn.glob(src_dir .. "/*.so", false, true)
			if #so_files == 0 then
				on_done("no .so produced by make in " .. src_dir)
				return
			end
			-- Copy the first .so produced by make to the canonical output path.
			system({ "cp", so_files[1], out }, {}, function(r2)
				if r2.code ~= 0 then
					on_done("cp failed: " .. r2.stderr)
				else
					on_done(nil, out)
				end
			end)
		end)
	end)
end

--- Download, extract, optionally generate, and compile a single parser.
--- Skips the whole pipeline when the installed revision already matches.
---@param name string  Language name
---@param parser ParserConfig  Parser configuration
---@param settings Config  Resolved plugin settings
local function install_parser(name, parser, settings)
	local revision = parser.revision or "master"

	-- Skip installation when the on-disk revision already matches the target.
	if get_installed_revision(name, settings.revision_dir) == revision then
		return
	end

	notify("installing " .. name .. " @ " .. revision:sub(1, 12))

	local tarball = settings.tmp_dir .. "/" .. name .. "-" .. revision .. ".tar.gz"
	local extract_dest = settings.tmp_dir .. "/" .. name .. "-" .. revision

	vim.fn.mkdir(settings.tmp_dir, "p")
	vim.fn.delete(extract_dest, "rf") -- clear any previous partial extract

	local archive_url = parser.url .. "/archive/" .. revision .. ".tar.gz"

	-- Step 1: download the source archive from the repository host.
	system({
		"curl",
		"--silent",
		"--fail",
		"--show-error",
		"--retry",
		"3",
		"-L",
		archive_url,
		"--output",
		tarball,
	}, { text = true }, function(r)
		vim.schedule(function()
			if r.code ~= 0 then
				notify("download failed for " .. name .. ": " .. r.stderr, vim.log.levels.ERROR)
				return
			end

			-- Step 2: extract the tarball, stripping the top-level directory created by GitHub.
			vim.fn.mkdir(extract_dest, "p")
			system({ "tar", "-xzf", tarball, "-C", extract_dest, "--strip-components=1" }, {}, function(r2)
				vim.schedule(function()
					if r2.code ~= 0 then
						notify("extract failed for " .. name .. ": " .. r2.stderr, vim.log.levels.ERROR)
						return
					end

					local src_dir = extract_dest

					--- Compile the parser and record the installed revision on success.
					local function do_compile()
						compile(name, src_dir, settings.data_dir, function(err, out)
							if err then
								notify("compile failed for " .. name .. ": " .. err, vim.log.levels.ERROR)
								return
							end
							vim.schedule(function()
								save_revision(name, revision, settings.revision_dir)
								install_queries(name, src_dir, settings.query_dir, function()
									notify("installed " .. name .. " -> " .. out)
								end)
							end)
						end)
					end

					local has_grammar = vim.fn.filereadable(src_dir .. "/grammar.js") == 1
					local has_parser_c = vim.fn.filereadable(src_dir .. "/src/parser.c") == 1

					-- Step 3: run `tree-sitter generate` only when the grammar source is present
					-- but the pre-generated parser.c is absent (i.e. the repo ships only the
					-- grammar DSL and expects consumers to generate it).
					if has_grammar and not has_parser_c then
						system({ "tree-sitter", "generate" }, { cwd = src_dir, text = true }, function(r3)
							if r3.code ~= 0 then
								notify(
									"tree-sitter generate failed for " .. name .. ": " .. r3.stderr,
									vim.log.levels.ERROR
								)
								return
							end
							do_compile()
						end)
					else
						do_compile()
					end
				end)
			end)
		end)
	end)
end

--- Force-reinstall a single parser, ignoring any cached revision.
--- Useful when a parser is broken or you want to pin to a new ref.
---@param name string  Language name as declared in `setup({ parsers = { ... } })`
M.install = function(name)
	if not M.settings then
		vim.notify("[simple-treesitter] call setup() first", vim.log.levels.ERROR)
		return
	end
	local parser = M.settings.parsers[name]
	if not parser then
		vim.notify("[simple-treesitter] unknown parser: " .. name, vim.log.levels.ERROR)
		return
	end
	-- Delete the revision marker so install_parser treats this as a new install.
	local rev_file = M.settings.revision_dir .. "/" .. name .. ".rev"
	vim.fn.delete(rev_file)
	install_parser(name, parser, M.settings)
end

--- Check all configured parsers and install any whose revision has changed.
M.update = function()
	if not M.settings then
		vim.notify("[simple-treesitter] call setup() first", vim.log.levels.ERROR)
		return
	end
	for name, parser in pairs(M.settings.parsers) do
		install_parser(name, parser, M.settings)
	end
end

--- Initialise the plugin and install any parsers not yet at the desired revision.
---@param opts? Config  Partial config merged over the built-in defaults
M.setup = function(opts)
	M.settings = vim.tbl_deep_extend("force", defaults, opts or {})

	for name, parser in pairs(M.settings.parsers) do
		install_parser(name, parser, M.settings)
	end

	vim.api.nvim_create_autocmd({ "FileType", "BufRead", "BufNewFile" }, {
		group = vim.api.nvim_create_augroup("SimpleTreesitter", { clear = true }),
		callback = function(event)
			local lang = vim.treesitter.language.get_lang(event.match) or event.match
			if vim.treesitter.query.get(lang, "highlights") then
				pcall(vim.treesitter.start, event.buf)
			end
		end,
	})
end

return M
