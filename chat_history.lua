local lfs = require("libs/libkoreader-lfs")
local History = {}

-- Escape the reserved line and its escaped forms, reversibly. Model compliance
-- is helpful, but never required for the integrity of the conversation file.
local function escape(text)
    return (text:gsub("([^\n]*)", function(line)
        if line:match("^\\*===$") then return "\\" .. line end
        return line
    end))
end

local function unescape(text)
    return (text:gsub("([^\n]*)", function(line)
        if line:match("^\\+===$") then return line:sub(2) end
        return line
    end))
end

function History.encode(messages)
    local parts = {}
    for i, message in ipairs(messages) do
        assert(message.role == (i % 2 == 1 and "user" or "assistant"), "Invalid message order")
        assert(type(message.content) == "string" and message.content:match("%S"), "Empty message")
        parts[i] = escape(message.content:gsub("\r\n", "\n"))
    end
    return table.concat(parts, "\n\n===\n\n") .. "\n"
end

function History.decode(text)
    text = text:gsub("\r\n", "\n")
    if text:sub(-1) == "\n" then text = text:sub(1, -2) end
    local messages, lines = {}, {}
    local function finish()
        local content = unescape(table.concat(lines, "\n"))
        if not content:match("%S") then return nil, "Empty message in conversation." end
        messages[#messages + 1] = {
            role = #messages % 2 == 0 and "user" or "assistant",
            content = content,
        }
        lines = {}
        return true
    end
    local after_separator = false
    for line in (text .. "\n"):gmatch("(.-)\n") do
        if line == "===" then
            if lines[#lines] == "" then table.remove(lines) end
            local ok, err = finish()
            if not ok then return nil, err end
            after_separator = true
        elseif after_separator and line == "" then
            after_separator = false -- remove only our one padding line
        else
            after_separator = false
            lines[#lines + 1] = line
        end
    end
    local ok, err = finish()
    if not ok then return nil, err end
    return messages
end

function History.ensureFolder(folder)
    if lfs.attributes(folder, "mode") == "directory" then return true end
    local parent = folder:gsub("/+$", ""):match("^(.*)/[^/]+$")
    if parent and parent ~= "" and parent ~= folder then
        local ok, err = History.ensureFolder(parent)
        if not ok then return nil, err end
    end
    return lfs.mkdir(folder)
end

function History.list(folder)
    local ok, err = History.ensureFolder(folder)
    if not ok then return nil, err end
    local files = {}
    local success, failure = pcall(function()
        for name in lfs.dir(folder) do
            if name:match("%.md$") and lfs.attributes(folder .. "/" .. name, "mode") == "file" then
                files[#files + 1] = name
            end
        end
    end)
    if not success then return nil, failure end
    table.sort(files, function(a, b) return a > b end)
    return files
end

function History.newPath(folder)
    local ok, err = History.ensureFolder(folder)
    if not ok then return nil, err end
    local stem = folder .. "/" .. os.date("%Y%m%d%H%M%S")
    local path, suffix = stem .. ".md", 0
    while lfs.attributes(path) do
        suffix = suffix + 1
        path = stem .. "-" .. suffix .. ".md"
    end
    return path
end

function History.load(path)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    local text, read_err = file:read("*a")
    file:close()
    if not text then return nil, read_err end
    return History.decode(text)
end

function History.save(path, messages)
    local ok, text = pcall(History.encode, messages)
    if not ok then return nil, text end
    local temporary = path .. ".tmp"
    local file, err = io.open(temporary, "wb")
    if not file then return nil, err end
    local written, write_err = file:write(text)
    local closed, close_err = file:close()
    if not written or not closed then
        os.remove(temporary)
        return nil, write_err or close_err
    end
    local renamed, rename_err = os.rename(temporary, path)
    if not renamed then os.remove(temporary) end
    return renamed, rename_err
end

return History
