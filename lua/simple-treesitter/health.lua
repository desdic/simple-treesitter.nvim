local M = {}

local function check_executable(name, required)
	if vim.fn.executable(name) == 1 then
		vim.health.ok(name .. " found")
	elseif required then
		vim.health.error(name .. " not found (required)")
	else
		vim.health.warn(name .. " not found (optional; only needed if parsers lack pre-generated parser.c)")
	end
end

local function check_neovim_version()
	local v = vim.version()
	if v.major > 0 or v.minor >= 11 then
		vim.health.ok(("Neovim %d.%d.%d"):format(v.major, v.minor, v.patch))
	else
		vim.health.error(("Neovim %d.%d.%d detected; 0.10+ required (vim.system)"):format(v.major, v.minor, v.patch))
	end
end

local function check_compilers()
	if vim.fn.executable("gcc") == 1 or vim.fn.executable("clang") == 1 then
		local cc = vim.fn.executable("gcc") == 1 and "gcc" or "clang"
		vim.health.ok("C compiler found (" .. cc .. ")")
	else
		vim.health.error("no C compiler found (gcc or clang required)")
	end
end

local function check_parsers(settings)
	if vim.tbl_isempty(settings.parsers) then
		vim.health.warn("no parsers configured")
		return
	end

	for name, parser in pairs(settings.parsers) do
		local revision = parser.revision or "master"
		local so_path = settings.data_dir .. "/" .. name .. ".so"
		local rev_path = settings.revision_dir .. "/" .. name .. ".rev"

		local installed_rev
		local f = io.open(rev_path, "r")
		if f then
			installed_rev = f:read("*l")
			f:close()
		end

		local so_exists = vim.fn.filereadable(so_path) == 1

		if so_exists and installed_rev == revision then
			vim.health.ok(name .. " installed @ " .. revision:sub(1, 12))
		elseif so_exists then
			vim.health.warn(
				name
					.. " .so present but revision mismatch (want "
					.. revision:sub(1, 12)
					.. ", have "
					.. (installed_rev or "unknown"):sub(1, 12)
					.. ") — run :lua require('simple-treesitter').install('"
					.. name
					.. "')"
			)
		else
			vim.health.warn(
				name .. " not yet installed @ " .. revision:sub(1, 12) .. " — it will be installed on next startup"
			)
		end
	end
end

M.check = function()
	vim.health.start("simple-treesitter")

	-- Neovim version
	check_neovim_version()

	-- Required tools
	vim.health.start("simple-treesitter: required tools")
	check_executable("curl", true)
	check_executable("tar", true)
	check_executable("make", true)
	check_compilers()

	-- Optional tools
	vim.health.start("simple-treesitter: optional tools")
	check_executable("tree-sitter", false)

	-- Parser status
	vim.health.start("simple-treesitter: parsers")
	local st = require("simple-treesitter").settings
	if not st then
		vim.health.warn("setup() has not been called yet — no parser status available")
		return
	end
	check_parsers(st)
end

return M
