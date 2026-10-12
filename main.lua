-- AIVision.koplugin (直连模式 v2.0)
-- 长按选段 → 直连智谱 CogView（免费·主力）/ 火山方舟豆包（兜底）→ 本地看图。
-- 无需电脑桥 / 中继 / 域名。Kindle 经 ssl.https 直连国内 API（国内不被 GFW 墙）。

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local json = require("json")
local util = require("util")
local logger = require("logger")

local AIVision = WidgetContainer:extend({
    name = "aivision",
    is_doc_only = false,
})

-- 国内生图端点（均不被墙，Kindle 直连即可）
local ZHIPU_URL    = "https://open.bigmodel.cn/api/paas/v4/images/generations"
local ZHIPU_MODEL  = "cogview-3-flash"               -- 免费档（带 AI 水印）
local DOUBAO_URL   = "https://ark.cn-beijing.volces.com/api/v3/images/generations"
local DOUBAO_MODEL = "doubao-seedream-4-5-251128"    -- 免费 200 张

-- 墨水屏风格后缀：让图更适合电子墨水屏、更易"看懂"
local STYLE_SUFFIX = "，黑白水墨画风格，高对比度，简洁构图，画面纯净无文字，适合电子墨水屏阅读器显示"

-- 预填 Key（可选）。留空则由用户在「设置智谱 Key / 设置豆包 Key」里填写。
-- ⚠️ 开源发布时切勿把真实 Key 写进这里——公开仓库一旦推送，历史无法撤回。
local DEFAULT_ZHIPU_KEY = ""

local _inst = nil

function AIVision:init(ui)
    self.ui = self.ui or ui
    _inst = self
    self.data_dir = DataStorage:getDataDir() .. "/aivision"
    self:_mkdir(self.data_dir)
    self.img_dir = self.data_dir .. "/images"
    self:_mkdir(self.img_dir)
    self.config = self:readJson(self.data_dir .. "/config.json") or {}
    -- 首次启动（无持久化 Key）时启用预填的智谱 Key，避免手动输入
    if (not self.config.zhipu_key or self.config.zhipu_key == "") and DEFAULT_ZHIPU_KEY ~= "" then
        self.config.zhipu_key = DEFAULT_ZHIPU_KEY
    end
    self.queue = self:readJson(self.data_dir .. "/queue.json") or {}

    if self.ui and self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        -- 按钮1：AI 生图 / 查看插图（按场景动态切换）
        -- 选中文字(未高亮)：直接生图并存画廊（不建高亮）
        -- 已有高亮且已绑图：显示「查看插图」
        -- 已有高亮但无图：生图并绑到该高亮
        self.ui.highlight:addToHighlightDialog("99_ai_vision", function(this, index)
            local ann = (index and this.ui and this.ui.annotation) and this.ui.annotation.annotations[index] or nil
            local img = ann and ann.aivision_image or nil
            if img and self:fileExists(img) then
                return {
                    text = "查看插图",
                    callback = function()
                        local ok2, err = pcall(function() self:viewBoundImage(img) end)
                        if not ok2 then logger.warn("AIVision: 查看插图异常", tostring(err)) end
                    end,
                }
            end
            local bind = ann and index or nil
            return {
                text = "AI 生图",
                callback = function()
                    local ok2, err = pcall(function() self:onGenerateFromSelection(this, bind) end)
                    if not ok2 then
                        logger.warn("AIVision: 生图入口异常", tostring(err))
                        pcall(function()
                            UIManager:show(InfoMessage:new{ text = "AI 生图出错：" .. tostring(err) })
                        end)
                    end
                end,
            }
        end)
        -- 按钮2：高亮并生图 / 重绑插图（按场景动态切换）
        -- 选中文字(未高亮)：新建高亮并生图、把图绑到该高亮
        -- 已有高亮：重新生成并覆盖绑定的图
        self.ui.highlight:addToHighlightDialog("98_ai_vision_hl", function(this, index)
            local ann = (index and this.ui and this.ui.annotation) and this.ui.annotation.annotations[index] or nil
            if ann then
                return {
                    text = "重绑插图",
                    callback = function()
                        local ok2, err = pcall(function() self:onGenerateFromSelection(this, index) end)
                        if not ok2 then logger.warn("AIVision: 重绑异常", tostring(err)) end
                    end,
                }
            end
            return {
                text = "高亮并生图",
                callback = function()
                    local ok2, err = pcall(function() self:onHighlightAndGenerate(this) end)
                    if not ok2 then
                        logger.warn("AIVision: 高亮并生图异常", tostring(err))
                        pcall(function()
                            UIManager:show(InfoMessage:new{ text = "AI 生图出错：" .. tostring(err) })
                        end)
                    end
                end,
            }
        end)
        logger.info("AIVision: 选区按钮已注入（AI 生图 / 高亮并生图）")
    end

    -- 菜单条目交给框架自动调用 addToMainMenu（见下方方法），这里不手动插入。
    -- 每个动作单独 pcall 注册：即使某一个失败，插件仍能正常加载（其余入口可用）。
    local ok, Dispatcher = pcall(require, "dispatcher")
    if ok and Dispatcher then
        -- general/reader/device 都置 true，确保「通用 / 阅读 / 设备」各手势分类里都能看到并绑定
        local actions = {
            { name = "ai_vision_gallery",   event = "AiVisionGallery",   title = "AI 生图记录" },
            { name = "ai_vision_setzhipu",  event = "AiVisionSetZhipu",  title = "设置智谱Key" },
            { name = "ai_vision_setdoubao", event = "AiVisionSetDoubao", title = "设置豆包Key" },
        }
        for _, a in ipairs(actions) do
            local rok, rerr = pcall(function()
                Dispatcher:registerAction(a.name, {
                    category = "none", event = a.event, title = a.title,
                    general = true, reader = true, device = true,
                })
            end)
            if not rok then
                logger.warn("AIVision: 注册手势 " .. a.name .. " 失败: " .. tostring(rerr))
            end
        end
    else
        logger.warn("AIVision: Dispatcher 不可用，手势将无法绑定（菜单与选区按钮仍可用）")
    end
