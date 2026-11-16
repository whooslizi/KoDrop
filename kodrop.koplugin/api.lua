local CHUNK = 64 * 1024
local MAX_JSON = 64 * 1024
local MAX_PIN_FAILS = 5
local PIN_LOCKOUT = 60

local Api = {}

local function fail(status, msg) error({ status = status, msg = msg }, 0) end

local function inside(p, base)
    return base == "/" or p == base or p:sub(1, #base + 1) == base .. "/"
end

function Api.clean(rel)
    if type(rel) ~= "string" or rel:find("%z") then return nil end
    local parts = {}
    for seg in rel:gmatch("[^/]+") do
        if seg == ".." then return nil end
        if seg ~= "." then parts[#parts + 1] = seg end
    end
    return "/" .. table.concat(parts, "/")
end

function Api.valid_name(n)
    return type(n) == "string" and n ~= "" and n ~= "." and n ~= ".." and #n <= 255
        and not n:find("[/%z]")
end

function Api.multipart(boundary, on_part)
    local delim = "\r\n--" .. boundary
    local buf = "\r\n" -- so the first boundary matches delim too
    local state = "scan"
    local part
    local skip = { write = function() end, close = function() end }
    local function feed(chunk)
        buf = buf .. chunk
        while true do
            if state == "scan" then
                local s, e = buf:find(delim, 1, true)
                if not s then
                    local keep = #delim - 1
                    if #buf > keep then
                        if part then part.write(buf:sub(1, #buf - keep)) end
                        buf = buf:sub(#buf - keep + 1)
                    end
                    return
                end
                if part then
                    part.write(buf:sub(1, s - 1))
                    part.close()
                    part = nil
                end
                buf = buf:sub(e + 1)
                state = "delim"
            elseif state == "delim" then
                if #buf < 2 then return end
                local two = buf:sub(1, 2)
                if two == "--" then state = "done" return end
                if two ~= "\r\n" then fail(400, "Malformed multipart body") end
                buf = buf:sub(3)
                state = "head"
            elseif state == "head" then
                local s, e = buf:find("\r\n\r\n", 1, true)
                if not s then
                    if #buf > 16384 then fail(400, "Multipart headers too large") end
                    return
                end
                part = on_part(buf:sub(1, s - 1)) or skip
                buf = buf:sub(e + 1)
                state = "scan"
            else
                buf = ""
                return
            end
        end
    end
    return feed, function() return state == "done" end
end

function Api.new(opts)
    local lfs, realpath, json, hooks = opts.lfs, opts.realpath, opts.json, opts.hooks
    local root = realpath(opts.root)
    if not root then return nil, "Root folder does not exist: " .. tostring(opts.root) end
    local protect = opts.protect
    if protect and inside(root, protect) then protect = nil end

    local session
    local pin_fails, locked_until = 0, 0

    local function new_token()
        local f = io.open("/dev/urandom", "rb")
        local b = f and f:read(16)
        if f then f:close() end
        b = b or (tostring(math.random()) .. tostring(os.time()) .. tostring({}))
        return (b:gsub(".", function(ch) return string.format("%02x", ch:byte()) end))
    end

    local function allowed(real)
        return real and inside(real, root) and not (protect and inside(real, protect))
    end

    local function resolve(rel)
        local r = Api.clean(rel)
        if not r then fail(400, "Invalid path") end
        local full = r == "/" and root or root .. r
        local real = realpath(full)
        if not real then
            local parent = full:match("^(.*)/[^/]+$")
            real = parent and realpath(parent ~= "" and parent or "/")
            if not real then fail(404, "Not found") end
        end
        if not allowed(real) then fail(403, "Path outside the allowed folder") end
        return full, r
    end

    local function mode(full) return lfs.attributes(full, "mode") end

    local function parent_of(full) return full:match("^(.*)/[^/]+$") end

    local function basename(full) return full:match("([^/]+)$") end

    local function ok(c, t)
        c:respond(200, "application/json", json.encode(t or { ok = true }))
    end

    local function body_json(c)
        local okd, t = pcall(json.decode, c:body(MAX_JSON), json.decode.simple)
        if not okd or type(t) ~= "table" then fail(400, "Invalid JSON body") end
        return t
    end

    local function path_list(t)
        if type(t.paths) ~= "table" or #t.paths == 0 then fail(400, "paths must be a non-empty array") end
        return t.paths
    end

    local function not_root(full)
        if full == root then fail(403, "Cannot modify the root folder") end
    end

    local routes = {}

    routes["GET /"] = function(c)
        c:respond(200, "text/html; charset=utf-8", opts.html)
    end

    routes["POST /api/login"] = function(c)
        local t = body_json(c)
        if not opts.pin then return ok(c) end
        if os.time() < locked_until then fail(429, "Too many attempts, wait a minute") end
        if tostring(t.pin) ~= opts.pin then
            pin_fails = pin_fails + 1
            if pin_fails >= MAX_PIN_FAILS then pin_fails, locked_until = 0, os.time() + PIN_LOCKOUT end
            fail(401, "Wrong PIN")
        end
        pin_fails = 0
        session = session or new_token()
        c:respond(200, "application/json", json.encode({ ok = true }),
            { ["Set-Cookie"] = "kodrop=" .. session .. "; Path=/; HttpOnly; SameSite=Strict" })
    end

    routes["GET /api/ls"] = function(c)
        local full, r = resolve(c.req.query.path or "/")
        if mode(full) ~= "directory" then fail(404, "Not a folder") end
        local entries = {}
        for name in lfs.dir(full) do
            local p = full .. "/" .. name
            local a = name:sub(1, 1) ~= "." and lfs.attributes(p)
            local visible = a and (a.mode == "file" or a.mode == "directory")
                and not (a.mode == "directory" and name:match("%.sdr$"))
            if visible and lfs.symlinkattributes(p, "mode") == "link" then visible = allowed(realpath(p)) end
            if visible and protect and a.mode == "directory" then visible = not inside(realpath(p) or p, protect) end
            if visible then
                entries[#entries + 1] = { name = name, dir = a.mode == "directory", size = a.size, mtime = a.modification }
            end
        end
        table.sort(entries, function(x, y)
            if x.dir ~= y.dir then return x.dir end
            return x.name:lower() < y.name:lower()
        end)
        ok(c, { path = r, entries = entries })
    end

    routes["GET /api/dl"] = function(c)
        local full = resolve(c.req.query.path)
        if mode(full) ~= "file" then fail(404, "Not a file") end
        local f = io.open(full, "rb")
        if not f then fail(403, "Cannot open file") end
        local name = basename(full)
        local ascii = name:gsub('[^%w%.%-_ ()]', "_")
        local encoded = name:gsub("[^%w%.%-_]", function(ch) return string.format("%%%02X", ch:byte()) end)
        local okd, err = pcall(function()
            c:head(200, {
                ["Content-Type"] = "application/octet-stream",
                ["Content-Length"] = tostring(f:seek("end")),
                ["Content-Disposition"] = string.format("attachment; filename=\"%s\"; filename*=UTF-8''%s", ascii, encoded),
            })
            f:seek("set")
            while true do
                local s = f:read(CHUNK)
                if not s then break end
                c:send(s)
                c:pause()
            end
        end)
        f:close()
        if not okd then error(err, 0) end
    end

    routes["POST /api/upload"] = function(c)
        local dir = resolve(c.req.query.path or "/")
        if mode(dir) ~= "directory" then fail(404, "Not a folder") end
        local ctype = c.req.headers["content-type"] or ""
        local boundary = ctype:match('boundary="([^"]+)"') or ctype:match("boundary=([^;%s]+)")
        if not ctype:lower():find("multipart/form-data", 1, true) or not boundary then
            fail(400, "Expected multipart/form-data")
        end
        local remaining = tonumber(c.req.headers["content-length"] or "")
        if not remaining then fail(411, "Content-Length required") end

        local saved, current = {}, nil
        local function unique(name)
            local stem, ext = name:match("^(.+)(%.[^.]+)$")
            if not stem then stem, ext = name, "" end
            local cand, n = name, 1
            while mode(dir .. "/" .. cand) or mode(dir .. "/" .. cand .. ".part") do
                cand = string.format("%s (%d)%s", stem, n, ext)
                n = n + 1
            end
            return cand
        end
        local function on_part(raw)
            local fname = raw:match('[Ff]ilename="([^"]*)"')
            if not fname then return nil end
            fname = fname:gsub("%%22", '"'):match("([^/\\]*)$"):gsub("%c", "")
            if not Api.valid_name(fname) then fail(400, "Invalid file name") end
            local final = unique(fname)
            local part_path = dir .. "/" .. final .. ".part"
            local f, err = io.open(part_path, "wb")
            if not f then fail(500, "Cannot create file: " .. tostring(err)) end
            current = { f = f, part = part_path, final = dir .. "/" .. final, name = final }
            return {
                write = function(s)
                    if s ~= "" and not current.f:write(s) then fail(507, "Write failed (storage full?)") end
                end,
                close = function()
                    current.f:close()
                    local okr, rerr = os.rename(current.part, current.final)
                    if not okr then os.remove(current.part) current = nil fail(500, "Rename failed: " .. tostring(rerr)) end
                    saved[#saved + 1] = current.name
                    current = nil
                end,
            }
        end

        local feed, done = Api.multipart(boundary, on_part)
        local okd, err = pcall(function()
            while remaining > 0 do
                local s = c:recv(math.min(CHUNK, remaining))
                remaining = remaining - #s
                feed(s)
                c:pause()
            end
            if not done() then fail(400, "Upload incomplete") end
        end)
        if current then
            current.f:close()
            os.remove(current.part)
        end
        if #saved > 0 then hooks.changed(dir) end
        if not okd then error(err, 0) end
        ok(c, { ok = true, saved = saved })
    end

    routes["POST /api/mkdir"] = function(c)
        local full = resolve(body_json(c).path)
        if not Api.valid_name(basename(full) or "") then fail(400, "Invalid folder name") end
        if mode(full) then fail(409, "Already exists") end
        local okm, err = lfs.mkdir(full)
        if not okm then fail(500, "mkdir failed: " .. tostring(err)) end
        hooks.changed(parent_of(full))
        ok(c)
    end

    local function move_one(src, dst)
        if mode(dst) then fail(409, "Already exists: " .. basename(dst)) end
        local is_file = mode(src) == "file"
        local okr, err = os.rename(src, dst)
        if not okr then fail(500, "Move failed: " .. tostring(err)) end
        hooks.moved(src, dst, is_file)
        hooks.changed(parent_of(src))
        hooks.changed(parent_of(dst))
    end

    routes["POST /api/rename"] = function(c)
        local t = body_json(c)
        local src = resolve(t.path)
        not_root(src)
        if not mode(src) then fail(404, "Not found") end
        if not Api.valid_name(t.name) then fail(400, "Invalid name") end
        move_one(src, parent_of(src) .. "/" .. t.name)
        ok(c)
    end

    routes["POST /api/move"] = function(c)
        local t = body_json(c)
        local dest = resolve(t.dest)
        if mode(dest) ~= "directory" then fail(404, "Destination is not a folder") end
        local dest_real = realpath(dest)
        for _, p in ipairs(path_list(t)) do
            local src = resolve(p)
            not_root(src)
            if not mode(src) then fail(404, "Not found: " .. tostring(p)) end
            if parent_of(src) ~= dest then
                if inside(dest_real, realpath(src)) then fail(400, "Cannot move a folder into itself") end
                move_one(src, dest .. "/" .. basename(src))
            end
        end
        ok(c)
    end

    routes["POST /api/delete"] = function(c)
        for _, p in ipairs(path_list(body_json(c))) do
            local full = resolve(p)
            not_root(full)
            local m = mode(full)
            if not m then fail(404, "Not found: " .. tostring(p)) end
            local okd
            if m == "directory" then okd = opts.purge_dir(full) else okd = os.remove(full) end
            if not okd then fail(500, "Delete failed: " .. tostring(p)) end
            hooks.deleted(full, m ~= "directory")
            hooks.changed(parent_of(full))
            c:pause()
        end
        ok(c)
    end

    return function(c)
        local req = c.req
        local route = routes[req.method .. " " .. req.path]
        if not route then fail(404, "No such endpoint") end
        if req.path ~= "/" then
            -- custom header forces a CORS preflight, so other sites can't POST here
            if req.method == "POST" and not req.headers["x-kodrop"] then fail(403, "Missing X-KoDrop header") end
            if opts.pin and req.path ~= "/api/login" then
                local cookie = (req.headers.cookie or ""):match("kodrop=(%x+)")
                if not session or cookie ~= session then fail(401, "PIN required") end
            end
        end
        route(c)
    end
end

return Api
