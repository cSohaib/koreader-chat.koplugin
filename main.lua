local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local History = require("chat_history")
local Api = require("chat_api")

local Chat = InputContainer:extend{ name = "koreader_chat", is_doc_only = false }

local function notify(text)
    UIManager:show(InfoMessage:new{ text = tostring(text) })
end

function Chat:init()
    self.config = LuaSettings:open(DataStorage:getSettingsDir() .. "/koreader_chat.lua")
    self.settings = {
        endpoint = self.config:readSetting("endpoint", "https://api.openai.com/v1/responses"),
        api_key = self.config:readSetting("api_key", ""),
        model = self.config:readSetting("model", ""),
        folder = self.config:readSetting("folder", DataStorage:getDataDir() .. "/chat-history"),
    }
    self.ui.menu:registerToMainMenu(self)
end

function Chat:addToMainMenu(items)
    items.koreader_chat = {
        text = "AI Chat",
        sorting_hint = "tools",
        sub_item_table = {
            { text = "New chat", callback = function() self:compose({ messages = {} }) end },
            { text = "Current chat", enabled_func = function() return self.session ~= nil end,
                callback = function() if self.session then self:view(self.session) end end },
            { text = "Continue previous chat", callback = function() self:chooseChat() end },
            { text = "Settings", sub_item_table = {
                { text = "API key", callback = function() self:editSetting("api_key", "API key (blank for unauthenticated endpoints)", true) end },
                { text = "Model", callback = function() self:editSetting("model", "Model ID") end },
                { text = "Responses endpoint", callback = function() self:editSetting("endpoint", "Full Responses endpoint URL") end },
                { text = "History folder", callback = function() self:editSetting("folder", "History folder") end },
            } },
        },
    }
end

function Chat:editSetting(key, title, password)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = self.settings[key],
        text_type = password and "password" or nil,
        buttons = {{
            { text = "Cancel", callback = function() UIManager:close(dialog) end },
            { text = "Save", callback = function()
                local value = dialog:getInputText():match("^%s*(.-)%s*$")
                if key ~= "api_key" and value == "" then return notify("Please enter a value.") end
                if key == "endpoint" and not value:match("^https?://[^/%s]+") then
                    return notify("Enter a full http:// or https:// Responses URL.")
                end
                if key == "api_key" and value:find("[\r\n]") then return notify("API key must be one line.") end
                if key == "folder" then
                    local ok, err = History.ensureFolder(value)
                    if not ok then return notify("Cannot create folder: " .. tostring(err)) end
                end
                self.settings[key] = value
                self.config:saveSetting(key, value)
                self.config:flush()
                UIManager:close(dialog)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Chat:chooseChat()
    local files, err = History.list(self.settings.folder)
    if not files then return notify("Cannot list conversations: " .. tostring(err)) end
    if #files == 0 then return notify("No saved conversations yet.") end
    local menu
    local items = {}
    for _, name in ipairs(files) do
        local path = self.settings.folder .. "/" .. name
        items[#items + 1] = { text = name, callback = function()
            local messages, load_err = History.load(path)
            if not messages then return notify("Cannot load conversation: " .. tostring(load_err)) end
            UIManager:close(menu)
            self:view({ path = path, messages = messages })
        end }
    end
    menu = Menu:new{ title = "Saved chats", item_table = items }
    menu.close_callback = function() UIManager:close(menu) end
    UIManager:show(menu)
end

function Chat:view(session)
    self.session = session
    if session.viewer then UIManager:close(session.viewer) end
    local text = {}
    for _, message in ipairs(session.messages) do
        text[#text + 1] = (message.role == "user" and "You" or "Assistant") .. ":\n\n" .. message.content
    end
    local viewer
    local pending = #session.messages % 2 == 1
    local action = session.unsaved and "Save again" or pending and "Retry" or "Reply"
    viewer = TextViewer:new{
        title = (session.path and session.path:match("[^/]+$") or "New chat")
            .. (session.unsaved and " (not saved)" or ""),
        text = table.concat(text, "\n\n────────\n\n"),
        buttons_table = {{
            { text = "Close", callback = function() UIManager:close(viewer) end },
            { text = action, callback = function()
                if session.unsaved then
                    if not self:save(session) then return end
                    UIManager:close(viewer)
                    return self:view(session)
                end
                UIManager:close(viewer)
                if pending then self:request(session) else self:compose(session) end
            end },
        }},
    }
    session.viewer = viewer
    viewer.close_callback = function() session.viewer = nil end
    UIManager:show(viewer)
    if viewer.scroll_widget then viewer.scroll_widget:scrollToRatio(1) end
end

function Chat:save(session)
    local err
    if not session.path then session.path, err = History.newPath(self.settings.folder) end
    local ok
    if session.path then ok, err = History.save(session.path, session.messages) end
    session.unsaved = not ok
    if not ok then
        notify("Could not save: " .. tostring(err) .. "\nKeep this chat open and use Save again.")
    end
    return ok
end

function Chat:compose(session)
    self.session = session
    if self.settings.model == "" then return notify("Set a model ID in AI Chat → Settings first.") end
    local dialog
    dialog = InputDialog:new{
        title = "Message",
        input = session.draft or "",
        input_type = "text",
        allow_newline = true,
        buttons = {{
            { text = "Cancel", callback = function()
                session.draft = dialog:getInputText()
                UIManager:close(dialog)
                if #session.messages > 0 then self:view(session) end
            end },
            { text = "Send", callback = function()
                local value = dialog:getInputText()
                if not value:match("%S") then return end
                session.messages[#session.messages + 1] = { role = "user", content = value }
                if not self:save(session) then
                    table.remove(session.messages)
                    session.unsaved = false -- the draft remains in the input widget
                    return
                end
                session.draft = nil
                UIManager:close(dialog)
                self:request(session)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Chat:request(session)
    if self.busy then return notify("A request is already running.") end
    if #session.messages % 2 ~= 1 then return self:view(session) end
    -- Show the saved chat before Wi-Fi's dialog: declining Wi-Fi leaves Retry available.
    self:view(session)
    NetworkMgr:runWhenConnected(function()
        if self.busy then return notify("A request is already running.") end
        if self.settings.model == "" then return notify("Set a model ID in Settings first.") end
        self.busy = true
        Trapper:wrap(function()
            local ok, completed, answer, err = pcall(function()
                return Trapper:dismissableRunInSubprocess(function()
                    return Api.send(self.settings, session.messages)
                end, "Waiting for AI… Tap to cancel.")
            end)
            self.busy = false
            if not ok or not completed or not answer then
                return notify(not ok and "Request failed. Your message is saved."
                    or not completed and "Cancelled. Your message is saved; use Retry."
                    or err or "No response. Your message is saved; use Retry.")
            end
            session.messages[#session.messages + 1] = { role = "assistant", content = answer }
            self:save(session)
            self:view(session)
        end)
    end)
end

return Chat
