-- profile_to_folded.lua
-- SWT profile tree → Firegraph folded stack 转换器
--
-- SWT profile.c dump() 返回的节点格式：
--   {
--     name = "func_name source_file:line",
--     value = record_time_us,    -- inclusive（含所有子节点）
--     count = hit_count,
--     rettime = ret_time,
--     alloc_count = alloc_count,
--     children = { [1] = {...}, [2] = {...} }  -- 可选
--   }
--
-- Firegraph 需要的 folded stack 格式：
--   "root;func1;subfunc 120\nroot;func2 45\n"
--   每行格式：分号分隔的调用栈 + 空格 + self_time
--
-- 转换规则（文档 §7.2）：
--   self_count = node.value - sum(children.value)
--   仅当 self_count > 0 时输出当前路径

local M = {}

-- 递归遍历 SWT profile tree，生成 folded stack 行
-- @param node     当前节点
-- @param path     当前调用路径（如 "root;func1"）
-- @param lines    收集 folded 行的列表
local function traverse_tree(node, path, lines)
    local raw_name = node.name or "?"
    -- 清理名称：提取函数名（去除文件:行号后缀），替换分号避免格式冲突
    local clean_name = raw_name:match("^(%S+)") or raw_name
    clean_name = clean_name:gsub(";", "_")

    local current_path
    if path == "" then
        current_path = clean_name
    else
        current_path = path .. ";" .. clean_name
    end

    local self_value = node.value or 0
    local children = node.children or {}

    -- 累加所有子节点的 value，并递归处理子节点
    local children_total = 0
    for _, child in ipairs(children) do
        children_total = children_total + (child.value or 0)
        traverse_tree(child, current_path, lines)
    end

    -- self = inclusive - sum(children)
    -- 仅当 self > 0 时才输出，避免重复计算
    self_value = self_value - children_total
    if self_value > 0 then
        table.insert(lines, current_path .. " " .. self_value)
    end
end

-- convert: 将 SWT profile.stop() 的返回值转换为 folded stack 字符串
-- @param swt_result  profile.stop() 返回的表：{ time = record_time, nodes = root_node }
-- @return folded_text  folded stack 格式的字符串
function M.convert(swt_result)
    if not swt_result or not swt_result.nodes then
        return ""
    end

    local lines = {}
    local root = swt_result.nodes

    if root.children then
        for _, child in ipairs(root.children) do
            traverse_tree(child, "", lines)
        end
    else
        -- 无子节点时直接输出根节点
        local name = (root.name or "?"):gsub(";", "_")
        table.insert(lines, name .. " " .. (root.value or 0))
    end

    return table.concat(lines, "\n")
end

-- convert_multi: 将多个 service 的 profile 结果分别转换
-- @param results   { [service_name] = swt_result, ... }
-- @return { [service_name] = folded_text, ... }
function M.convert_multi(results)
    local output = {}
    for svc, result in pairs(results) do
        local folded = M.convert(result)
        if folded ~= "" then
            output[svc] = folded
        end
    end
    return output
end

return M