end

-- 手势事件入口统一兜底：绝不让异常冒泡到框架导致崩溃
local function safeCall(self, fn, ...)
    local ok, err = pcall(fn, self, ...)
    if not ok then
        logger.warn("AIVision: " .. tostring(fn) .. " 异常: " .. tostring(err))
        pcall(function()
            UIManager:show(InfoMessage:new{ text = "AI 生图出错：" .. tostring(err) })
        end)
    end
end

function AIVision:onAiVisionGallery() safeCall(self, AIVision.showGallery) end
function AIVision:onAiVisionSetZhipu() safeCall(self, AIVision.showSetKey, "zhipu_key", "智谱 CogView") end
function AIVision:onAiVisionSetDoubao() safeCall(self, AIVision.showSetKey, "doubao_key", "豆包 Seedream") end

-- ===== 工具 =====
function AIVision:_mkdir(p)
    pcall(function()
        local lfs = require("libs/libkoreader-lfs")
        lfs.mkdir(p)
    end)
end
function AIVision:fileExists(p)
    local ok, f = pcall(io.open, p, "r")
    if ok and f then f:close(); return true end
    return false
end
function AIVision:fileSize(p)
    local ok, f = pcall(io.open, p, "rb")
    if not ok or not f then return 0 end
    local sz = f:seek("end"); f:close()
    return sz or 0
end
function AIVision:fileDelete(p)
    local ok = pcall(os.remove, p)
    return ok and not self:fileExists(p)
end
-- 人类可读的体积
function AIVision:prettySize(n)
    if not n or n <= 0 then return "0KB" end
    if n < 1024 then return n .. "B" end
    if n < 1024 * 1024 then return string.format("%.0fKB", n / 1024) end
    return string.format("%.1fMB", n / (1024 * 1024))
end
function AIVision:imgPath(id) return self.img_dir .. "/" .. id .. ".png" end

-- ⚠ 关键：Kindle 上 socket.http 不支持 https，连国内 API 必须用 ssl.https（LuaSec）
function AIVision:httpModule(url)
    if type(url) == "string" and url:lower():find("^https://") then
        local ok, https = pcall(require, "ssl.https")
        if ok and https then return https end
    end
    local ok2, http = pcall(require, "socket.http")
    if ok2 and http then return http end
    return nil
end

