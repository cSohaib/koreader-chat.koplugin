-- Run from the repository root: luajit tests/run.lua
package.path = "./?.lua;" .. package.path
package.preload["libs/libkoreader-lfs"] = function() return require("lfs") end
local lfs = require("lfs")
local History = require("chat_history")
local passed = 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if not ok then error(name .. ": " .. tostring(err)) end
    passed = passed + 1
    print("PASS " .. name)
end
local function equal(a, b) assert(a == b, tostring(a) .. " ~= " .. tostring(b)) end
local function message(role, text) return { role = role, content = text } end

test("Markdown round trip preserves delimiters, escapes, Unicode and whitespace", function()
    local messages = {
        message("user", "\nHello مرحبا\n===\n\\===\n\\\\===\n\n"),
        message("assistant", "# Reply\n\n```\n===\n```\n"),
        message("user", "Continue\n\n"),
    }
    local loaded = assert(History.decode(History.encode(messages)))
    equal(#loaded, 3)
    for i, item in ipairs(messages) do
        equal(loaded[i].role, item.role)
        equal(loaded[i].content, item.content)
    end
end)

test("Plain Markdown imports and CRLF are accepted", function()
    local loaded = assert(History.decode("Hello\r\n\r\n===\r\n\r\nHi\r\n"))
    equal(#loaded, 2)
    equal(loaded[1].content, "Hello")
    equal(loaded[2].role, "assistant")
    equal(loaded[2].content, "Hi")
end)

test("Empty and malformed conversations are rejected", function()
    for _, text in ipairs({ "", "\n", "===\ntext", "text\n===", "text\n===\n===\nend" }) do
        assert(not History.decode(text))
    end
    assert(not pcall(History.encode, { message("assistant", "wrong role") }))
end)

local temporary = os.tmpname()
os.remove(temporary)
assert(lfs.mkdir(temporary))
test("Save, restart, resume, list and filename collision", function()
    local folder = temporary .. "/nested/chats"
    local date = os.date
    os.date = function() return "20260907180000" end
    local path = assert(History.newPath(folder))
    os.date = date
    local messages = { message("user", "First question") }
    assert(History.save(path, messages))
    os.date = function() return "20260907180000" end
    local other = assert(History.newPath(folder))
    os.date = date
    assert(other ~= path)
    equal(other:match("[^/]+$"), "20260907180000-1.md")
    -- Simulate process restart: no in-memory state is reused.
    messages = assert(History.load(path))
    equal(#messages, 1)
    messages[2] = message("assistant", "First answer")
    messages[3] = message("user", "Follow-up")
    assert(History.save(path, messages))
    equal(#assert(History.load(path)), 3)
    local f = assert(io.open(folder .. "/ignored.tmp", "w")); f:close()
    assert(lfs.mkdir(folder .. "/directory.md"))
    equal(#assert(History.list(folder)), 1)
    assert(not History.save(folder .. "/missing/file.md", messages))
    os.remove(folder .. "/ignored.tmp")
    lfs.rmdir(folder .. "/directory.md")
    os.remove(path)
    lfs.rmdir(folder)
    lfs.rmdir(temporary .. "/nested")
end)

test("Failed atomic replacement leaves previous history intact", function()
    local path = temporary .. "/existing.md"
    assert(History.save(path, { message("user", "original") }))
    local rename = os.rename
    os.rename = function() return nil, "simulated disk failure" end
    local ok = History.save(path, { message("user", "replacement") })
    os.rename = rename
    assert(not ok)
    equal(assert(History.load(path))[1].content, "original")
    assert(not lfs.attributes(path .. ".tmp"))
    os.remove(path)
end)
lfs.rmdir(temporary)

-- Stub the bundled JSON codec, not the Responses output parser. Production
-- uses KOReader's rapidjson; these tests need only Lua and LuaFileSystem.
local fixture, encoded
package.preload.rapidjson = function() return {
    encode = function(value) encoded = value; return "request-json" end,
    decode = function(value) if value == "invalid" then error("invalid JSON") end; return fixture end,
} end
local Api = require("chat_api")
test("Payload replays all roles with storage disabled and no response ID", function()
    local messages = { message("user", "Q"), message("assistant", "A"), message("user", "More") }
    local payload = Api.payload({ model = "custom-model" }, messages)
    equal(payload.input, messages)
    equal(payload.model, "custom-model")
    equal(payload.store, false)
    equal(payload.stream, false)
    equal(payload.previous_response_id, nil)
end)

test("Extracts all assistant text blocks and ignores reasoning", function()
    fixture = { status = "completed", output = {
        { type = "reasoning", summary = {} },
        { type = "message", role = "assistant", content = {
            { type = "output_text", text = "One" }, { type = "output_text", text = "Two" },
        } },
    } }
    equal(Api.parse("valid", 200), "One\n\nTwo")
end)

test("Handles refusals, API errors, empty, incomplete and invalid responses", function()
    fixture = { output = {{ type = "message", role = "assistant", content = {{ type = "refusal", refusal = "No" }} }} }
    equal(Api.parse("valid", 200), "No")
    fixture = { error = { message = "Quota exceeded" } }
    local text, err = Api.parse("valid", 429)
    assert(not text and err:find("Quota exceeded", 1, true))
    fixture = { status = "incomplete", output = {} }
    assert(not Api.parse("valid", 200))
    fixture = { output = {} }
    assert(not Api.parse("valid", 200))
    assert(not Api.parse("invalid", 502))
    fixture = "wrong shape"
    assert(not Api.parse("valid", 200))
end)

test("TLS SAN matching rejects unrelated hosts and broad wildcards", function()
    assert(Api.matchesHost("api.openai.com", { "*.openai.com" }))
    assert(Api.matchesHost("API.OPENAI.COM", { "api.openai.com" }))
    assert(not Api.matchesHost("openai.com", { "*.openai.com" }))
    assert(not Api.matchesHost("a.b.openai.com", { "*.openai.com" }))
    assert(not Api.matchesHost("api.attacker.com", { "*.openai.com" }))
    assert(not Api.matchesHost("attacker.com", { "*.com" }))
    assert(not Api.matchesHost("127.0.0.1", { "*.0.0.1" }))
end)

local request_hook, reset = nil, false
for _, name in ipairs({ "socket.http", "ssl.https", "ltn12", "socketutil" }) do package.loaded[name] = nil end
package.preload["socket.http"] = function() return { request = function(request) return request_hook(request) end } end
package.preload["ssl.https"] = function() return { tcp = function(settings)
    equal(settings.verify, "peer")
    equal(settings.cafile, "data/ca-bundle.crt")
    return function() return {} end
end } end
package.preload.ltn12 = function() return { source = { string = function(body) return body end } } end
package.preload.socketutil = function() return {
    set_timeout = function() reset = false end,
    reset_timeout = function() reset = true end,
    table_sink = function(chunks) return function(chunk) chunks[#chunks + 1] = chunk; return 1 end end,
} end
test("HTTP request uses exact endpoint, auth, full input and disables redirects", function()
    fixture = { output = {{ type = "message", role = "assistant", content = {{ type = "output_text", text = "Answer" }} }} }
    request_hook = function(request)
        equal(request.url, "https://example.com/custom/responses")
        equal(request.headers.Authorization, "Bearer test-key")
        equal(request.method, "POST")
        equal(request.redirect, false)
        assert(request.create)
        request.sink("valid")
        return 1, 200
    end
    equal(Api.send({ endpoint = "https://example.com/custom/responses", api_key = "test-key", model = "test" }, { message("user", "Q") }), "Answer")
    assert(reset)
    equal(encoded.input[1].content, "Q")
end)
test("Transport errors reset timeout and never expose request credentials", function()
    request_hook = function() error("secret-key") end
    local answer, err = Api.send({ endpoint = "http://localhost/responses", api_key = "secret-key", model = "test" }, {})
    assert(not answer and not err:find("secret-key", 1, true))
    assert(reset)
end)

-- Exercise the UI controller using lightweight KOReader widget doubles.
local widgets = {}
local Widget = {}
function Widget:new(o) setmetatable(o, { __index = self }); widgets[#widgets + 1] = o; return o end
function Widget:extend(o) return setmetatable(o, { __index = self }) end
function Widget:onShowKeyboard() end
function Widget:getInputText() return self.input end
for _, module in ipairs({ "container/inputcontainer", "inputdialog", "infomessage", "menu", "textviewer" }) do
    package.preload["ui/widget/" .. module] = function() return Widget end
end
local shown = {}
package.preload["ui/uimanager"] = function() return {
    show = function(_, widget) shown[widget] = true end,
    close = function(_, widget) shown[widget] = nil end,
} end
package.preload["ui/network/manager"] = function() return { runWhenConnected = function(_, fn) fn() end } end
local cancelled = false
package.preload["ui/trapper"] = function() return {
    wrap = function(_, fn) fn() end,
    dismissableRunInSubprocess = function(_, fn) if cancelled then return false end; return true, fn() end,
} end
package.preload.datastorage = function() return {} end
package.preload.luasettings = function() return {} end
local Chat = require("main")
local chat = Chat:new{ settings = { model = "test", folder = "/unused" } }
local real_save, real_send = History.save, Api.send
local stored, sends = nil, 0
History.save = function(_, messages) stored = History.encode(messages); return true end
Api.send = function(_, messages) sends = sends + 1; equal(#messages % 2, 1); return "Reply" end

test("UI send persists user before calling API, then closes the old viewer", function()
    local session = { path = "/unused/chat.md", messages = {} }
    chat:compose(session)
    local dialog = widgets[#widgets]
    dialog.input = "Question"
    dialog.buttons[1][2].callback()
    equal(#session.messages, 2)
    equal(#assert(History.decode(stored)), 2)
    equal(sends, 1)
    local viewers = 0
    for widget in pairs(shown) do if widget.buttons_table then viewers = viewers + 1 end end
    equal(viewers, 1)
    equal(session.viewer.buttons_table[1][2].text, "Reply")
end)
test("Cancellation leaves a saved user turn and Retry completes it exactly once", function()
    cancelled = true
    local session = { path = "/unused/pending.md", messages = { message("user", "Pending") } }
    chat:request(session)
    equal(#session.messages, 1)
    equal(session.viewer.buttons_table[1][2].text, "Retry")
    equal(chat.busy, false)
    cancelled = false
    session.viewer.buttons_table[1][2].callback()
    equal(#session.messages, 2)
    equal(sends, 2)
    chat:request(session) -- stale retry must not resend an answered turn
    equal(sends, 2)
end)
test("Failed reply save offers Save again without another API request", function()
    History.save = function() return nil, "disk full" end
    local session = { path = "/unused/failure.md", messages = { message("user", "Q") } }
    chat:request(session)
    equal(#session.messages, 2)
    equal(session.viewer.buttons_table[1][2].text, "Save again")
    local count = sends
    History.save = function() return true end
    session.viewer.buttons_table[1][2].callback()
    equal(sends, count)
    equal(session.viewer.buttons_table[1][2].text, "Reply")
end)
History.save, Api.send = real_save, real_send
print(string.format("\n%d tests passed", passed))
