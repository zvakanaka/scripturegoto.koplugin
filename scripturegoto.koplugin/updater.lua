--[[--
Self-update for this plugin: checks a version manifest served over HTTPS,
and if newer, downloads + verifies + installs a replacement copy of this
whole plugin directory.

* The update server's TLS certificate is *pinned*: `update-ca.pem`, bundled
  in this plugin directory, is the exact self-signed certificate the server
  uses, and requests are made with `verify = "peer"` against only that
  file (KOReader's own LuaSec default is `verify = "none"`).
* Independently of TLS, the downloaded archive's SHA-256 is checked against
  the manifest before it's extracted.
* The server is deployment-specific: its manifest URL is the first line of
  `update-server.txt` and its certificate is `update-ca.pem`, both added to
  the plugin directory when a release is packaged (see
  scripts/package-plugin.sh) and neither in the repository. Without them,
  updates are simply unavailable.

The new files replace this plugin's directory on disk, but KOReader keeps
running the old code already loaded until it restarts.
--]]--

local JSON = require("json")
local ltn12 = require("ltn12")
local https = require("ssl.https")
local socket = require("socket")
local socketutil = require("socketutil")
local sha2 = require("ffi/sha2")
local logger = require("logger")

local Updater = {}

-- Overrides update-server.txt when set (tests).
Updater.MANIFEST_URL = nil

-- The manifest URL for this install: the first non-empty line of
-- update-server.txt in the plugin directory.
function Updater:getManifestUrl(plugin_dir)
    if self.MANIFEST_URL then
        return self.MANIFEST_URL
    end
    local f = io.open(plugin_dir .. "/update-server.txt", "r")
    if not f then
        return nil
    end
    local url
    for line in f:lines() do
        url = line:match("^%s*(%S+)")
        if url then break end
    end
    f:close()
    return url
end

-- Versions are "YYYY.MM.DD-N", compared numerically per field: as strings,
-- "2026.09.19-10" would sort before "2026.09.19-9". Anything else falls back
-- to a string comparison rather than failing.
local function isVersionNewer(remote, current)
    local ry, rm, rd, rn = remote:match("^(%d+)%.(%d+)%.(%d+)-(%d+)$")
    local cy, cm, cd, cn = current:match("^(%d+)%.(%d+)%.(%d+)-(%d+)$")
    if not (ry and cy) then
        return remote ~= current and remote > current
    end
    local r = { tonumber(ry), tonumber(rm), tonumber(rd), tonumber(rn) }
    local c = { tonumber(cy), tonumber(cm), tonumber(cd), tonumber(cn) }
    for i = 1, 4 do
        if r[i] ~= c[i] then
            return r[i] > c[i]
        end
    end
    return false
end

function Updater:getCurrentVersion(plugin_dir)
    local f = io.open(plugin_dir .. "/VERSION", "r")
    if not f then
        return nil
    end
    local v = f:read("*l")
    f:close()
    return v and v:gsub("%s+$", "")
end

-- Returns a decoded manifest table {version=, url=, sha256=, size=} plus
-- whether it's newer than what's installed, or nil + error string.
function Updater:checkForUpdate(plugin_dir)
    local current = self:getCurrentVersion(plugin_dir)
    if not current then
        return nil, "could not read local VERSION file"
    end

    local manifest_url = self:getManifestUrl(plugin_dir)
    if not manifest_url then
        return nil, "updates are not configured for this build (no update-server.txt)"
    end

    local ca_file = plugin_dir .. "/update-ca.pem"
    if not io.open(ca_file, "rb") then
        return nil, "update-ca.pem not found in plugin directory"
    end

    local result_chunks = {}
    socketutil:set_timeout(15, 30)
    local ok, code, _headers, status = pcall(function()
        return socket.skip(1, https.request{
            url = manifest_url,
            sink = ltn12.sink.table(result_chunks),
            cafile = ca_file,
            verify = "peer",
        })
    end)
    socketutil:reset_timeout()

    if not ok then
        logger.warn("Updater: manifest fetch raised:", code)
        return nil, "connection failed: " .. tostring(code)
    end
    if code ~= 200 then
        return nil, "server returned " .. tostring(code) .. " " .. tostring(status)
    end

    local raw = table.concat(result_chunks)
    local decode_ok, manifest = pcall(JSON.decode, raw)
    if not decode_ok or type(manifest) ~= "table" or not manifest.version then
        return nil, "bad manifest JSON"
    end

    manifest.current_version = current
    manifest.is_newer = isVersionNewer(manifest.version, current)
    return manifest
end

-- Streams the update archive to disk, verifies its SHA-256 against the manifest, then
-- extracts and atomically swaps it in for plugin_dir. Returns true, or
-- nil + error string.
function Updater:downloadAndInstall(plugin_dir, manifest, progress_cb)
    local parent_dir = plugin_dir:match("^(.*)/[^/]+$")
    if not parent_dir then
        return nil, "could not determine plugin parent directory"
    end

    local ca_file = plugin_dir .. "/update-ca.pem"
    local plugin_name = plugin_dir:match("([^/]+)$")
    local archive_path = parent_dir .. "/" .. plugin_name .. "-update.tar.gz"
    local new_dir = plugin_dir .. ".new"

    os.remove(archive_path)
    local out = io.open(archive_path, "wb")
    if not out then
        return nil, "could not open " .. archive_path .. " for writing"
    end

    if progress_cb then progress_cb("downloading") end

    socketutil:set_timeout(30, 300)
    local ok, code, _headers, status = pcall(function()
        return socket.skip(1, https.request{
            url = manifest.url,
            sink = ltn12.sink.file(out),
            cafile = ca_file,
            verify = "peer",
        })
    end)
    socketutil:reset_timeout()

    if not ok then
        os.remove(archive_path)
        return nil, "download failed: " .. tostring(code)
    end
    if code ~= 200 then
        os.remove(archive_path)
        return nil, "server returned " .. tostring(code) .. " " .. tostring(status)
    end

    if progress_cb then progress_cb("verifying") end

    local verify_ok, verify_err = self:_verifySha256(archive_path, manifest.sha256)
    if not verify_ok then
        os.remove(archive_path)
        return nil, verify_err
    end

    if progress_cb then progress_cb("extracting") end

    os.execute(string.format('rm -rf "%s"', new_dir))
    os.execute(string.format('mkdir -p "%s"', new_dir))
    -- The archive's top-level entry is "scripturegoto.koplugin/..." --
    -- strip it so new_dir itself holds main.lua etc., ready to become the
    -- new plugin directory via a plain rename.
    local extract_status = os.execute(string.format(
        'tar -xzf "%s" --strip-components=1 -C "%s"', archive_path, new_dir))
    -- LuaJIT's os.execute returns the raw shell exit status (0 == success),
    -- not Lua 5.2+'s true/exitcode/signal triple.
    if extract_status ~= 0 or not io.open(new_dir .. "/main.lua", "rb") then
        os.execute(string.format('rm -rf "%s"', new_dir))
        os.remove(archive_path)
        return nil, "extraction failed (tar exit " .. tostring(extract_status) ..
            "); install the plugin by hand instead"
    end

    if progress_cb then progress_cb("installing") end

    -- Keep exactly one backup, not an ever-growing pile of them.
    os.execute(string.format('rm -rf "%s".old-*', plugin_dir))
    local backup_dir = plugin_dir .. ".old-" .. os.time()
    local renamed_old, rename_old_err = os.rename(plugin_dir, backup_dir)
    if not renamed_old then
        os.execute(string.format('rm -rf "%s"', new_dir))
        os.remove(archive_path)
        return nil, "could not move aside current install: " .. tostring(rename_old_err)
    end

    local renamed_new, rename_new_err = os.rename(new_dir, plugin_dir)
    if not renamed_new then
        -- Try to restore the old install rather than leaving the user with
        -- neither a working old nor new copy.
        os.rename(backup_dir, plugin_dir)
        os.execute(string.format('rm -rf "%s"', new_dir))
        os.remove(archive_path)
        return nil, "could not install new version, restored previous one: " .. tostring(rename_new_err)
    end

    os.remove(archive_path)
    return true
end

-- Hashes the file in fixed-size chunks rather than reading it whole.
function Updater:_verifySha256(path, expected_hex)
    local f = io.open(path, "rb")
    if not f then
        return nil, "could not reopen downloaded archive to verify it"
    end
    local feed = sha2.sha256()
    while true do
        local chunk = f:read(65536)
        if not chunk then break end
        feed(chunk)
    end
    f:close()
    local actual_hex = feed()
    if actual_hex ~= expected_hex then
        logger.warn("Updater: checksum mismatch, expected", expected_hex, "got", actual_hex)
        return nil, "checksum mismatch -- downloaded file does not match the manifest"
    end
    return true
end

return Updater
