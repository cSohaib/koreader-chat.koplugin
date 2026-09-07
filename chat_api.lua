local json = require("rapidjson")
local Api = {}

-- LuaSec verifies the certificate chain, but leaves hostname verification to
-- its caller. Require a matching SAN; only a whole leftmost DNS label may vary.
function Api.matchesHost(host, names)
    host = host:lower()
    for _, name in ipairs(names or {}) do
        name = name:lower()
        if name == host then return true end
        if not host:match("^[%d.]+$") and not host:find(":", 1, true)
            and name:sub(1, 2) == "*." and name:sub(3):find(".", 1, true)
            and host:match("^[^.]+%.(.+)$") == name:sub(3) then
            return true
        end
    end
    return false
end

function Api.payload(settings, messages)
    return {
        model = settings.model,
        instructions = "You are a helpful assistant. Reply in Markdown. Do not use a line containing only ===; use ATX (#) headings instead.",
        input = messages,
        store = false,
        stream = false,
    }
end

function Api.parse(body, status)
    local ok, data = pcall(json.decode, body)
    if not ok or type(data) ~= "table" then
        return nil, "HTTP " .. tostring(status) .. ": endpoint did not return valid JSON."
    end
    -- RapidJSON's null sentinel is truthy; successful Responses use error: null.
    if tonumber(status) ~= 200 or (data.error and data.error ~= json.null) then
        local message = type(data.error) == "table" and data.error.message
        return nil, "HTTP " .. tostring(status) .. ": "
            .. (type(message) == "string" and message or "request failed")
    end
    if data.status and data.status ~= json.null and data.status ~= "completed" then
        return nil, "Response " .. tostring(data.status) .. ". Retry the saved message."
    end
    local parts = {}
    for _, item in ipairs(type(data.output) == "table" and data.output or {}) do
        if type(item) == "table" and item.type == "message" and item.role == "assistant" then
            for _, part in ipairs(type(item.content) == "table" and item.content or {}) do
                if type(part) == "table" then
                    local text = part.type == "output_text" and part.text
                        or part.type == "refusal" and part.refusal
                    if type(text) == "string" then parts[#parts + 1] = text end
                end
            end
        end
    end
    local text = table.concat(parts, "\n\n")
    if not text:match("%S") then return nil, "The response contained no assistant text." end
    return text
end

function Api.send(settings, messages)
    local http = require("socket.http")
    local https = require("ssl.https")
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local chunks = {}
    local body = json.encode(Api.payload(settings, messages))
    socketutil:set_timeout(120, 120)
    local request = {
        url = settings.endpoint,
        method = "POST",
        redirect = false,
        headers = {
            ["Content-Type"] = "application/json",
            ["Content-Length"] = tostring(#body),
        },
        source = ltn12.source.string(body),
        sink = socketutil.table_sink(chunks),
    }
    if settings.api_key ~= "" then
        request.headers.Authorization = "Bearer " .. settings.api_key
    end
    if settings.endpoint:match("^https://") then
        local create = https.tcp{ verify = "peer", cafile = "data/ca-bundle.crt" }
        request.create = function()
            local connection = create()
            local connect = connection.connect
            function connection:connect(host, port)
                local result, err = connect(self, host, port)
                if not result then return result, err end
                local cert = self.sock:getpeercertificate()
                local san = cert and cert:extensions()["2.5.29.17"] or {}
                local names = (host:match("^[%d.]+$") or host:find(":", 1, true))
                    and san.iPAddress or san.dNSName
                if not Api.matchesHost(host, names) then
                    self:close()
                    return nil, "TLS hostname mismatch"
                end
                return result
            end
            return connection
        end
    end
    local ok, result, status = pcall(http.request, request)
    socketutil:reset_timeout()
    if not ok or not result then
        -- Transport exceptions may contain request details; never expose the key.
        return nil, "Connection failed or timed out. Check Wi-Fi, endpoint and device date. Your message is saved."
    end
    return Api.parse(table.concat(chunks), status)
end

return Api
