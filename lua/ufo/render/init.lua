local api = vim.api
local fn = vim.fn

local highlight = require('ufo.highlight')
local extmark = require('ufo.render.extmark')
local treesitter = require('ufo.render.treesitter')
local match = require('ufo.render.match')
local utils = require('ufo.utils')

local M = {}

local function selecthighestPriorityMark(marks, pos, initMark, concealEabnled)
    local res = initMark
    for _, m in ipairs(marks) do
        local sc, ec, priority = m[2], m[4], m[6]
        local oPriority = res[6]
        if concealEabnled then
            local conceal, oConceal = m[7], res[7]
            if oConceal then
                if conceal and sc < pos and pos <= ec and oPriority <= priority then
                    res = m
                end
            else
                if sc < pos and pos <= ec and (oPriority <= priority or conceal) then
                    res = m
                end
            end
        else
            if sc < pos and pos <= ec and oPriority <= priority then
                res = m
            end
        end
    end
    return res
end

-- 1-indexed
local function syntaxToRowHighlightRange(res, lnum, startCol, endCol)
    local lastIndex = 1
    local lastHlId
    for c = startCol, endCol do
        local hlId = fn.synID(lnum, c, true)
        if lastHlId and lastHlId ~= hlId then
            table.insert(res, {lnum, lastIndex, c - 1, lastHlId})
            lastIndex = c
        end
        lastHlId = hlId
    end
    table.insert(res, {lnum, lastIndex, endCol, lastHlId})
end

local function mapHightlightMarkers(bufnr, startRow, marks, hlGroups, ns)
    for _, m in ipairs(marks) do
        local hlGroup = m[5]
        if next(hlGroups[hlGroup]) then
            local sr, sc = m[1] - startRow, m[2]
            local er, ec = m[3] - startRow, m[4]
            extmark.setHighlight(bufnr, ns, sr, sc, er, ec, hlGroup, m[6])
        end
    end
end

local function mapInlayMarkers(bufnr, startRow, marks, ns)
    for _, m in ipairs(marks) do
        local sr, sc = m[1] - startRow, m[2]
        extmark.setVirtText(bufnr, ns, sr, sc, m[3], {
            priority = m[4],
            virt_text_pos = 'inline'
        })
    end
end