function AIVision:readJson(path)
    local ok, f = pcall(io.open, path, "r")
    if not ok or not f then return nil end
    local s = f:read("*a"); f:close()
    local ok2, v = pcall(json.decode, s)
    if ok2 and v then return v end
    return nil
end
function AIVision:writeJson(path, v)
    local ok, s = pcall(json.encode, v)
    if not ok then return end
    pcall(function()
        local f = io.open(path, "w")
        if f then f:write(s); f:close() end
    end)
end

-- KOReader 框架在构建 ☰ 菜单时会自动对每个已注册 widget 调用 addToMainMenu(menu_items)，
-- 把条目写进传进来的 menu_items 表即可（readermenu.lua:341）。
function AIVision:addToMainMenu(menu_items)
    menu_items.aivision = {
        text = "AI 生图",
        sub_item_table = {
            {
                text = "AI 生图记录",
                callback = function() self:showGallery() end,
            },
            {
                text = "设置智谱 Key（CogView 免费·主力）",
                callback = function() self:showSetKey("zhipu_key", "智谱 CogView") end,
            },
            {
                text = "设置豆包 Key（Seedream 兜底）",
                callback = function() self:showSetKey("doubao_key", "豆包 Seedream") end,
            },
            {
                text = "🗑 清空历史记录（图片需手动删文件）",
                callback = function() self:confirmClearHistory() end,
            },
        },
    }
end

-- ===== 设置 Key（save_callback 官方机制）=====
function AIVision:showSetKey(key, label)
    local dlg = InputDialog:new{
        title = "设置 " .. label .. " API Key",
        input_hint = "粘贴从官网获取的 Key（留空 = 不用该后端）",
        input_type = "string",
        text = self.config[key] or "",
        _text_modified = true,
        save_callback = function(content, closing)
            local v = (content or ""):gsub("%s+", "")
            self.config[key] = v
            self:writeJson(self.data_dir .. "/config.json", self.config)
            UIManager:show(InfoMessage:new{
                text = (v == "" and (label .. " Key 已清空")) or (label .. " Key 已保存"),
            })
            return true
        end,
    }
    UIManager:show(dlg)
end

-- ===== 选区按钮 → 发送 =====
-- bind_index：可选，传入则生图成功后把图绑定到该高亮（annotations[index].aivision_image）
-- pre_text：可选，调用方预先取出的文字，避免 saveHighlight 后选区被清导致取不到
function AIVision:onGenerateFromSelection(rh, bind_index, pre_text)
    self._pending_bind = bind_index  -- 供延迟调度的 generate 读取
    local text = pre_text or ""
    if (not text or text == "") then
        pcall(function()
            if rh and rh.selected_text and rh.selected_text.text then
                text = util.cleanupSelectedText(rh.selected_text.text)
            end
        end)
    end
    if (not text or text == "") and rh and rh.hold_pos and rh.hold_pos.text then
        text = rh.hold_pos.text
    end
    if not text or text == "" then
        UIManager:show(InfoMessage:new{ text = "没有选中文字" })
        return
    end
    text = text:gsub("%s+", " "):sub(1, 400)

    local book, page = "", ""
    pcall(function()
        local doc = self.ui.document
        if doc then
            local props = doc:getProps()
            book = props and (props.title or "") or ""
            local cp = doc:getCurrentPage()
            page = cp and tostring(cp) or ""
        end
    end)

    local req_id = tostring(os.time()) .. "_" .. tostring(math.random(100000, 999999))
    table.insert(self.queue, 1, {
        id = req_id, text = text, book = book, page = page,
        status = "pending", ts = os.time(),
    })
    -- 只保留最近 MAX_QUEUE 条，更早的记录连带其图片一起清掉（避免无限堆积）
    local MAX_QUEUE = 50
    while #self.queue > MAX_QUEUE do
        local old = table.remove(self.queue)
        if old and old.status == "done" then self:fileDelete(self:imgPath(old.id)) end
    end
    self:writeJson(self.data_dir .. "/queue.json", self.queue)

    pcall(function() rh:onClose() end)

    if (not self.config.zhipu_key or self.config.zhipu_key == "")
       and (not self.config.doubao_key or self.config.doubao_key == "") then
        UIManager:show(InfoMessage:new{
            text = "还没配置 Key！\n去「AI 生图记录」→ 设置智谱 / 豆包 Key",
        })
        return
    end

    local loading = InfoMessage:new{ text = "AI 生图生成中…（直连智谱 → 豆包）" }
    UIManager:show(loading)
    -- 异步触发，先让"生成中"渲染出来，再做阻塞式 HTTPS 请求
    UIManager:scheduleIn(0.3, function()
        self:generate(req_id, text .. STYLE_SUFFIX, book, page)
        pcall(function() UIManager:close(loading) end)
    end)
