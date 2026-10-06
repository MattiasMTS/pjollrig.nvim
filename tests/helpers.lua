local H = {}
local uv = vim.uv
H.plugin = uv.cwd()
vim.cmd.runtime("plugin/pjollrig.lua")

function H.tmp()
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  return uv.fs_realpath(d)
end

function H.git(dir, ...)
  local r = vim
    .system({
      "git",
      "-C",
      dir,
      "-c",
      "user.name=t",
      "-c",
      "user.email=t@t",
      "-c",
      "commit.gpgsign=false",
      "-c",
      "core.hooksPath=/dev/null",
      ...,
    }, { text = true })
    :wait()
  assert(r.code == 0, table.concat({ ... }, " ") .. ": " .. (r.stderr or ""))
  return vim.trim(r.stdout)
end

function H.write(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
end

---Git repo with the given files committed on `main`; returns its realpath.
function H.repo(files)
  local d = H.tmp()
  H.git(d, "init", "-q", "-b", "main")
  for name, lines in pairs(files or { ["a.lua"] = { "one", "two", "three" } }) do
    H.write(d .. "/" .. name, lines)
  end
  H.git(d, "add", ".")
  H.git(d, "commit", "-qm", "base")
  return d
end

---Fresh state dir, no windows/buffers, no fake modules.
function H.reset(opts)
  vim.env.XDG_STATE_HOME = H.tmp()
  vim.cmd("silent! tabonly! | silent! only! | enew! | silent! %bwipeout!")
  package.loaded["pjollrig.github"] = nil
  require("pjollrig.store").mem = {}
  require("pjollrig").setup(opts or {})
end

---Run a child nvim with the plugin on the rtp and the current state dir.
function H.nvim(args, env)
  local argv = { "nvim", "--clean", "--headless", "--cmd", "set rtp^=" .. H.plugin }
  return vim.system(vim.list_extend(argv, args), {
    text = true,
    env = vim.tbl_extend("force", { XDG_STATE_HOME = vim.env.XDG_STATE_HOME }, env or {}),
  })
end

function H.marks(buf)
  local ns = vim.api.nvim_create_namespace("pjollrig")
  return vim.api.nvim_buf_get_extmarks(buf or 0, ns, 0, -1, { details = true })
end

---Directory of executable shims; each logs its argv (and stdin) to <dir>/<name>.log.
function H.shims(scripts)
  local d = H.tmp()
  for name, body in pairs(scripts) do
    H.write(d .. "/" .. name, { "#!/bin/sh", body })
    vim.fn.setfperm(d .. "/" .. name, "rwxr-xr-x")
  end
  vim.env.PATH = d .. ":" .. vim.env.PATH
  return d
end

return H