function M.mapHighlightLimitByRange(srcBufnr, dstBufnr, startRange, endRange, text, ns)
    local startRow, startCol = startRange[1], startRange[1]
    local endRow, endCol = endRange[1], endRange[2]
    local nss = {}
    for _, namespace in pairs(api.nvim_get_namespaces()) do
        if ns ~= namespace then
            table.insert(nss, namespace)
        end
    end
    local hlGroups = highlight.hlGroups()
    local hlMarks, inlayMarks = extmark.getHighlightsAndInlayByRange(srcBufnr, startRange, endRange, nss)
    mapHightlightMarkers(dstBufnr, startRow, hlMarks, hlGroups, ns)
    hlMarks = treesitter.getHighlightsByRange(srcBufnr, startRange, endRange, hlGroups)
    mapHightlightMarkers(dstBufnr, startRow, hlMarks, hlGroups, ns)
    if vim.bo[srcBufnr].syntax ~= '' then
        api.nvim_buf_call(srcBufnr, function()
            local res = {}
            local lnum, endLnum = startRow + 1, endRow + 1
            if lnum == endLnum then
                syntaxToRowHighlightRange(res, lnum, startCol + 1, endCol)
            else
                for l = lnum, endLnum - 1 do
                    syntaxToRowHighlightRange(res, l, 1, #text[l - lnum + 1])
                end
                syntaxToRowHighlightRange(res, endLnum, 1, endCol)
            end
            for _, r in ipairs(res) do
                local row = r[1] - lnum
                extmark.setHighlight(dstBufnr, ns, row, r[2] - 1, row, r[3], r[4], 1)
            end
        end)
    end
    mapInlayMarkers(dstBufnr, startRow, inlayMarks, ns)
end

function M.mapMatchByLnum(srcWinid, dstWinid, lnum, endLnum)
    local res = match.mapHighlightsByLnum(srcWinid, lnum, endLnum)
    if not vim.tbl_isempty(res) then
        fn.setmatches(res, dstWinid)
    end
end

function M.setVirtText(bufnr, ns, row, col, virtText, opts)
    return extmark.setVirtText(bufnr, ns, row, col, virtText, opts)
end

function M.captureVirtText(bufnr, text, lnum, syntax, namespaces, concealLevel)
    local len = #text
    if len == 0 then
        return {{'', 'UfoFoldedFg'}}
    end

    local extMarks, inlayMarks = extmark.getHighlightsAndInlayByRange(bufnr, {lnum - 1, 0}, {lnum - 1, len}, namespaces)
    local tsMarks = treesitter.getHighlightsByRange(bufnr, {lnum - 1, 0}, {lnum - 1, len})

    local hlGroups = highlight.hlGroups()
    local hlMarks = {}

    local concealEabnled = concealLevel > 0
    for _, m in ipairs(extMarks) do
        local hlGroup, conceal = m[5], m[7]
        if (concealEabnled and conceal) or (hlGroup and hlGroups[hlGroup].foreground) then
            if m[4] == -1 then
                m[4] = len
            end
            table.insert(hlMarks, m)
        end
    end

    for _, m in ipairs(tsMarks) do
        local hlGroup, conceal = m[5], m[7]
        if (concealEabnled and conceal) or (hlGroup and hlGroups[hlGroup].foreground) then
            if m[4] == -1 then
                m[4] = len
            end
            table.insert(hlMarks, m)
        end
    end

    local default = {0, 1, 0, len, 'UfoFoldedFg', 1}
    table.sort(inlayMarks, function(a, b)
        local aCol, bCol, aPriority, bPriority = a[2], b[2], a[4], b[4]
        return aCol < bCol or (aCol == bCol and aPriority < bPriority)
    end)

    local virtText = {}
    local inlayMark = table.remove(inlayMarks)
    local newChunk = true
    local lastSynConceal
    for i = 1, len do
        local mark = selecthighestPriorityMark(hlMarks, i, default, concealEabnled)
        if syntax and mark == default then
            mark = {0, i, 0, i, -1, -1}
            -- already accounts for concealLevel
            local concealed = api.nvim_buf_call(bufnr, function() return fn.synconcealed(lnum, i) end)
            if concealed[1] == 1 then
                mark[5] = 'conceal'
                mark[7] = concealed[2]
                if concealed[3] ~= lastSynConceal then
                    mark[2] = i - 1 -- inserts coneal chunk
                    lastSynConceal = concealed[3]
                end
            else
                mark[5] = api.nvim_buf_call(bufnr, function() return fn.synID(lnum, i, true) end)
            end

            if mark[5] == 'Normal' then
                mark[5] = 'UfoFoldedFg'
            end
        end
        local startCol, hlGroup, conceal = mark[2], mark[5], mark[7]

        -- process text
        if concealEabnled and conceal then
            if startCol == i - 1 and concealLevel < 3 then
                table.insert(virtText, {conceal, hlGroup})
            end
            newChunk = true
        else
            local lastChunk = virtText[#virtText] or {}
            if newChunk or hlGroup ~= lastChunk[2] then
                table.insert(virtText, {{i, i}, hlGroup})
                newChunk = false
            else
                lastChunk[1][2] = i
            end
        end

        -- insert inlay hints
        while inlayMark and inlayMark[2] == i do
            for _, chunk in ipairs(inlayMark[3]) do
                table.insert(virtText, chunk)
            end
            inlayMark = table.remove(inlayMarks)
            newChunk = true
        end
    end

    for _, chunk in ipairs(virtText) do
        local e1 = chunk[1]
        if type(e1) == 'table' then
            local sc, ec = e1[1], e1[2]
            chunk[1] = text:sub(sc, ec)
        end
    end
    return virtText
end

---Prefer use nvim_buf_set_extmark rather than matchaddpos, only use matchaddpos if buffer is shared
---with multiple windows in current tabpage.
---Check out https://github.com/neovim/neovim/issues/20208 for detail.
---@param handle number
---@param hlGroup string
---@param ns number
---@param start number
---@param finish number
---@param delay? number
---@param shared? boolean
---@return Promise
function M.highlightLinesWithTimeout(handle, hlGroup, ns, start, finish, delay, shared)
    vim.validate({
        handle = {handle, 'number'},
        hlGoup = {hlGroup, 'string'},
        ns = {ns, 'number'},
        start = {start, 'number'},
        finish = {finish, 'number'},
        delay = {delay, 'number', true},
        shared = {shared, 'boolean', true},
    })
    local ids = {}
    local onFulfilled
    if shared then
        local prior = 10
        local l = {}
        for i = start, finish do
            table.insert(l, {i})
            if i % 8 == 0 then
                table.insert(ids, fn.matchaddpos(hlGroup, l, prior))
                l = {}
            end
        end
        if #l > 0 then
            table.insert(ids, fn.matchaddpos(hlGroup, l, prior))
        end
        onFulfilled = function()
            for _, id in ipairs(ids) do
                pcall(fn.matchdelete, id, handle)
            end
        end
    else
        local o = {hl_group = hlGroup}
        for i = start, finish do
            local row, col = i - 1, 0
            o.end_row = i
            o.end_col = 0
            table.insert(ids, api.nvim_buf_set_extmark(handle, ns, row, col, o))
        end
        onFulfilled = function()
            for _, id in ipairs(ids) do
                pcall(api.nvim_buf_del_extmark, handle, ns, id)
            end
        end
    end
    return utils.wait(delay or 300):thenCall(onFulfilled)
end

return M