end

-- ===== 直连生图（智谱主力 / 豆包兜底）=====
function AIVision:generate(req_id, prompt, book, page)
    local tried = {}

    -- 1) 智谱 CogView（免费主力）
    local zkey = self.config.zhipu_key
    if zkey and zkey ~= "" then
        local ok, j = self:httpJsonPost(ZHIPU_URL,
            { ["Authorization"] = "Bearer " .. zkey },
            { model = ZHIPU_MODEL, prompt = prompt, size = "1024x1024", n = 1 })
        if ok then
            local path = self.img_dir .. "/" .. req_id .. ".png"
            local got, why = self:saveFromResponse(j, path)
            if got then
                self:setStatus(req_id, "done", "")
                self:finishWithBind(path, "智谱 CogView")
                return
            end
            table.insert(tried, "智谱:" .. tostring(why))
        else
            table.insert(tried, "智谱:" .. tostring(j))
        end
    else
        table.insert(tried, "智谱:未配置Key")
    end

    -- 2) 豆包 Seedream（兜底）
    local dkey = self.config.doubao_key
    if dkey and dkey ~= "" then
        local ok, j = self:httpJsonPost(DOUBAO_URL,
            { ["Authorization"] = "Bearer " .. dkey },
            { model = DOUBAO_MODEL, prompt = prompt, size = "1024x1024" })
        if ok then
            local path = self.img_dir .. "/" .. req_id .. ".png"
            local got, why = self:saveFromResponse(j, path)
            if got then
                self:setStatus(req_id, "done", "")
                self:finishWithBind(path, "豆包 Seedream")
                return
            end
            table.insert(tried, "豆包:" .. tostring(why))
        else
            table.insert(tried, "豆包:" .. tostring(j))
        end
    else
        table.insert(tried, "豆包:未配置Key")
    end

    self:setStatus(req_id, "failed", table.concat(tried, " | "))
    UIManager:show(InfoMessage:new{
        text = "AI 生图失败：\n" .. table.concat(tried, "\n"),
    })
end

-- 生图成功后的收尾：若本次有绑定高亮则绑定，并给出对应提示
function AIVision:finishWithBind(path, backend)
    local bind = self._pending_bind
    self._pending_bind = nil
    if bind then
        self:bindImageToHighlight(bind, path)
        UIManager:show(InfoMessage:new{ text = "图片生成成功，点击高亮文本查看" })
    else
        UIManager:show(InfoMessage:new{ text = "AI 生图完成（" .. backend .. "）" })
    end
end

-- 把图片路径绑到指定高亮，并随 annotation 一起持久化（不改变原书，仅记在 .sdr 元数据）
function AIVision:bindImageToHighlight(index, path)
    pcall(function()
        local ann = self.ui and self.ui.annotation and self.ui.annotation.annotations[index]
        if not ann then return end
        ann.aivision_image = path
        -- 让框架在关闭文档时一并保存；这里再显式触发一次 annotation 落盘
        if self.ui.annotation.onSaveSettings then
            pcall(self.ui.annotation.onSaveSettings, self.ui.annotation)
        end
    end)
end

-- 高亮并生图：先创建高亮拿到索引，再生图并把图绑到该高亮
function AIVision:onHighlightAndGenerate(rh)
    -- 先取出文字：saveHighlight 后选区可能被清，提前保存最稳
    local text = ""
    pcall(function()
        if rh and rh.selected_text and rh.selected_text.text then
            text = util.cleanupSelectedText(rh.selected_text.text)
        end
    end)
    local index = nil
    pcall(function()
        if rh and rh.saveHighlight then index = rh:saveHighlight() end
    end)
    if not index then
        -- 建高亮失败（例如没有选中文字），退回直接生图
        UIManager:show(InfoMessage:new{ text = "无法创建高亮，已改为直接生图" })
        self:onGenerateFromSelection(rh, nil, text)
        return
    end
    self:onGenerateFromSelection(rh, index, text)
