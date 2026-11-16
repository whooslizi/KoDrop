local dir = "kodrop.koplugin/"

local clock = 0
package.preload.socket = function() return { gettime = function() clock = clock + 0.001 return clock end } end
package.preload.logger = function() return { warn = print } end

local Api = dofile(dir .. "api.lua")
local Server = dofile(dir .. "server.lua")

assert(Api.clean("/") == "/")
assert(Api.clean("") == "/")
assert(Api.clean("a//b/./c/") == "/a/b/c")
assert(Api.clean("/etc/passwd") == "/etc/passwd")
assert(Api.clean("../x") == nil)
assert(Api.clean("/a/../../x") == nil)
assert(Api.clean("a\0b") == nil)
assert(Api.clean(nil) == nil)
assert(Api.valid_name("book.epub") and not Api.valid_name("..") and not Api.valid_name("a/b") and not Api.valid_name(""))

local boundary = "----WebKitFormBoundaryX"
local payload1 = ("\r\n--" .. boundary:sub(1, 10)) .. string.rep("A\r\n-", 50)
local payload2 = "second file"
local body = "--" .. boundary .. "\r\n"
    .. 'Content-Disposition: form-data; name="file"; filename="a.epub"\r\nContent-Type: application/epub+zip\r\n\r\n'
    .. payload1 .. "\r\n--" .. boundary .. "\r\n"
    .. 'Content-Disposition: form-data; name="note"\r\n\r\nignored\r\n--' .. boundary .. "\r\n"
    .. 'Content-Disposition: form-data; name="file"; filename="b.txt"\r\n\r\n'
    .. payload2 .. "\r\n--" .. boundary .. "--\r\n"

local function parse(chunks)
    local files, cur = {}, nil
    local feed, done = Api.multipart(boundary, function(h)
        local name = h:match('filename="([^"]*)"')
        if not name then return nil end
        cur = { name = name, data = {} }
        return {
            write = function(s) table.insert(cur.data, s) end,
            close = function() files[#files + 1] = { cur.name, table.concat(cur.data) } end,
        }
    end)
    for _, c in ipairs(chunks) do feed(c) end
    return files, done()
end

for split = 1, #body do
    local files, done = parse({ body:sub(1, split), body:sub(split + 1) })
    assert(done, "not done at split " .. split)
    assert(#files == 2, "file count at split " .. split)
    assert(files[1][1] == "a.epub" and files[1][2] == payload1, "payload1 at split " .. split)
    assert(files[2][1] == "b.txt" and files[2][2] == payload2, "payload2 at split " .. split)
end
local bytes = {}
for i = 1, #body do bytes[i] = body:sub(i, i) end
local files = parse(bytes)
assert(#files == 2 and files[1][2] == payload1, "byte-by-byte parse")
local _, done = parse({ body:sub(1, #body - 10) })
assert(not done, "truncated body must not be done")

local tmp = os.tmpname()
os.remove(tmp)
assert(os.execute("mkdir " .. tmp))
local fake_lfs = {
    attributes = function(p, what)
        local m
        if p == tmp then m = "directory"
        else local f = io.open(p, "rb") if f then f:close() m = "file" end end
        if what then return m end
        return m and { mode = m }
    end,
}
local function realpath(p)
    if p == tmp or fake_lfs.attributes(p, "mode") then return p end
end
local changed = {}
local handler = Api.new{
    root = tmp, html = "<html>", lfs = fake_lfs, realpath = realpath,
    json = { encode = function(t) return t.error and ('{"error":"' .. t.error .. '"}') or "{}" end },
    hooks = { changed = function(d) changed[#changed + 1] = d end },
}

local function fake_sock(input)
    local pos, out, calls = 1, {}, 0
    local s = {}
    function s:receive(pat, prefix)
        calls = calls + 1
        if calls % 3 == 0 then return nil, "timeout", prefix or "" end
        if pat == "*l" then
            local e = input:find("\n", pos, true)
            if not e then return nil, "closed", prefix or "" end
            local line = input:sub(pos, e - 1):gsub("\r", "")
            pos = e + 1
            return (prefix or "") .. line
        end
        local n = math.min(pat, 7)
        local data = input:sub(pos, pos + n - 1)
        pos = pos + #data
        if data == "" then return nil, "closed", "" end
        return nil, "timeout", data
    end
    function s:send(d, i) out[#out + 1] = d:sub(i) return #d end
    function s:close() end
    function s:settimeout() end
    function s:setoption() end
    return s, out
end

local function request(raw)
    local sock, out = fake_sock(raw)
    local accepted = false
    local srv = setmetatable({
        sock = { accept = function() if not accepted then accepted = true return sock end end },
        handler = handler, encode = function(t) return t.error or "" end,
        conns = {}, last_activity = 0,
    }, Server)
    for _ = 1, 100000 do
        srv:tick()
        if accepted and #srv.conns == 0 then break end
    end
    return table.concat(out)
end

local upload = "POST /api/upload?path=%2F HTTP/1.1\r\nHost: k\r\nX-KoDrop: 1\r\n"
    .. "Content-Type: multipart/form-data; boundary=" .. boundary .. "\r\n"
    .. "Content-Length: " .. #body .. "\r\n\r\n" .. body
local resp = request(upload)
assert(resp:match("^HTTP/1.0 200"), resp)
local f = assert(io.open(tmp .. "/a.epub", "rb"))
assert(f:read("*a") == payload1, "uploaded content mismatch")
f:close()
assert(not io.open(tmp .. "/a.epub.part", "rb"), ".part left behind")
assert(changed[1] == tmp, "FileManager refresh hook not called")

assert(request(upload):match("^HTTP/1.0 200"))
assert(io.open(tmp .. "/a (1).epub", "rb"), "duplicate name not uniquified")

resp = request(upload:sub(1, #upload - 40))
assert(not resp:match("^HTTP/1.0 200"), "truncated upload accepted")
local listing = io.popen("ls '" .. tmp .. "'"):read("*a")
assert(listing:find("b (2).txt", 1, true) == nil and not listing:find(".part", 1, true),
    ".part left after truncated upload:\n" .. listing)

assert(request("POST /api/upload?path=%2F HTTP/1.1\r\nContent-Length: 0\r\n\r\n"):match("^HTTP/1.0 403"))
assert(request("GET /api/dl?path=..%2Fetc%2Fpasswd HTTP/1.1\r\n\r\n"):match("^HTTP/1.0 400"))
assert(request("GET / HTTP/1.1\r\n\r\n"):match("<html>$"))

os.execute("rm -rf '" .. tmp .. "'")
print("kodrop spec: all checks passed")