end

-- 查看绑定在高亮上的插图
function AIVision:viewBoundImage(path)
    if not (path and self:fileExists(path)) then
        UIManager:show(InfoMessage:new{ text = "插图文件缺失" })
        return
    end
    local ImageViewer = require("ui/widget/imageviewer")
    UIManager:show(ImageViewer:new{
        file = path,
        dither = true,
        with_title_bar = false,
    })
end

-- 解析生图响应，把图存到 path。返回 (true) 或 (false, why)
function AIVision:saveFromResponse(j, path)
    local item = (j and j.data and j.data[1]) or nil
    if not item then
        return false, "无 data 字段:" .. self:respSummary(j)
    end
    if item.url and item.url ~= "" then
        local ok, why = self:downloadImage(item.url, path)
        if ok then return true end
        return false, "下载失败(" .. tostring(why) .. ")"
    end
    if item.b64_json and item.b64_json ~= "" then
        local dec = self:base64decode(item.b64_json)
        if dec then
            local wok = pcall(function()
                local f = assert(io.open(path, "wb")); f:write(dec); f:close()
            end)
            if wok then return true end
            return false, "写文件失败"
        end
        return false, "base64 解码不可用"
    end
    return false, "响应无 url/b64"
end

function AIVision:respSummary(j)
    local ok, s = pcall(json.encode, j)
    if ok then return s:sub(1, 200) end
    return "未知响应"
end

function AIVision:base64decode(b64)
    local ok, mod = pcall(require, "ffi/util")
    if ok and mod and mod.base64decode then
        local ok2, r = pcall(mod.base64decode, b64)
        if ok2 and r then return r end
    end
    return nil
end

-- POST JSON，返回 (ok, json_or_errmsg)
function AIVision:httpJsonPost(url, headers, body_table)
    local body = json.encode(body_table)
    local resp = {}
    local ok, code = pcall(function()
        local http = self:httpModule(url)
        if not http then return "no_http_module" end
        local ltn12 = require("ltn12")
        local _, c = http.request{
            url = url, method = "POST",
            headers = self:mergeHeaders(headers, {
                ["Content-Type"] = "application/json",
                ["Content-Length"] = tostring(#body),
            }),
            source = ltn12.source.string(body),
            sink = ltn12.sink.table(resp),
        }
        return c
    end)
    if not ok then return false, "Lua错误:" .. tostring(code) end
    if type(code) ~= "number" or code ~= 200 then
        local e = (type(code) == "string") and code or ("HTTP " .. tostring(code))
        return false, e
    end
    local s = table.concat(resp)
    local ok2, j = pcall(json.decode, s)
    if ok2 and j then return true, j end
    return false, "JSON解析失败:" .. s:sub(1, 200)
end

function AIVision:downloadImage(url, path)
    local resp = {}
    local ok, code = pcall(function()
        local http = self:httpModule(url)
        if not http then return "no_http_module" end
        local ltn12 = require("ltn12")
        local _, c = http.request{
            url = url, method = "GET",
            sink = ltn12.sink.table(resp),
        }
        return c
    end)
    if not ok or type(code) ~= "number" or code ~= 200 then
        local e = (type(code) == "string") and code or ("HTTP " .. tostring(code))
        return false, e
    end
    local data = table.concat(resp)
    if not data or #data == 0 then return false, "空响应" end
    local wok = pcall(function()
        local f = assert(io.open(path, "wb")); f:write(data); f:close()
    end)
    if not wok then return false, "写文件失败" end
    return true
end

function AIVision:mergeHeaders(a, b)
    local h = {}
    for k, v in pairs(a or {}) do h[k] = v end
    for k, v in pairs(b or {}) do h[k] = v end
    return h
end

function AIVision:setStatus(req_id, status, err)
    for _, it in ipairs(self.queue) do
        if it.id == req_id then it.status = status; it.error = err; break end
    end
    self:writeJson(self.data_dir .. "/queue.json", self.queue)
end

-- ===== 下拉：记录列表 =====
-- 清空历史记录：只清 queue 列表，不动 images/ 里的图片文件
-- （图片交由用户在文件管理器里自行清理，避免误删）
function AIVision:clearHistory()
    local n = #(self.queue or {})
    self.queue = {}
    self:writeJson(self.data_dir .. "/queue.json", self.queue)
    return n
end

function AIVision:confirmClearHistory()
    local n = #(self.queue or {})
    if n == 0 then
        UIManager:show(InfoMessage:new{ text = "没有记录可清空" })
        return
    end
    UIManager:show(ConfirmBox:new{
        title = "清空历史记录",
        text = "将清空 " .. n .. " 条生成记录。\n\n图片文件不会被删除，如需清理请到：\n" .. self.img_dir,
        ok_text = "清空",
        cancel_text = "取消",
        ok_callback = function()
            local c = self:clearHistory()
            UIManager:show(InfoMessage:new{
                text = "已清空 " .. c .. " 条记录\n图片请到文件夹手动删除",
            })
            self:showGallery()
        end,
    })
end

function AIVision:showGallery()
    local Menu = require("ui/widget/menu")
    local items = {}
    local n_img, total_bytes = 0, 0
    for _, it in ipairs(self.queue or {}) do
        if it.status == "done" then
            n_img = n_img + 1
            total_bytes = total_bytes + self:fileSize(self:imgPath(it.id))
        end
    end

    -- ── 功能区（与设置 Key 同层级，轻点即触发）──
    table.insert(items, {
        text = "🔑 设置智谱 Key（当前：" .. ((self.config.zhipu_key and self.config.zhipu_key ~= "") and "已设" or "空") .. "）",
        callback = function() self:showSetKey("zhipu_key", "智谱 CogView") end,
    })
    table.insert(items, {
        text = "🔑 设置豆包 Key（当前：" .. ((self.config.doubao_key and self.config.doubao_key ~= "") and "已设" or "空") .. "）",
        callback = function() self:showSetKey("doubao_key", "豆包 Seedream") end,
    })
    table.insert(items, {
        text = "🗑 清空历史记录（" .. #(self.queue or {}) .. " 条）",
        callback = function() self:confirmClearHistory() end,
        separator = true,
    })

    -- ── 记录区 ──
    for _, it in ipairs(self.queue or {}) do
        local st, sz = "", ""   -- 必须给初值：failed/pending 分支不赋 sz，拼 nil 会报错
        if it.status == "done" then
            st = "✓"
            local b = self:fileSize(self:imgPath(it.id))
            sz = (b > 0) and ("  " .. self:prettySize(b)) or "  (文件缺失)"
        elseif it.status == "failed" then st = "✗ " .. (it.error or "失败")
        else st = "… 生成中" end
        local body = (it.text or ""):gsub("%s+", " ")
        local label = st .. " " .. body:sub(1, 26) .. ((#body > 26) and "…" or "") .. sz
        table.insert(items, {
            text = label,
            callback = function() self:showImage(it) end,
        })
    end

    local footer = "📁 图片目录：" .. self.img_dir
        .. (n_img > 0 and ("\n共 " .. n_img .. " 张 / " .. self:prettySize(total_bytes)) or "")
    local title = (#(self.queue or {}) == 0)
        and "AI 生图记录（先设置 Key：智谱主力 / 豆包兜底）"
        or "AI 生图记录"
    UIManager:show(Menu:new{
        title = title,
        item_table = items,
        covers_fullscreen = false,
        footer_text = footer,
    })
end

-- ===== 看图 =====
function AIVision:showImage(it)
    if it.status ~= "done" then
        UIManager:show(InfoMessage:new{
            text = it.status == "failed" and ("生成失败：" .. (it.error or "")) or "还在生成中…",
        })
        return
    end
    local path = self:imgPath(it.id)
    if not (self:fileExists(path) and self:fileSize(path) > 0) then
        UIManager:show(InfoMessage:new{
            text = "图片文件缺失，请重新生图",
        })
        return
    end
    local ImageViewer = require("ui/widget/imageviewer")
    UIManager:show(ImageViewer:new{
        file = path,
        dither = true,
        with_title_bar = false,
    })
end

return AIVision
