--[[
=====================================================================
 《千星奇域》小游戏：坦克动荡（Tank Trouble 2 / 坦克动荡2 · 4399 flash 版）
 客户端 UI 脚本  ·  Lua 5.3

 美术方案（不使用任何外部贴图）：
   仅需编辑器自带的「白色方块」「白色圆形」两个基础形状模板 + 一个文本框模板，
   通过拉伸 / 旋转 / 上色 / 多控件拼接，在运行时拼出：
     坦克（履带·履带节·车体·斜面·高光·炮塔·炮管·炮口 共15部件）、
     炮弹（底圆+主圆+高光）、导弹（弹体+头圆+尾翼+尾焰）、
     破片弹、地雷（雷刺+三层圆）、补给箱（包装带+中心圆）、
     立体墙壁（墙面+顶亮条+底暗条）。

 迷宫：N×N 正方形网格，DFS 擦除部分网格线段生成（道路严格等宽），
       再随机多开若干缺口形成环路；连续墙段自动合并成长条。

 操作：
   WASD / 方向键：前进、后退、原地左转、原地右转
   Q / 回车：开火（不支持回车的运行时自动改用空格）
   普通炮弹无限反弹，10 秒后消失，每辆坦克场上最多 5 发
   碾过补给箱拾取七种武器：
     加特林 · 激光 · 遥控导弹 · 追踪导弹 · 地雷 · 破片弹 · 死亡射线（穿墙激光）
   遥控导弹：发射后移动键改为控导弹，再按开火键引爆
   破片弹：发射后再按开火键手动引爆，不按则 3 秒后自动引爆
   死亡射线：蓄力 2 秒发射，穿透内部薄墙、被迷宫边界挡住
=====================================================================
]]

--==================== ① 模板 ID（只需 3 个：方块 / 圆 / 文本）====================
local PREFAB = {
    SQUARE = 1073741868, -- 白色方块（Stretch）：墙/车体/履带/炮管/补给箱/遮罩 等
    CIRCLE = 1073741869, -- 白色圆形（Stretch）：炮塔/炮弹/地雷/导弹头/高光 等
    TEXT   = 1073741871, -- 文本框模板
}

--==================== ② 可调参数 ====================
local CFG = {
    -- 场地
    ARENA_SIZE  = 780,          -- 竞技场边长（UI 单位）
    GRID_N      = 10,           -- 迷宫每边格数（道路 = 正方形网格）
    WALL_T      = 8,            -- 墙厚
    TANK_R      = 16,           -- 坦克碰撞半径（道路宽约76，宽松通行）
    -- 机动（已按原版节奏重新标定：每秒约2格）
    TURN_SPEED  = 3.0,          -- 转向角速度（弧度/秒，约172°/秒）
    MOVE_SPEED  = 155,          -- 前进速度
    BACK_SPEED  = 100,          -- 倒车速度
    -- 普通炮弹（官方 BULLET_*）
    SHELL_LIFE  = 10.0,         -- BULLET_MAX_LIFETIME
    SHELL_SPEED = 380,
    SHELL_R     = 3,
    MAX_SHELLS  = 5,            -- BULLET_AMMO_COUNT
    FIRE_CD     = 0.35,
    -- 加特林（官方 GATLING_GUN_*）
    MG_AMMO     = 20,           -- GATLING_GUN_AMMO_COUNT
    MG_CD       = 0.12,         -- GATLING_GUN_FIRE_RATE
    MG_SPREAD   = 0.10,         -- GATLING_GUN_BULLET_SPREAD
    MG_LIFE     = 2.0,          -- GATLING_GUN_MAX_LIFETIME
    MG_SPEED    = 430,
    MG_R        = 2.5,
    MAX_MG      = 20,
    -- 激光（官方 LASER_*）
    LASER_AMMO    = 1,
    LASER_CD      = 0.5,
    LASER_LOCK    = 0.2,        -- LASER_LOCK_TIME
    LASER_MAXLEN  = 2200,
    LASER_BOUNCES = 4,
    BEAM_WIDTH    = 5,
    BEAM_LIFE     = 0.18,
    -- 追踪导弹（官方 HOMING_MISSILE_*）
    HOMING_AMMO     = 1,
    HOMING_LIFE     = 10.0,     -- HOMING_MISSILE_MAX_LIFETIME
    HOMING_ACTIVATE = 2.0,      -- HOMING_MISSILE_ACTIVATION_TIME
    HOMING_SPEED    = 260,
    HOMING_TURN     = 3.5,      -- [标定] 追踪转向角速度
    HOMING_CD       = 0.5,
    -- 遥控导弹（flash 独有，在线版已移除）
    RC_AMMO   = 1,
    RC_LIFE   = 10.0,           -- [标定]
    RC_SPEED  = 280,            -- [标定]
    RC_TURN   = 3.0,            -- [标定]
    RC_CD     = 0.5,
    -- 破片弹（flash 独有 Frag Bomb）
    FRAG_AMMO = 1,
    FRAG_LIFE = 3.0,            -- [标定] 3 秒自动引爆
    FRAG_SPEED= 380,            -- [标定] 与普通弹同速反弹
    FRAG_CD   = 0.5,
    -- 死亡射线（flash 独有 Death Ray）
    DEATH_AMMO    = 1,
    DEATH_CHARGE  = 2.0,        -- 蓄力 2 秒（攻略明确 two seconds to charge）
    DEATH_MAXLEN  = 1200,       -- [标定] 射程
    DEATH_CD      = 0.5,
    -- 地雷（官方 MINE_*）
    MINE_AMMO     = 3,          -- MINE_AMMO_COUNT
    MINE_CD       = 0.35,
    MINE_ARM      = 0.5,        -- MINE_ACTIVATION_DELAY
    MINE_DETONATE = 0.4,        -- MINE_DETONATION_DELAY
    MINE_TRIGGER  = 26,
    -- 爆炸 / 破片
    BLAST_R         = 78,       -- [标定] 直接杀伤半径
    SHRAPNEL_COUNT  = 30,       -- MINE_NUM_SHRAPNEL
    SHRAPNEL_LIFE   = 0.7,      -- [标定]
    SHRAPNEL_SPEED  = 340,
    SHRAPNEL_R      = 2,
    FLASH_LIFE      = 0.32,     -- 爆炸闪光动画时长
    -- 补给箱
    CRATE_FIRST     = 3.0,
    CRATE_SPAWN_MIN = 3.0,      -- 刷新间隔 3~8 秒
    CRATE_SPAWN_VAR = 5.0,
    CRATE_MAX       = 3,
    CRATE_SAFE      = 130,      -- [标定] 刷新点与坦克最小距离
    -- 回合
    ROUND_GAP     = 2.2,
    EXTRA_OPEN    = 0.10,       -- 迷宫生成后额外擦除墙段比例（制造环路）
}

--==================== ③ 颜色与调色工具 ====================
local function C(r, g, b, a) return Color(math.floor(r), math.floor(g), math.floor(b), a or 255) end

local COLOR = {
    SCREEN    = C(20, 22, 28),          -- 全屏遮罩（盖住初始草地）
    FLOOR     = C(44, 47, 55),          -- 竞技场地板
    FLOOR_LINE= C(56, 60, 70),          -- 地板砖缝
    WALL      = C(125, 135, 148),       -- 墙面
    WALL_TOP  = C(167, 176, 188),       -- 墙顶亮条
    WALL_SIDE = C(76, 83, 94),          -- 墙底暗条
    PLAYER    = C(224, 82, 70),         -- 玩家红
    ENEMY     = C(87, 184, 88),         -- 电脑绿
    SHELL_P   = C(255, 207, 125),
    SHELL_E   = C(200, 245, 200),
    TEXT      = C(245, 245, 245),
    TEXT_OUT  = C(20, 20, 24),
    LABEL     = C(30, 30, 34),
    FLAME     = C(255, 170, 60),
}

-- 同色系明暗：f>1 变亮，f<1 变暗
-- 注意：ColorValue 没有 .r/.g/.b 字段，必须用 Color.ToRGBA 拆包
local function shade(color, f)
    local r, g, b, a = Color.ToRGBA(color)
    return C(math.min(255, r * f), math.min(255, g * f),
             math.min(255, b * f), a)
end
-- 同色改透明度
local function withAlpha(color, a)
    local r, g, b = Color.ToRGBA(color)
    return C(r, g, b, a)
end

--==================== ④ 武器定义 ====================
local WEAPONS = {
    normal   = { name = "普通炮",   ammo = 0 },
    gatling  = { name = "加特林",   ammo = CFG.MG_AMMO,
                 color = C(255, 205, 70),  label = "枪" },
    laser    = { name = "激光",     ammo = CFG.LASER_AMMO,
                 color = C(90, 220, 255),  label = "激" },
    rc       = { name = "遥控导弹", ammo = CFG.RC_AMMO,
                 color = C(255, 150, 60),  label = "控" },
    homing   = { name = "追踪导弹", ammo = CFG.HOMING_AMMO,
                 color = C(255, 90, 180),  label = "追" },
    mine     = { name = "地雷",     ammo = CFG.MINE_AMMO,
                 color = C(200, 110, 255), label = "雷" },
    frag     = { name = "破片弹",   ammo = CFG.FRAG_AMMO,
                 color = C(120, 255, 150), label = "片" },
    deathray = { name = "死亡射线", ammo = CFG.DEATH_AMMO,
                 color = C(255, 80, 140),  label = "穿" },
}
local CRATE_ORDER = { "gatling", "laser", "rc", "homing", "mine", "frag", "deathray" }

-- 弹种参数：kind 决定撞墙/到期行为
local PTYPE = {
    normal   = { life = CFG.SHELL_LIFE,  speed = CFG.SHELL_SPEED,
                 r = CFG.SHELL_R, kind = "bounce" },
    mg       = { life = CFG.MG_LIFE,     speed = CFG.MG_SPEED,
                 r = CFG.MG_R,    kind = "bounce" },
    homing   = { life = CFG.HOMING_LIFE, speed = CFG.HOMING_SPEED,
                 r = 6, kind = "homing" },
    rc       = { life = CFG.RC_LIFE,     speed = CFG.RC_SPEED,
                 r = 7, kind = "bomb" },
    frag     = { life = CFG.FRAG_LIFE,   speed = CFG.FRAG_SPEED,
                 r = 7, kind = "frag" },
    shrapnel = { life = CFG.SHRAPNEL_LIFE, speed = CFG.SHRAPNEL_SPEED,
                 r = CFG.SHRAPNEL_R, kind = "shard" },
}
local CAUSE = {
    normal = "炮弹", mg = "加特林子弹", homing = "追踪导弹", rc = "遥控导弹",
    frag = "破片弹", shrapnel = "弹片", laser = "激光", mine = "地雷",
    deathray = "死亡射线", blast = "爆炸",
}

--==================== ⑤ 运行时状态 ====================
---@type ClientUIContainerControl|nil
local host = nil
local walls = {}                 -- 碰撞矩形 {x,y,w,h,border?}
local wallCtrls = {}             -- 墙壁全部控件（含亮/暗条）
local projs = {}
local mines = {}
local beams = {}
local effects = {}               -- 爆炸闪光等动画 {ctl,t,life,r0,r1,color}
local crates = {}
local createdCtrls = {}
local player, enemy
local statusText, scoreText, weaponText, hintText
local input = { fwd = false, back = false, left = false, right = false }
local pScore, eScore = 0, 0
local roundState = "playing"
local roundTimer = 0
local logicPaused = false
local halfS, cell
local crateTimer = CFG.CRATE_FIRST
local N = CFG.GRID_N

-- 前置声明
local killTank
local updateHUDAll
local revertWeapon
local explodeAt
local detonateBomb
local onSpecialEnd
local disposeParts
local partsVisible

--==================== ⑥ 通用工具 ====================
local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi else return v end
end

local function angleDiff(a, b)
    local d = a - b
    while d > math.pi do d = d - 2 * math.pi end
    while d < -math.pi do d = d + 2 * math.pi end
    return d
end

-- 渲染层级说明：
-- 不再调用 SetSiblingIndex（同一帧数百次重排会触发 Unity Canvas 重入式重建导致卡死）。
-- 改为「创建顺序即层级」：后创建的控件显示在上方。
-- 全局创建顺序：遮罩 → 地板 → 地砖 → 坦克 → [每回合]墙壁 → 战中诞生的补给箱/地雷/炮弹
-- LAYER 表仅作为调用处的语义标记保留，不参与实际重排。
local LAYER = {
    COVER  = 1, BG = 2, LINES = 3, CRATE = 4, MINE = 5, TANK = 6,
    WALL   = 7, PROJ = 8, BEAM = 9, EFFECT = 10, HUD = 11,
}

---@return ClientUIControl|nil
local function createControl(prefabIndex, parent, _layer)
    local ok, ctl = pcall(game.InstantiateClientUIControl, prefabIndex, parent)
    if not ok or ctl == nil then
        printerr("[坦克动荡] 创建控件失败，prefabIndex=" .. tostring(prefabIndex)
            .. "，请检查模板ID：" .. tostring(ctl))
        return nil
    end
    pcall(function()
        ctl:SetAnchorMin(0.5, 0.5)
        ctl:SetAnchorMax(0.5, 0.5)
        ctl:SetPivot(0.5, 0.5)
    end)
    table.insert(createdCtrls, ctl)
    return ctl --[[@as ClientUIControl]]
end

local function destroyControl(ctl)
    if ctl ~= nil then pcall(game.DestroyClientUIControl, ctl) end
end

local function allTanks()
    return { player, enemy }
end

--==================== ⑦ 部件组（方块/圆拼接，整体平移旋转）====================
-- 一个部件 = 一个控件 + 相对组中心的局部坐标(lx,ly) + 局部旋转lrot
local function newPart(shape, w, h, color, lx, ly, lrot, layer)
    local ctl = createControl(shape == "circle" and PREFAB.CIRCLE or PREFAB.SQUARE, host, layer)
    if ctl == nil then return nil end
    pcall(function()
        ctl:SetSizeDelta(w, h)
        ctl.imageColor = color
        ctl.imageType = Enum.ImageType.Stretch
    end)
    return { ctl = ctl, lx = lx or 0, ly = ly or 0, lrot = lrot or 0 }
end

local function addPart(list, shape, w, h, color, lx, ly, lrot, layer)
    local p = newPart(shape, w, h, color, lx, ly, lrot, layer)
    if p ~= nil then table.insert(list, p) end
end

-- 组整体同步到世界 (x,y,theta)
local function syncParts(parts, x, y, theta)
    local ct, st = math.cos(theta), math.sin(theta)
    local deg = math.deg(theta)
    for _, p in ipairs(parts) do
        local wx = x + p.lx * ct - p.ly * st
        local wy = y + p.lx * st + p.ly * ct
        p.ctl:SetAnchoredPosition(wx, wy)
        p.ctl:SetLocalRotation(0, 0, deg + math.deg(p.lrot))
    end
end

function partsVisible(parts, v)
    for _, p in ipairs(parts) do
        pcall(function() p.ctl:SetVisible(v) end)
    end
end

function disposeParts(parts)
    if parts == nil then return end
    for _, p in ipairs(parts) do destroyControl(p.ctl) end
end

--==================== ⑧ 碰撞几何 ====================
local function resolveCircleRect(t, radius, rect)
    local closestX = clamp(t.x, rect.x - rect.w / 2, rect.x + rect.w / 2)
    local closestY = clamp(t.y, rect.y - rect.h / 2, rect.y + rect.h / 2)
    local dx, dy = t.x - closestX, t.y - closestY
    local d2 = dx * dx + dy * dy
    if d2 >= radius * radius then return false end
    if d2 > 1e-8 then
        local d = math.sqrt(d2)
        local push = radius - d
        t.x = t.x + dx / d * push
        t.y = t.y + dy / d * push
    else
        local penX = rect.w / 2 - math.abs(t.x - rect.x)
        local penY = rect.h / 2 - math.abs(t.y - rect.y)
        if penX < penY then
            t.x = t.x + (t.x >= rect.x and penX or -penX)
        else
            t.y = t.y + (t.y >= rect.y and penY or -penY)
        end
    end
    return true
end

local function circleHitsRect(x, y, radius, rect)
    local closestX = clamp(x, rect.x - rect.w / 2, rect.x + rect.w / 2)
    local closestY = clamp(y, rect.y - rect.h / 2, rect.y + rect.h / 2)
    local dx, dy = x - closestX, y - closestY
    return dx * dx + dy * dy < radius * radius
end

-- 扫掠圆 vs 矩形外扩区：防高速弹单帧穿墙
local function sweptCircleRect(x1, y1, x2, y2, radius, rect)
    local minX = rect.x - rect.w / 2 - radius
    local maxX = rect.x + rect.w / 2 + radius
    local minY = rect.y - rect.h / 2 - radius
    local maxY = rect.y + rect.h / 2 + radius
    local dx, dy = x2 - x1, y2 - y1
    local tmin, tmax = 0.0, 1.0
    if math.abs(dx) < 1e-9 then
        if x1 < minX or x1 > maxX then return false end
    else
        local t1, t2 = (minX - x1) / dx, (maxX - x1) / dx
        if t1 > t2 then t1, t2 = t2, t1 end
        tmin = math.max(tmin, t1); tmax = math.min(tmax, t2)
        if tmin > tmax then return false end
    end
    if math.abs(dy) < 1e-9 then
        if y1 < minY or y1 > maxY then return false end
    else
        local t1, t2 = (minY - y1) / dy, (maxY - y1) / dy
        if t1 > t2 then t1, t2 = t2, t1 end
        tmin = math.max(tmin, t1); tmax = math.min(tmax, t2)
        if tmin > tmax then return false end
    end
    return tmax >= 0
end

local function segmentHitsRect(x1, y1, x2, y2, r)
    local dx, dy = x2 - x1, y2 - y1
    local tmin, tmax = 0, 1
    local minX, maxX = r.x - r.w / 2, r.x + r.w / 2
    local minY, maxY = r.y - r.h / 2, r.y + r.h / 2
    if math.abs(dx) < 1e-9 then
        if x1 < minX or x1 > maxX then return false end
    else
        local t1, t2 = (minX - x1) / dx, (maxX - x1) / dx
        if t1 > t2 then t1, t2 = t2, t1 end
        tmin = math.max(tmin, t1); tmax = math.min(tmax, t2)
        if tmin > tmax then return false end
    end
    if math.abs(dy) < 1e-9 then
        if y1 < minY or y1 > maxY then return false end
    else
        local t1, t2 = (minY - y1) / dy, (maxY - y1) / dy
        if t1 > t2 then t1, t2 = t2, t1 end
        tmin = math.max(tmin, t1); tmax = math.min(tmax, t2)
        if tmin > tmax then return false end
    end
    return true
end

-- 射线 vs 矩形集合；dx,dy 单位方向；返回 距离/命中点/撞面('x'竖面/'y'横面)
local function rayWalls(x, y, dx, dy, maxDist, list)
    local bestD, bestX, bestY, bestFace
    for _, r in ipairs(list) do
        local minX, maxX = r.x - r.w / 2, r.x + r.w / 2
        local minY, maxY = r.y - r.h / 2, r.y + r.h / 2
        local t1, t2 = -math.huge, math.huge
        local tx, ty = -math.huge, -math.huge
        if math.abs(dx) < 1e-9 then
            if x < minX or x > maxX then goto continue end
        else
            t1 = (minX - x) / dx; t2 = (maxX - x) / dx
            if t1 > t2 then t1, t2 = t2, t1 end
            tx = (dx > 0) and t1 or t2
        end
        if math.abs(dy) < 1e-9 then
            if y < minY or y > maxY then goto continue end
        else
            local s1, s2 = (minY - y) / dy, (maxY - y) / dy
            if s1 > s2 then s1, s2 = s2, s1 end
            t1 = math.max(t1, s1); t2 = math.min(t2, s2)
            ty = (dy > 0) and s1 or s2
        end
        if t1 <= t2 and t2 >= 0 then
            local entry = (t1 < 0) and 0 or t1
            if entry <= maxDist then
                local d = entry
                if bestD == nil or d < bestD then
                    bestD = d
                    bestX = x + dx * d
                    bestY = y + dy * d
                    bestFace = (tx > ty) and "x" or "y"
                end
            end
        end
        ::continue::
    end
    return bestD, bestX, bestY, bestFace
end

local function distPointSeg(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    if len2 < 1e-8 then
        return math.sqrt((px - ax) ^ 2 + (py - ay) ^ 2)
    end
    local t = clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1)
    local cx, cy = ax + t * dx, ay + t * dy
    return math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2)
end

local function raycastBlocked(x, y, dx, dy, maxDist)
    for _, wl in ipairs(walls) do
        if segmentHitsRect(x, y, x + dx * maxDist, y + dy * maxDist, wl) then
            return true
        end
    end
    return false
end

--==================== ⑨ 迷宫（正方形网格擦线段：DFS + 额外环路）====================
-- 墙段布尔表：
--   V[c][r]：c=0..N，r=0..N-1，位于格子 c-1 与 c 之间的竖线段
--   H[c][r]：c=0..N-1，r=0..N，位于格子 r-1 与 r 之间的横线段
local V, H

local function wallTablesInit()
    V, H = {}, {}
    for c = 0, N do
        V[c] = {}
        for r = 0, N - 1 do V[c][r] = true end
    end
    for r = 0, N do
        H[r] = {}
        for c = 0, N - 1 do H[r][c] = true end
    end
end

-- 打通格子 (c,r) 与邻居之间的墙段
local function openTo(c, r, dir)
    if dir == 0 and c < N then     -- 右
        V[c + 1][r] = false
    elseif dir == 1 and r < N then -- 下
        H[r + 1][c] = false
    elseif dir == 2 and c > 0 then -- 左
        V[c][r] = false
    elseif dir == 3 and r > 0 then -- 上
        H[r][c] = false
    end
end

-- 递归回溯 DFS 生成完美迷宫
local function generateMaze()
    wallTablesInit()
    local visited = {}
    for i = 1, N * N do visited[i] = false end
    local stack = { { c = 0, r = 0 } }
    visited[1] = true
    while #stack > 0 do
        local top = stack[#stack]
        local c, r = top.c, top.r
        local dirs = { 0, 1, 2, 3 }
        for i = 4, 2, -1 do
            local j = math.random(i)
            dirs[i], dirs[j] = dirs[j], dirs[i]
        end
        local moved = false
        for _, d in ipairs(dirs) do
            local nc, nr = c, r
            if d == 0 then nc = c + 1 elseif d == 1 then nr = r + 1
            elseif d == 2 then nc = c - 1 else nr = r - 1 end
            if nc >= 0 and nc < N and nr >= 0 and nr < N and not visited[nr * N + nc + 1] then
                openTo(c, r, d)
                visited[nr * N + nc + 1] = true
                table.insert(stack, { c = nc, r = nr })
                moved = true
                break
            end
        end
        if not moved then table.remove(stack) end
    end

    -- 额外随机擦除部分内部墙段，形成环路（坦克动荡地图环路较多）
    local internal = {}
    for c = 1, N - 1 do
        for r = 0, N - 1 do table.insert(internal, { "v", c, r }) end
    end
    for r = 1, N - 1 do
        for c = 0, N - 1 do table.insert(internal, { "h", c, r }) end
    end
    for i = #internal, 2, -1 do
        local j = math.random(i)
        internal[i], internal[j] = internal[j], internal[i]
    end
    local extra = math.floor(#internal * CFG.EXTRA_OPEN)
    for i = 1, extra do
        local seg = internal[i]
        if seg[1] == "v" then V[seg[2]][seg[3]] = false
        else H[seg[3]][seg[2]] = false end
    end
end

-- 格子 (c,r) 中心的世界坐标
local function cellCenter(c, r)
    return -halfS + (c + 0.5) * cell, -halfS + (r + 0.5) * cell
end

-- 世界坐标 → 格子索引
local function cellOf(x, y)
    local c = math.floor((x + halfS) / cell)
    local r = math.floor((y + halfS) / cell)
    return clamp(c, 0, N - 1), clamp(r, 0, N - 1)
end

-- 由墙段布尔表生成碰撞矩形（合并连续墙段）与立体墙壁控件
local function buildWallsFromTables()
    local T = CFG.WALL_T

    -- 碰撞矩形：边界 + 内部（按连续段合并）
    walls = {}
    table.insert(walls, { x = -(halfS + T / 2), y = 0, w = T, h = N * cell + 2 * T, border = true })
    table.insert(walls, { x =  (halfS + T / 2), y = 0, w = T, h = N * cell + 2 * T, border = true })
    table.insert(walls, { x = 0, y = -(halfS + T / 2), w = N * cell + 2 * T, h = T, border = true })
    table.insert(walls, { x = 0, y =  (halfS + T / 2), w = N * cell + 2 * T, h = T, border = true })

    -- 竖墙：按列合并连续 true
    for c = 1, N - 1 do
        local r = 0
        while r < N do
            if V[c][r] then
                local r0 = r
                while r < N and V[c][r] do r = r + 1 end
                local len = (r - r0) * cell
                local x = -halfS + c * cell
                local y = -halfS + (r0 + 0.5) * cell + cell / 2 - cell / 2
                y = -halfS + r0 * cell + len / 2
                table.insert(walls, { x = x, y = y, w = T, h = len + T })
            else r = r + 1 end
        end
    end
    -- 横墙：按行合并连续 true
    for r = 1, N - 1 do
        local c = 0
        while c < N do
            if H[r][c] then
                local c0 = c
                while c < N and H[r][c] do c = c + 1 end
                local len = (c - c0) * cell
                local x = -halfS + c0 * cell + len / 2
                local y = -halfS + r * cell
                table.insert(walls, { x = x, y = y, w = len + T, h = T })
            else c = c + 1 end
        end
    end
end

-- 墙壁立体视觉：每段墙 = 主面 + 顶/左亮条 + 底/右暗条
local function buildWallVisuals()
    for _, ctl in ipairs(wallCtrls) do destroyControl(ctl) end
    wallCtrls = {}
    for _, wl in ipairs(walls) do
        local main = createControl(PREFAB.SQUARE, host, LAYER.WALL)
        if main ~= nil then
            pcall(function()
                main:SetSizeDelta(wl.w, wl.h)
                main.imageColor = COLOR.WALL
                main.imageType = Enum.ImageType.Stretch
            end)
            main:SetAnchoredPosition(wl.x, wl.y)
            table.insert(wallCtrls, main)

            -- 亮条（顶部/左侧内缩2px）与暗条（底部/右侧）
            if wl.h > wl.w then
                -- 竖墙：左右两侧做明暗
                local lit = createControl(PREFAB.SQUARE, host, LAYER.WALL)
                if lit ~= nil then
                    pcall(function()
                        lit:SetSizeDelta(2, wl.h - 4)
                        lit.imageColor = COLOR.WALL_TOP
                        lit.imageType = Enum.ImageType.Stretch
                    end)
                    lit:SetAnchoredPosition(wl.x - wl.w / 2 + 2, wl.y)
                    table.insert(wallCtrls, lit)
                end
                local dark = createControl(PREFAB.SQUARE, host, LAYER.WALL)
                if dark ~= nil then
                    pcall(function()
                        dark:SetSizeDelta(2, wl.h - 4)
                        dark.imageColor = COLOR.WALL_SIDE
                        dark.imageType = Enum.ImageType.Stretch
                    end)
                    dark:SetAnchoredPosition(wl.x + wl.w / 2 - 2, wl.y)
                    table.insert(wallCtrls, dark)
                end
            else
                -- 横墙：上下两侧做明暗
                local lit = createControl(PREFAB.SQUARE, host, LAYER.WALL)
                if lit ~= nil then
                    pcall(function()
                        lit:SetSizeDelta(wl.w - 4, 2)
                        lit.imageColor = COLOR.WALL_TOP
                        lit.imageType = Enum.ImageType.Stretch
                    end)
                    lit:SetAnchoredPosition(wl.x, wl.y - wl.h / 2 + 2)
                    table.insert(wallCtrls, lit)
                end
                local dark = createControl(PREFAB.SQUARE, host, LAYER.WALL)
                if dark ~= nil then
                    pcall(function()
                        dark:SetSizeDelta(wl.w - 4, 2)
                        dark.imageColor = COLOR.WALL_SIDE
                        dark.imageType = Enum.ImageType.Stretch
                    end)
                    dark:SetAnchoredPosition(wl.x, wl.y + wl.h / 2 - 2)
                    table.insert(wallCtrls, dark)
                end
            end
        end
    end
    print("[坦克动荡] 立体墙壁已生成，碰撞墙段=" .. #walls .. "，控件数=" .. #wallCtrls)
end

--==================== ⑩ 坦克（15 部件拼接）====================
local function buildTankVisual(base)
    local parts = {}
    -- 车头 / 炮口朝局部 +x（与 theta 前进方向一致；w/h 保持原值，用 lrot=90 转正）
    -- 履带（深色）×2：沿 x 方向铺开
    addPart(parts, "sq", 12, 40, shade(base, 0.42), 0, -13, 90, LAYER.TANK)
    addPart(parts, "sq", 12, 40, shade(base, 0.42), 0,  13, 90, LAYER.TANK)
    -- 履带节纹 ×每侧3条
    for _, xx in ipairs({ -12, 0, 12 }) do
        addPart(parts, "sq", 12, 3, shade(base, 0.62), xx, -13, 90, LAYER.TANK)
        addPart(parts, "sq", 12, 3, shade(base, 0.62), xx,  13, 90, LAYER.TANK)
    end
    -- 主车体 + 前装甲斜面（装甲在 +x 一侧）
    addPart(parts, "sq", 24, 30, base, -3, 0, 90, LAYER.TANK)
    addPart(parts, "sq", 17, 7, shade(base, 0.85), 13, 0, 90, LAYER.TANK)
    -- 车身高光
    addPart(parts, "sq", 17, 3, shade(base, 1.28), 5, 0, 90, LAYER.TANK)
    -- 圆形炮塔 + 炮塔心
    addPart(parts, "circle", 19, 19, shade(base, 1.10), 0, 0, 0, LAYER.TANK)
    addPart(parts, "circle", 9, 9, shade(base, 0.70), 0, 0, 0, LAYER.TANK)
    -- 炮管 + 炮口（指向局部 +x）
    addPart(parts, "sq", 7, 24, shade(base, 0.55), 20, 0, 90, LAYER.TANK)
    addPart(parts, "sq", 9, 4, shade(base, 0.35), 31, 0, 90, LAYER.TANK)
    return parts
end

local function createTank(tankColor)
    return {
        x = 0, y = 0, theta = -math.pi / 2,
        fireCd = 0, alive = true,
        weapon = "normal", ammo = 0, fireHeld = false, lockT = 0,
        visual = buildTankVisual(tankColor),
        charging = nil,
        rcProj = nil,
        fragProj = nil,
        -- AI 导航
        thinkT = 0, nextCell = nil, evadeT = 0,
    }
end

local function muzzlePos(t, extra)
    local d = CFG.TANK_R + (extra or 4)
    return t.x + math.cos(t.theta) * d, t.y + math.sin(t.theta) * d
end

local function moveTank(t, dx, dy)
    if dx == 0 and dy == 0 then return end
    t.x = t.x + dx
    t.y = t.y + dy
    for _, wl in ipairs(walls) do resolveCircleRect(t, CFG.TANK_R, wl) end
end

local function resolveTanks(a, b)
    if not a.alive or not b.alive then return end
    local dx, dy = a.x - b.x, a.y - b.y
    local minDist = CFG.TANK_R * 2
    local d2 = dx * dx + dy * dy
    if d2 < minDist * minDist and d2 > 1e-8 then
        local d = math.sqrt(d2)
        local push = (minDist - d) / 2
        a.x = a.x + dx / d * push
        a.y = a.y + dy / d * push
        b.x = b.x - dx / d * push
        b.y = b.y - dy / d * push
    end
end

--==================== ⑪ 弹射物视觉（多层拼接）====================
-- 普通炮弹：深色底圆 + 主圆 + 高光点
local function visualShell(shellColor)
    local parts = {}
    addPart(parts, "circle", 9, 9, shade(shellColor, 0.45), 0, 0, 0, LAYER.PROJ)
    addPart(parts, "circle", 6.5, 6.5, shellColor, 0, 0, 0, LAYER.PROJ)
    addPart(parts, "circle", 2, 2, C(255, 255, 255, 200), -1.5, -1.5, 0, LAYER.PROJ)
    return parts
end

-- 机枪弹：单圆
local function visualMG(shellColor)
    local parts = {}
    addPart(parts, "circle", 5, 5, shellColor, 0, 0, 0, LAYER.PROJ)
    return parts
end

-- 导弹（追踪/遥控）：弹体 + 头圆 + 双尾翼 + 尾焰
local function visualMissile(missileColor)
    local parts = {}
    -- 弹头朝局部 +x（与飞行方向 theta 一致）
    addPart(parts, "sq", 7, 13, missileColor, -3, 0, 90, LAYER.PROJ)
    addPart(parts, "circle", 8, 8, shade(missileColor, 1.15), 6, 0, 0, LAYER.PROJ)
    addPart(parts, "sq", 3, 6, shade(missileColor, 0.5), -10, -4.5, 89.4, LAYER.PROJ)
    addPart(parts, "sq", 3, 6, shade(missileColor, 0.5), -10,  4.5, 90.6, LAYER.PROJ)
    addPart(parts, "circle", 3.5, 3.5, COLOR.FLAME, -11, 0, 0, LAYER.PROJ)
    return parts
end

-- 破片弹：底圆 + 主圆 + 3凸点 + 高光（凸点朝局部 +x）
local function visualFragBomb(fragColor)
    local parts = {}
    addPart(parts, "circle", 15, 15, shade(fragColor, 0.45), 0, 0, 0, LAYER.PROJ)
    addPart(parts, "circle", 11.5, 11.5, fragColor, 0, 0, 0, LAYER.PROJ)
    addPart(parts, "circle", 2.5, 2.5, shade(fragColor, 0.6), 7, 0, 0, LAYER.PROJ)
    addPart(parts, "circle", 2.5, 2.5, shade(fragColor, 0.6), 3, -6, 0, LAYER.PROJ)
    addPart(parts, "circle", 2.5, 2.5, shade(fragColor, 0.6), 3, 6, 0, LAYER.PROJ)
    addPart(parts, "circle", 2.5, 2.5, C(255, 255, 255, 190), -3, -3, 0, LAYER.PROJ)
    return parts
end

-- 弹片：单圆
local function visualShrapnel(shellColor)
    local parts = {}
    addPart(parts, "circle", 5, 5, shellColor, 0, 0, 0, LAYER.PROJ)
    return parts
end

--==================== ⑫ 弹射物逻辑 ====================
local function removeProj(index)
    local p = projs[index]
    if p ~= nil then
        onSpecialEnd(p)
        disposeParts(p.visual)
    end
    table.remove(projs, index)
end

local function countProj(ownerTank, ptype)
    local n = 0
    for _, p in ipairs(projs) do
        if p.ownerTank == ownerTank and p.ptype == ptype then n = n + 1 end
    end
    return n
end

-- 发射弹射物
local function spawnProjectile(ownerTank, ptype, x, y, dx, dy, spreadRad, controlled)
    local def = PTYPE[ptype]
    -- 注意：不能写 x = x or muzzlePos(...)，or 表达式会把 muzzlePos 的
    -- 第二个返回值 y 截断，导致 y 为 nil（曾引发发射后每帧报错、画面冻结）
    if x == nil then x, y = muzzlePos(ownerTank, 5) end
    if dx == nil then
        dx, dy = math.cos(ownerTank.theta), math.sin(ownerTank.theta)
    end
    if spreadRad and spreadRad ~= 0 then
        local baseA = math.atan(dy, dx) + (math.random() * 2 - 1) * spreadRad
        dx, dy = math.cos(baseA), math.sin(baseA)
    end

    local baseColor = (ownerTank == player) and COLOR.SHELL_P or COLOR.SHELL_E
    local visual
    if ptype == "normal" then
        visual = visualShell(baseColor)
    elseif ptype == "mg" then
        visual = visualMG(baseColor)
    elseif ptype == "homing" or ptype == "rc" then
        visual = visualMissile(WEAPONS[ptype].color)
    elseif ptype == "frag" then
        visual = visualFragBomb(WEAPONS.frag.color)
    else
        visual = visualShrapnel(baseColor)
    end

    local p = {
        x = x, y = y,
        vx = dx * def.speed, vy = dy * def.speed,
        life = def.life, age = 0, r = def.r,
        ptype = ptype, kind = def.kind, ownerTank = ownerTank,
        controlled = controlled or false, visual = visual,
    }
    table.insert(projs, p)
    syncParts(visual, x, y, math.atan(dy, dx))
    return p
end

-- 爆炸闪光动画
local function spawnFlash(x, y, bigR, color)
    for _, rr in ipairs({ bigR, bigR * 0.66, bigR * 0.4 }) do
        local ctl = createControl(PREFAB.CIRCLE, host, LAYER.EFFECT)
        if ctl ~= nil then
            pcall(function()
                ctl:SetSizeDelta(rr, rr)
                ctl.imageColor = withAlpha(color, 160)
                ctl.imageType = Enum.ImageType.Stretch
            end)
            ctl:SetAnchoredPosition(x, y)
            table.insert(effects, {
                ctl = ctl, t = CFG.FLASH_LIFE, life = CFG.FLASH_LIFE,
                r0 = rr * 0.4, r1 = rr * 1.25, color = color,
            })
        end
    end
end

local function updateEffects(dt)
    for i = #effects, 1, -1 do
        local e = effects[i]
        e.t = e.t - dt
        if e.t <= 0 then
            destroyControl(e.ctl)
            table.remove(effects, i)
        else
            local k = 1 - e.t / e.life
            local rr = e.r0 + (e.r1 - e.r0) * k
            local a = math.floor(160 * (1 - k))
            pcall(function()
                e.ctl:SetSizeDelta(rr, rr)
                e.ctl.imageColor = withAlpha(e.color, a)
            end)
        end
    end
end

-- 爆炸：范围直接杀伤 + 30片破片 + 闪光
function explodeAt(x, y, sourceTank)
    print(string.format("[坦克动荡] 爆炸 @ (%.0f, %.0f)", x, y))
    for _, t in ipairs(allTanks()) do
        if t.alive then
            local dx, dy = t.x - x, t.y - y
            if dx * dx + dy * dy < CFG.BLAST_R * CFG.BLAST_R then
                killTank(t, sourceTank, "blast")
            end
        end
    end
    for i = 1, CFG.SHRAPNEL_COUNT do
        local a = (i - 1) / CFG.SHRAPNEL_COUNT * 2 * math.pi + math.random() * 0.1
        local dx, dy = math.cos(a), math.sin(a)
        spawnProjectile(sourceTank or player, "shrapnel",
                        x + dx * 6, y + dy * 6, dx, dy)
    end
    spawnFlash(x, y, CFG.BLAST_R * 1.35, C(255, 190, 90))
end

function detonateBomb(index)
    local p = projs[index]
    if p == nil then return end
    local x, y, owner = p.x, p.y, p.ownerTank
    removeProj(index)
    explodeAt(x, y, owner)
end

function onSpecialEnd(p)
    local tank = p.ownerTank
    if p.ptype == "rc" then
        if tank.rcProj == p then tank.rcProj = nil; revertWeapon(tank) end
    elseif p.ptype == "frag" then
        if tank.fragProj == p then tank.fragProj = nil; revertWeapon(tank) end
    end
end

-- 追踪导弹：激活后朝最近敌方转向
local function updateHoming(p, dt)
    if p.age < CFG.HOMING_ACTIVATE then return end
    local target, bestD2
    for _, t in ipairs(allTanks()) do
        if t.alive and t ~= p.ownerTank then
            local d2 = (t.x - p.x) ^ 2 + (t.y - p.y) ^ 2
            if bestD2 == nil or d2 < bestD2 then bestD2 = d2; target = t end
        end
    end
    if target == nil then return end
    local curA = math.atan(p.vy, p.vx)
    local wantA = math.atan(target.y - p.y, target.x - p.x)
    local d = angleDiff(wantA, curA)
    d = clamp(d, -CFG.HOMING_TURN * dt, CFG.HOMING_TURN * dt)
    local newA = curA + d
    p.vx = math.cos(newA) * CFG.HOMING_SPEED
    p.vy = math.sin(newA) * CFG.HOMING_SPEED
end

-- 遥控导弹：玩家移动键控转向
local function updateRCControl(p, dt)
    if not p.controlled or p.ownerTank ~= player then return end
    local turn = (input.left and 1 or 0) - (input.right and 1 or 0)
    if turn ~= 0 then
        local a = math.atan(p.vy, p.vx) + turn * CFG.RC_TURN * dt
        p.vx = math.cos(a) * CFG.RC_SPEED
        p.vy = math.sin(a) * CFG.RC_SPEED
    end
end

local function updateProjectiles(dt)
    for i = #projs, 1, -1 do
        local p = projs[i]
        p.life = p.life - dt
        p.age = p.age + dt
        if p.life <= 0 then
            if p.kind == "bomb" or p.kind == "frag" then
                detonateBomb(i)
            else
                removeProj(i)
            end
        else
            if p.ptype == "homing" then updateHoming(p, dt) end
            if p.ptype == "rc" then updateRCControl(p, dt) end

            local nx = p.x + p.vx * dt
            local ny = p.y + p.vy * dt
            for _, wl in ipairs(walls) do
                if sweptCircleRect(p.x, p.y, nx, ny, p.r, wl) then
                    if p.kind == "bomb" then
                        detonateBomb(i)
                        nx = nil
                        break
                    elseif p.kind == "shard" then
                        removeProj(i)
                        nx = nil
                        break
                    else
                        local prevOutsideX = p.x < wl.x - wl.w / 2 - p.r
                            or p.x > wl.x + wl.w / 2 + p.r
                        if prevOutsideX then
                            p.vx = -p.vx
                            nx = (p.x < wl.x - wl.w / 2)
                                and (wl.x - wl.w / 2 - p.r - 0.5)
                                or  (wl.x + wl.w / 2 + p.r + 0.5)
                        else
                            p.vy = -p.vy
                            ny = (p.y < wl.y - wl.h / 2)
                                and (wl.y - wl.h / 2 - p.r - 0.5)
                                or  (wl.y + wl.h / 2 + p.r + 0.5)
                        end
                        break
                    end
                end
            end
            if nx ~= nil and projs[i] == p then
                p.x, p.y = nx, ny
                syncParts(p.visual, p.x, p.y, math.atan(p.vy, p.vx))
            end
        end
    end
end

local function checkProjHits()
    for i = #projs, 1, -1 do
        local p = projs[i]
        for _, t in ipairs(allTanks()) do
            if t.alive and not (p.ownerTank == t and p.age < 0.12) then
                local dx, dy = p.x - t.x, p.y - t.y
                local rr = CFG.TANK_R + p.r
                if dx * dx + dy * dy < rr * rr then
                    if p.kind == "bomb" or p.kind == "frag" then
                        detonateBomb(i)
                    else
                        killTank(t, p.ownerTank, p.ptype)
                        removeProj(i)
                    end
                    break
                end
            end
        end
    end
end

--==================== ⑬ 光束画面 / 激光 / 死亡射线 ====================
local function addBeamSegment(beam, x1, y1, x2, y2, color, width)
    local len = math.sqrt((x2 - x1) ^ 2 + (y2 - y1) ^ 2)
    if len < 1 then return end
    local ctl = createControl(PREFAB.SQUARE, host, LAYER.BEAM)
    if ctl == nil then return end
    pcall(function()
        ctl:SetSizeDelta(len, width)
        ctl.imageColor = color
        ctl.imageType = Enum.ImageType.Stretch
    end)
    ctl:SetAnchoredPosition((x1 + x2) / 2, (y1 + y2) / 2)
    ctl:SetLocalRotation(0, 0, math.deg(math.atan(y2 - y1, x2 - x1)))
    table.insert(beam.ctrls, ctl)
end

local function updateBeams(dt)
    for i = #beams, 1, -1 do
        local b = beams[i]
        b.life = b.life - dt
        if b.life <= 0 then
            for _, ctl in ipairs(b.ctrls) do destroyControl(ctl) end
            table.remove(beams, i)
        end
    end
end

local function beamHitTanks(points, ownerTank, cause)
    for seg = 1, #points - 1 do
        local a, b = points[seg], points[seg + 1]
        for _, t in ipairs(allTanks()) do
            if t.alive and not (t == ownerTank and seg == 1) then
                if distPointSeg(t.x, t.y, a.x, a.y, b.x, b.y) < CFG.TANK_R then
                    killTank(t, ownerTank, cause)
                end
            end
        end
    end
end

local function fireLaserBeam(tank)
    local x, y = muzzlePos(tank, 6)
    local dx, dy = math.cos(tank.theta), math.sin(tank.theta)
    local points = { { x = x, y = y } }
    local remaining, bounces = CFG.LASER_MAXLEN, 0
    while remaining > 0 and bounces <= CFG.LASER_BOUNCES do
        local d, hx, hy = rayWalls(x, y, dx, dy, remaining, walls)
        if d == nil then
            table.insert(points, { x = x + dx * remaining, y = y + dy * remaining })
            break
        end
        table.insert(points, { x = hx, y = hy })
        remaining = remaining - d
        local _, _, _, face = rayWalls(hx - dx * 0.01, hy - dy * 0.01, dx, dy, 1, walls)
        if face == "x" then dx = -dx else dy = -dy end
        x = hx + dx * 0.6; y = hy + dy * 0.6
        bounces = bounces + 1
    end
    local beam = { life = CFG.BEAM_LIFE, ctrls = {} }
    for seg = 1, #points - 1 do
        addBeamSegment(beam, points[seg].x, points[seg].y,
                       points[seg + 1].x, points[seg + 1].y,
                       WEAPONS.laser.color, CFG.BEAM_WIDTH)
    end
    table.insert(beams, beam)
    beamHitTanks(points, tank, "laser")
    print("[坦克动荡] 激光发射，折线段数=" .. (#points - 1))
end

local function fireDeathRay(tank)
    local x, y = muzzlePos(tank, 6)
    local dx, dy = math.cos(tank.theta), math.sin(tank.theta)
    local borderWalls = {}
    for _, wl in ipairs(walls) do
        if wl.border then table.insert(borderWalls, wl) end
    end
    local d, hx, hy = rayWalls(x, y, dx, dy, CFG.DEATH_MAXLEN, borderWalls)
    local ex = hx or (x + dx * CFG.DEATH_MAXLEN)
    local ey = hy or (y + dy * CFG.DEATH_MAXLEN)
    local beam = { life = CFG.BEAM_LIFE, ctrls = {} }
    addBeamSegment(beam, x, y, ex, ey, WEAPONS.deathray.color, CFG.BEAM_WIDTH + 1)
    table.insert(beams, beam)
    for _, t in ipairs(allTanks()) do
        if t.alive and t ~= tank then
            if distPointSeg(t.x, t.y, x, y, ex, ey) < CFG.TANK_R then
                killTank(t, tank, "deathray")
            end
        end
    end
    print("[坦克动荡] 死亡射线发射")
end

--==================== ⑭ 地雷（雷刺+三层圆拼接）====================
local function visualMine(mineColor)
    local parts = {}
    -- 6 根雷刺
    for i = 0, 5 do
        local a = i / 6 * 2 * math.pi
        addPart(parts, "sq", 3, 5, shade(mineColor, 0.5),
                math.cos(a) * 9, math.sin(a) * 9, a + math.pi / 2, LAYER.MINE)
    end
    addPart(parts, "circle", 16, 16, shade(mineColor, 0.45), 0, 0, 0, LAYER.MINE)
    addPart(parts, "circle", 12.5, 12.5, mineColor, 0, 0, 0, LAYER.MINE)
    addPart(parts, "circle", 5.5, 5.5, C(255, 90, 90), 0, 0, 0, LAYER.MINE)
    addPart(parts, "circle", 2.5, 2.5, C(255, 255, 255, 190), -2, -2, 0, LAYER.MINE)
    return parts
end

local function placeMine(tank)
    local bx = tank.x - math.cos(tank.theta) * (CFG.TANK_R + 4)
    local by = tank.y - math.sin(tank.theta) * (CFG.TANK_R + 4)
    local visual = visualMine(WEAPONS.mine.color)
    table.insert(mines, {
        x = bx, y = by, age = 0, armed = false,
        placer = tank, visual = visual, placerLeft = false, detonating = nil,
    })
    syncParts(visual, bx, by, 0)
    print("[坦克动荡] 地雷已放置")
end

local function triggerMine(mine)
    mine.detonating = CFG.MINE_DETONATE
    print("[坦克动荡] 地雷被触发，0.4 秒后引爆")
end

local function updateMines(dt)
    for i = #mines, 1, -1 do
        local m = mines[i]
        m.age = m.age + dt
        if m.detonating ~= nil then
            m.detonating = m.detonating - dt
            partsVisible(m.visual, math.floor(m.detonating * 12) % 2 == 0)
            if m.detonating <= 0 then
                local x, y, owner = m.x, m.y, m.placer
                disposeParts(m.visual)
                table.remove(mines, i)
                explodeAt(x, y, owner)
            end
        else
            if not m.armed and m.age >= CFG.MINE_ARM then
                m.armed = true
                partsVisible(m.visual, false)
            end
            if m.armed then
                for _, t in ipairs(allTanks()) do
                    if t.alive then
                        local d = math.sqrt((t.x - m.x) ^ 2 + (t.y - m.y) ^ 2)
                        if t == m.placer then
                            if d > 32 then m.placerLeft = true end
                            if m.placerLeft and d < CFG.MINE_TRIGGER then
                                triggerMine(m); break
                            end
                        elseif d < CFG.MINE_TRIGGER then
                            triggerMine(m); break
                        end
                    end
                end
            end
        end
    end
end

--==================== ⑮ 补给箱（拼接，不再需要箱子专属模板）====================
local function visualCrate(crateColor)
    local parts = {}
    addPart(parts, "sq", 32, 32, crateColor, 0, 0, 0, LAYER.CRATE)
    addPart(parts, "sq", 26, 26, shade(crateColor, 0.5), 0, 0, 0, LAYER.CRATE)
    addPart(parts, "sq", 6, 28, crateColor, 0, 0, 0, LAYER.CRATE)
    addPart(parts, "sq", 28, 6, shade(crateColor, 1.25), 0, 0, 0, LAYER.CRATE)
    addPart(parts, "circle", 8, 8, shade(crateColor, 1.1), 0, 0, 0, LAYER.CRATE)
    return parts
end

local function spawnCrate()
    local w = CRATE_ORDER[math.random(1, #CRATE_ORDER)]
    local def = WEAPONS[w]
    local x, y
    for _ = 1, 30 do
        local gx = math.random(0, N - 1)
        local gy = math.random(0, N - 1)
        local cx, cy = cellCenter(gx, gy)
        local okPos = true
        for _, t in ipairs(allTanks()) do
            local dd = math.sqrt((t.x - cx) ^ 2 + (t.y - cy) ^ 2)
            if dd < CFG.CRATE_SAFE then okPos = false break end
        end
        if okPos then
            for _, c in ipairs(crates) do
                if (c.x - cx) ^ 2 + (c.y - cy) ^ 2 < 70 * 70 then okPos = false break end
            end
        end
        if okPos then x, y = cx, cy break end
    end
    if x == nil then
        print("[坦克动荡] 本轮未找到合适的补给箱位置")
        return
    end

    local visual = visualCrate(def.color)
    syncParts(visual, x, y, 0)

    local txtCtl = createControl(PREFAB.TEXT, host, LAYER.CRATE)
    if txtCtl ~= nil then
        pcall(function()
            txtCtl:SetSizeDelta(32, 32)
            txtCtl.fontSize = 20
            txtCtl.fontColor = COLOR.LABEL
            txtCtl.bgColor = C(0, 0, 0, 0)
            txtCtl.horizontalAlignment = Enum.TextHorizontalAlignment.Middle
            txtCtl.verticalAlignment = Enum.TextVerticalAlignment.Middle
            txtCtl.text = def.label
        end)
        txtCtl:SetAnchoredPosition(x, y)
    end

    table.insert(crates, { x = x, y = y, weapon = w, visual = visual, txtCtl = txtCtl })
    print("[坦克动荡] 补给箱出现：" .. def.name)
end

local function pickupCrate(index, tank)
    local c = crates[index]
    local def = WEAPONS[c.weapon]
    disposeParts(c.visual)
    destroyControl(c.txtCtl)
    table.remove(crates, index)
    tank.weapon = c.weapon
    tank.ammo = def.ammo
    print("[坦克动荡] " .. (tank == player and "玩家" or "电脑") .. " 拾取了 " .. def.name)
    updateHUDAll()
end

local function updateCratePickups()
    for i = #crates, 1, -1 do
        local c = crates[i]
        for _, t in ipairs(allTanks()) do
            if t.alive then
                local d2 = (t.x - c.x) ^ 2 + (t.y - c.y) ^ 2
                if d2 < (CFG.TANK_R + 12) ^ 2 then
                    pickupCrate(i, t)
                    break
                end
            end
        end
    end
end

--==================== ⑯ 开火总入口 / 武器切换 ====================
function revertWeapon(tank)
    if tank.weapon == "normal" then return end
    print("[坦克动荡] " .. (tank == player and "玩家" or "电脑") .. " 的 "
        .. WEAPONS[tank.weapon].name .. " 已用完，恢复普通炮")
    tank.weapon = "normal"
    tank.ammo = 0
    tank.charging = nil
    updateHUDAll()
end

local function consumeAmmo(tank)
    tank.ammo = tank.ammo - 1
    if tank.ammo <= 0 then revertWeapon(tank) end
end

local function tryFire(tank)
    if not tank.alive or tank.fireCd > 0 then return end
    local w = tank.weapon
    if w == "normal" then
        if countProj(tank, "normal") >= CFG.MAX_SHELLS then return end
        tank.fireCd = CFG.FIRE_CD
        spawnProjectile(tank, "normal")
    elseif w == "gatling" then
        if countProj(tank, "mg") >= CFG.MAX_MG then tank.fireCd = 0.1 return end
        tank.fireCd = CFG.MG_CD
        spawnProjectile(tank, "mg", nil, nil, nil, nil, CFG.MG_SPREAD)
        consumeAmmo(tank)
    elseif w == "laser" then
        tank.fireCd = CFG.LASER_CD
        tank.lockT = CFG.LASER_LOCK
        fireLaserBeam(tank)
        consumeAmmo(tank)
    elseif w == "homing" then
        tank.fireCd = CFG.HOMING_CD
        spawnProjectile(tank, "homing")
        consumeAmmo(tank)
    elseif w == "mine" then
        tank.fireCd = CFG.MINE_CD
        placeMine(tank)
        consumeAmmo(tank)
    elseif w == "rc" then
        if tank.rcProj ~= nil then return end
        tank.fireCd = CFG.RC_CD
        local p = spawnProjectile(tank, "rc", nil, nil, nil, nil, nil, tank == player)
        if p ~= nil then tank.rcProj = p end
    elseif w == "frag" then
        if tank.fragProj ~= nil then return end
        tank.fireCd = CFG.FRAG_CD
        local p = spawnProjectile(tank, "frag")
        if p ~= nil then tank.fragProj = p end
    elseif w == "deathray" then
        tank.charging = { t = CFG.DEATH_CHARGE }
        tank.lockT = CFG.DEATH_CHARGE
        tank.fireCd = CFG.DEATH_CD + CFG.DEATH_CHARGE
    end
end

local function updateCharging(tank, dt)
    if tank.charging == nil then return end
    tank.charging.t = tank.charging.t - dt
    if tank.charging.t <= 0 and tank.weapon == "deathray" then
        fireDeathRay(tank)
        tank.charging = nil
        consumeAmmo(tank)
    end
end

local function handleFirePress(tank)
    if not tank.alive or roundState ~= "playing" then return end
    if tank.rcProj ~= nil then
        for i, p in ipairs(projs) do
            if p == tank.rcProj then detonateBomb(i); break end
        end
    elseif tank.fragProj ~= nil then
        for i, p in ipairs(projs) do
            if p == tank.fragProj then detonateBomb(i); break end
        end
    elseif tank.charging ~= nil then
        -- 蓄力中忽略
    else
        tryFire(tank)
        updateHUDAll()
    end
end

--==================== ⑰ 电脑 AI（BFS 寻路 + 安全开火 + 躲弹）====================

-- BFS：以 (sc,sr) 为起点，返回 dist 与 parent（格子索引）
local function bfs(sc, sr)
    local nn = N * N
    local dist, parent = {}, {}
    for i = 1, nn do dist[i] = -1; parent[i] = -1 end
    local queue = { sr * N + sc + 1 }
    dist[sr * N + sc + 1] = 0
    local head = 1
    while head <= #queue do
        local idx = queue[head]; head = head + 1
        local c = (idx - 1) % N
        local r = math.floor((idx - 1) / N)
        local d = dist[idx]
        -- 四向（检查之间墙段）
        if c < N - 1 and not V[c + 1][r] then
            local ni = r * N + c + 2
            if dist[ni] < 0 then dist[ni] = d + 1; parent[ni] = idx; table.insert(queue, ni) end
        end
        if c > 0 and not V[c][r] then
            local ni = r * N + c
            if dist[ni] < 0 then dist[ni] = d + 1; parent[ni] = idx; table.insert(queue, ni) end
        end
        if r < N - 1 and not H[r + 1][c] then
            local ni = (r + 1) * N + c + 1
            if dist[ni] < 0 then dist[ni] = d + 1; parent[ni] = idx; table.insert(queue, ni) end
        end
        if r > 0 and not H[r][c] then
            local ni = (r - 1) * N + c + 1
            if dist[ni] < 0 then dist[ni] = d + 1; parent[ni] = idx; table.insert(queue, ni) end
        end
    end
    return dist, parent
end

-- 由 parent 链回溯，返回紧邻的下一格 {c,r}
local function nextCellFromParent(parent, startIdx, targetIdx)
    local idx = targetIdx
    while parent[idx] ~= startIdx do
        idx = parent[idx]
        if idx < 0 then return nil end
    end
    return { c = (idx - 1) % N, r = math.floor((idx - 1) / N) }
end

-- 开火安全检查：模拟炮弹反弹 1.3 秒，若轨迹很快回到自己身边则不开火
local function isSafeShot(tank)
    local x, y = muzzlePos(tank, 6)
    local dx, dy = math.cos(tank.theta), math.sin(tank.theta)
    local limit = CFG.SHELL_SPEED * 1.3
    local traveled = 0
    for step = 1, 6 do
        local remain = limit - traveled
        local d, hx, hy, face = rayWalls(x, y, dx, dy, remain, walls)
        local ex, ey = x + dx * (d or remain), y + dy * (d or remain)
        -- 遥控导弹撞第一面墙即爆：爆点距自己过近会被自己的爆炸带走
        if step == 1 and tank.weapon == "rc" and d ~= nil then
            local blastD = math.sqrt((tank.x - ex) ^ 2 + (tank.y - ey) ^ 2)
            if blastD < CFG.BLAST_R * 1.05 then return false end
        end
        if traveled > CFG.SHELL_SPEED * 0.2 then
            if distPointSeg(tank.x, tank.y, x, y, ex, ey) < CFG.TANK_R + 6 then
                return false
            end
        end
        if d == nil then break end
        traveled = traveled + d
        if face == "x" then dx = -dx else dy = -dy end
        x = hx + dx * 0.6; y = hy + dy * 0.6
    end
    return true
end

-- 危险评估：所有子弹未来 0.3 秒直线轨迹距自己过近 → 返回最危险的弹
local function detectThreat(e)
    local threat, bestD
    for _, p in ipairs(projs) do
        if not (p.ownerTank == e and p.age < 0.15) then
            local fx = p.x + p.vx * 0.3
            local fy = p.y + p.vy * 0.3
            local d = distPointSeg(e.x, e.y, p.x, p.y, fx, fy)
            if d < CFG.TANK_R + 9 and (bestD == nil or d < bestD) then
                bestD = d; threat = p
            end
        end
    end
    return threat
end

local function updateEnemyAI(dt)
    local e = enemy
    e.fireCd = math.max(0, e.fireCd - dt)
    e.thinkT = e.thinkT - dt
    e.evadeT = math.max(0, e.evadeT - dt)

    -- ① 危险规避（最高优先级）：沿走廊前/后选择远离子弹的方向
    local threat = detectThreat(e)
    if threat ~= nil then
        local awayA = math.atan(e.y - threat.y, e.x - threat.x)
        local options = {
            { a = e.theta,           rev = false },
            { a = e.theta + math.pi, rev = true  },
        }
        local best, bestScore
        for _, o in ipairs(options) do
            local dx, dy = math.cos(o.a), math.sin(o.a)
            local blocked = raycastBlocked(e.x, e.y, dx, dy, cell * 0.4)
            local score = math.cos(angleDiff(o.a, awayA)) - (blocked and 10 or 0)
            if best == nil or score > bestScore then best = o; bestScore = score end
        end
        if bestScore < -0.4 then
            -- 前后都不安全：原地不动等待
        else
            local diff = angleDiff(best.a, e.theta)
            if math.abs(diff) > 0.12 then
                e.theta = e.theta + clamp(diff, -CFG.TURN_SPEED * 1.2 * dt, CFG.TURN_SPEED * 1.2 * dt)
            else
                local sp = best.rev and CFG.BACK_SPEED or CFG.MOVE_SPEED
                moveTank(e, math.cos(e.theta) * sp * dt, math.sin(e.theta) * sp * dt)
            end
        end
        return
    end

    -- ①.5 破片弹智能引爆：能炸死玩家且炸不到自己时立即引爆
    if e.fragProj ~= nil then
        local f = e.fragProj
        local dP2 = (f.x - player.x) ^ 2 + (f.y - player.y) ^ 2
        local dS2 = (f.x - e.x) ^ 2 + (f.y - e.y) ^ 2
        if player.alive and dP2 < (CFG.BLAST_R * 0.85) ^ 2
           and dS2 > (CFG.BLAST_R * 1.05) ^ 2 then
            for i, p in ipairs(projs) do
                if p == f then detonateBomb(i) break end
            end
            return
        end
    end

    -- ② 视线检测：从自己射向玩家的射线是否被墙挡住
    local toPX, toPY = player.x - e.x, player.y - e.y
    local distP = math.sqrt(toPX * toPX + toPY * toPY)
    local aimA = math.atan(toPY, toPX)
    local wallD = rayWalls(e.x, e.y, math.cos(aimA), math.sin(aimA), distP + 1, walls)
    local canSee = (wallD == nil) or (wallD > distP)

    if canSee then
        -- 瞄准玩家（不前进），对齐且安全时开火
        local diff = angleDiff(aimA, e.theta)
        if math.abs(diff) > 0.05 then
            local step = CFG.TURN_SPEED * 1.15 * dt
            e.theta = e.theta + clamp(diff, -step, step)
        else
            -- 爆炸类武器贴脸发射会被自己的爆炸波及，拉开距离前不发射
            local explosive = (e.weapon == "rc" or e.weapon == "frag")
            local tooClose = explosive and distP < CFG.BLAST_R * 1.05
            if e.fireCd <= 0 and e.charging == nil and not tooClose and isSafeShot(e) then
                tryFire(e)
                e.evadeT = 0.6     -- 开火后短暂规避自己的反弹弹
            end
        end
        e.fireHeld = math.abs(diff) < 0.2
        return
    end
    e.fireHeld = false

    -- ③ 网格导航：定期 BFS，目标在「最近补给箱」与「玩家」间选择
    if e.thinkT <= 0 or e.nextCell == nil then
        local ec, er = cellOf(e.x, e.y)
        local dist, parent = bfs(ec, er)
        local pc, pr = cellOf(player.x, player.y)
        local targetIdx = pr * N + pc + 1
        local playerD = dist[targetIdx]
        for _, c in ipairs(crates) do
            local cc, cr = cellOf(c.x, c.y)
            local ci = cr * N + cc + 1
            if dist[ci] >= 0 and (playerD < 0 or dist[ci] < playerD) then
                targetIdx = ci
            end
        end
        local startIdx = er * N + ec + 1
        if dist[targetIdx] >= 0 and targetIdx ~= startIdx then
            e.nextCell = nextCellFromParent(parent, startIdx, targetIdx)
        else
            e.nextCell = nil
        end
        e.thinkT = 0.4
    end

    -- ④ 沿下一格导航：先转向对齐，再前进，到达格中心吸附
    if e.nextCell ~= nil then
        local tx, ty = cellCenter(e.nextCell.c, e.nextCell.r)
        local wantA = math.atan(ty - e.y, tx - e.x)
        local diff = angleDiff(wantA, e.theta)
        if math.abs(diff) > 0.12 then
            local step = CFG.TURN_SPEED * 1.1 * dt
            e.theta = e.theta + clamp(diff, -step, step)
        else
            moveTank(e, math.cos(e.theta) * CFG.MOVE_SPEED * 0.92 * dt,
                           math.sin(e.theta) * CFG.MOVE_SPEED * 0.92 * dt)
            if (e.x - tx) ^ 2 + (e.y - ty) ^ 2 < 12 * 12 then
                -- 到达：吸附并在下次 BFS 前临时以同方向延伸一格
                e.x, e.y = tx, ty
                local ec, er = e.nextCell.c, e.nextCell.r
                local cont = nil
                local dx, dy = math.cos(e.theta), math.sin(e.theta)
                if math.abs(dx) > 0.9 then
                    local nc = ec + (dx > 0 and 1 or -1)
                    if nc >= 0 and nc < N and not ((dx > 0) and V[ec + 1][er] or V[ec][er]) then
                        cont = { c = nc, r = er }
                    end
                else
                    local nr = er + (dy > 0 and 1 or -1)
                    if nr >= 0 and nr < N and not ((dy > 0) and H[er + 1][ec] or H[er][ec]) then
                        cont = { c = ec, r = nr }
                    end
                end
                e.nextCell = cont
                if cont == nil then e.thinkT = 0 end
            end
        end
    end
end

--==================== ⑱ HUD ====================
local function makeText(width, yPos, size, text)
    local ctl = createControl(PREFAB.TEXT, host, LAYER.HUD)
    if ctl == nil then return nil end
    pcall(function()
        ctl:SetSizeDelta(width, 40)
        ctl.fontSize = size
        ctl.fontColor = COLOR.TEXT
        ctl.bgColor = C(0, 0, 0, 0)
        ctl.enableOutline = true
        ctl.outlineColor = COLOR.TEXT_OUT
        ctl.horizontalAlignment = Enum.TextHorizontalAlignment.Middle
        ctl.verticalAlignment = Enum.TextVerticalAlignment.Middle
        ctl.text = text
    end)
    ctl:SetAnchoredPosition(0, yPos)
    return ctl
end

local function updateScoreHUD()
    if scoreText ~= nil then
        scoreText.text = string.format("玩家（红） %d : %d 电脑（绿）", pScore, eScore)
    end
end

local function updateWeaponHUD()
    if weaponText == nil then return end
    if player.weapon == "normal" then
        weaponText.text = "当前武器：普通炮"
        return
    end
    local suffix = ""
    if player.rcProj ~= nil then
        suffix = "（遥控中，再按开火引爆）"
    elseif player.fragProj ~= nil then
        suffix = "（待引爆，再按开火引爆）"
    elseif player.charging ~= nil then
        suffix = "（蓄力中…）"
    end
    weaponText.text = string.format("当前武器：%s × %d%s",
        WEAPONS[player.weapon].name, player.ammo, suffix)
end

function updateHUDAll()
    updateScoreHUD()
    updateWeaponHUD()
end

local function setupHUD()
    scoreText  = makeText(CFG.ARENA_SIZE, -CFG.ARENA_SIZE / 2 - 44, 30, "")
    statusText = makeText(CFG.ARENA_SIZE, -CFG.ARENA_SIZE / 2 - 88, 24, "准备中……")
    weaponText = makeText(CFG.ARENA_SIZE, -CFG.ARENA_SIZE / 2 - 130, 22, "")
    hintText   = makeText(CFG.ARENA_SIZE, -CFG.ARENA_SIZE / 2 - 170, 20,
                          "WASD / 方向键：移动　　Q / 回车：开火　　碾过补给箱拾取武器")
    updateHUDAll()
end

--==================== ⑲ 击杀与回合流程 ====================
function killTank(victim, sourceTank, cause)
    if roundState ~= "playing" or not victim.alive then return end
    local causeText = CAUSE[cause] or "武器"
    victim.alive = false
    partsVisible(victim.visual, false)
    print("[坦克动荡] 坦克被击毁：死者=" .. (victim == player and "玩家" or "电脑")
        .. "，死因=" .. causeText)

    if victim == player then
        eScore = eScore + 1
        if sourceTank == player then
            statusText.text = string.format("你被自己反弹回来的%s击毁了！电脑 +1", causeText)
        else
            statusText.text = string.format("你被电脑的%s击毁了！电脑 +1", causeText)
        end
    else
        pScore = pScore + 1
        statusText.text = string.format("你的%s击毁了敌方坦克！玩家 +1", causeText)
    end
    updateHUDAll()
    roundState = "roundover"
    roundTimer = CFG.ROUND_GAP
end

--==================== ⑳ 场景搭建 / 回合重置 ====================
local function spawnTanks()
    local sp1X, sp1Y = cellCenter(1, 1)
    local sp2X, sp2Y = cellCenter(N - 2, N - 2)
    player.x, player.y, player.theta = sp1X, sp1Y, -math.pi / 2
    enemy.x, enemy.y, enemy.theta = sp2X, sp2Y, math.pi / 2
    for _, t in ipairs(allTanks()) do
        t.fireCd, t.lockT = 0, 0
        t.weapon, t.ammo = "normal", 0
        t.fireHeld = false
        t.charging = nil
        t.rcProj = nil
        t.fragProj = nil
        t.thinkT = 0; t.nextCell = nil; t.evadeT = 0
        partsVisible(t.visual, true)
    end
    for _ = 1, 4 do
        for _, wl in ipairs(walls) do
            resolveCircleRect(player, CFG.TANK_R, wl)
            resolveCircleRect(enemy, CFG.TANK_R, wl)
        end
    end
    player.alive, enemy.alive = true, true
    syncParts(player.visual, player.x, player.y, player.theta)
    syncParts(enemy.visual, enemy.x, enemy.y, enemy.theta)
end

local function clearProjectiles()
    for _, p in ipairs(projs) do disposeParts(p.visual) end
    projs = {}
end

local function clearMines()
    for _, m in ipairs(mines) do disposeParts(m.visual) end
    mines = {}
end

local function clearBeams()
    for _, b in ipairs(beams) do
        for _, ctl in ipairs(b.ctrls) do destroyControl(ctl) end
    end
    beams = {}
end

local function clearEffects()
    for _, e in ipairs(effects) do destroyControl(e.ctl) end
    effects = {}
end

local function clearCrates()
    for _, c in ipairs(crates) do
        disposeParts(c.visual)
        destroyControl(c.txtCtl)
    end
    crates = {}
end

-- 一次性棋盘地砖：N×N 极淡明暗交替方块，铺在地板之上、坦克/墙壁之下
-- （创建顺序即层级；墙壁每回合重建、晚于地砖，故墙线始终压在地砖上）
local floorTileCtrls = {}
local function buildFloorTiles()
    for _, ctl in ipairs(floorTileCtrls) do destroyControl(ctl) end
    floorTileCtrls = {}
    for r = 0, N - 1 do
        for c = 0, N - 1 do
            local cx, cy = cellCenter(c, r)
            local ctl = createControl(PREFAB.SQUARE, host, LAYER.BG)
            if ctl ~= nil then
                local tileColor = ((c + r) % 2 == 0)
                    and shade(COLOR.FLOOR, 1.05)
                    or  shade(COLOR.FLOOR, 0.96)
                pcall(function()
                    ctl:SetSizeDelta(cell - 2, cell - 2)
                    ctl.imageColor = tileColor
                    ctl.imageType = Enum.ImageType.Stretch
                end)
                ctl:SetAnchoredPosition(cx, cy)
                table.insert(floorTileCtrls, ctl)
            end
        end
    end
end

local function startNewRound()
    clearProjectiles()
    clearMines()
    clearBeams()
    clearEffects()
    clearCrates()
    crateTimer = CFG.CRATE_FIRST
    generateMaze()
    buildWallsFromTables()
    buildWallVisuals()
    spawnTanks()
    roundState = "playing"
    statusText.text = "战斗中！炮弹会反弹，小心误伤自己；留意补给箱"
    updateHUDAll()
    print("[坦克动荡] 新回合开始")
end

--==================== ㉑ 按键注册 ====================
local function getEventType(eventName)
    local ok, ev = pcall(function() return Enum.KeyEventType[eventName] end)
    if ok then return ev end
    return nil
end

local function registerKey(eventName, callback, tag)
    if host == nil then return false end
    local ev = getEventType(eventName)
    if ev == nil then
        print("[坦克动荡] 当前运行时不存在按键事件：" .. eventName .. "（" .. tag .. "）")
        return false
    end
    local ok, err = pcall(function() host:AddKeyEventListener(ev, callback) end)
    if ok then
        print("[坦克动荡] 已注册按键事件：" .. eventName .. "（" .. tag .. "）")
    else
        printerr("[坦克动荡] 注册按键失败：" .. eventName .. " - " .. tostring(err))
    end
    return ok
end

local function onMoveKeyDown(action)
    return function() input[action] = true; return true end
end
local function onMoveKeyUp(action)
    return function() input[action] = false; return true end
end

local function onFireDown()
    return function()
        player.fireHeld = true
        if roundState == "playing" then handleFirePress(player) end
        return true
    end
end
local function onFireUp()
    return function() player.fireHeld = false; return true end
end

local function setupInput()
    local binds = {
        { down = "KeyboardMoveForwardKeyDown",    up = "KeyboardMoveForwardKeyUp",    act = "fwd"  },
        { down = "KeyboardMoveBackwardKeyDown",   up = "KeyboardMoveBackwardKeyUp",   act = "back" },
        { down = "KeyboardMoveLeftKeyDown",       up = "KeyboardMoveLeftKeyUp",       act = "left" },
        { down = "KeyboardMoveRightKeyDown",      up = "KeyboardMoveRightKeyUp",      act = "right"},
        { down = "KeyboardCraftspersonKey36Down", up = "KeyboardCraftspersonKey36Up", act = "fwd"  },
        { down = "KeyboardCraftspersonKey37Down", up = "KeyboardCraftspersonKey37Up", act = "back" },
        { down = "KeyboardCraftspersonKey38Down", up = "KeyboardCraftspersonKey38Up", act = "left" },
        { down = "KeyboardCraftspersonKey39Down", up = "KeyboardCraftspersonKey39Up", act = "right"},
    }
    for _, b in ipairs(binds) do
        registerKey(b.down, onMoveKeyDown(b.act), b.act)
        registerKey(b.up,   onMoveKeyUp(b.act),   b.act)
    end
    registerKey("KeyboardCharacterSkill2KeyDown", onFireDown(), "攻击-Q")
    registerKey("KeyboardCharacterSkill2KeyUp",   onFireUp(),   "攻击-Q抬起")

    local enterDown = {
        "KeyboardEnterKeyDown", "KeyboardReturnKeyDown",
        "KeyboardKeypadEnterKeyDown", "KeyboardMenuConfirmKeyDown",
        "ControllerMenuConfirmKeyDown",
    }
    local enterUp = {
        "KeyboardEnterKeyUp", "KeyboardReturnKeyUp",
        "KeyboardKeypadEnterKeyUp", "KeyboardMenuConfirmKeyUp",
        "ControllerMenuConfirmKeyUp",
    }
    local enterOk = false
    for k, name in ipairs(enterDown) do
        if getEventType(name) ~= nil then
            enterOk = registerKey(name, onFireDown(), "攻击-回车")
            if enterOk and getEventType(enterUp[k]) ~= nil then
                registerKey(enterUp[k], onFireUp(), "攻击-回车抬起")
            end
            break
        end
    end
    if not enterOk then
        registerKey("KeyboardJumpKeyDown", onFireDown(), "攻击-空格(回车备选)")
        registerKey("KeyboardJumpKeyUp",   onFireUp(),   "攻击-空格抬起")
        print("[坦克动荡] 提示：当前 API 不支持回车键，已改用空格作为第二个开火键")
    end
end

--==================== ㉒ 生命周期 ====================
function OnInit()
    math.randomseed(os.time())
    host = script.object
    print("[坦克动荡] OnInit，宿主类型=" .. typeof(host))
    if host == nil then
        printerr("[坦克动荡] script.object 为空，请确认脚本挂载在容器控件上")
    end
end

function OnStart()
    print("[坦克动荡] OnStart")
    if host == nil then return end

    pcall(function() host.disableKeyEventPassthrough = true end)

    halfS = CFG.ARENA_SIZE / 2 - CFG.WALL_T
    cell = (halfS * 2) / N

    -- ① 全屏遮罩：超大深色方块，任何分辨率都盖住初始草地
    local cover = createControl(PREFAB.SQUARE, host, LAYER.COVER)
    if cover ~= nil then
        pcall(function()
            cover:SetSizeDelta(4000, 4000)
            cover.imageColor = COLOR.SCREEN
            cover.imageType = Enum.ImageType.Stretch
        end)
        cover:SetAnchoredPosition(0, 0)
    end

    -- ② 竞技场地板
    local bg = createControl(PREFAB.SQUARE, host, LAYER.BG)
    if bg ~= nil then
        pcall(function()
            bg:SetSizeDelta(CFG.ARENA_SIZE, CFG.ARENA_SIZE)
            bg.imageColor = COLOR.FLOOR
            bg.imageType = Enum.ImageType.Stretch
        end)
        bg:SetAnchoredPosition(0, 0)
    end

    -- ③ 地砖（一次性棋盘格，在坦克之前创建 → 层级在坦克/墙壁之下）
    buildFloorTiles()

    -- ④ 坦克（视觉全部由部件组拼接；墙壁在每回合开始时创建，自然压在坦克之上）
    player = createTank(COLOR.PLAYER)
    enemy  = createTank(COLOR.ENEMY)
    setupHUD()
    setupInput()

    pScore, eScore = 0, 0
    startNewRound()

    script:EnableUpdate(true)
    print("[坦克动荡] OnStart 完成")
end

function OnEnable()
    logicPaused = false
    print("[坦克动荡] OnEnable，逻辑恢复")
end

function OnDisable()
    logicPaused = true
    print("[坦克动荡] OnDisable，逻辑暂停")
end

function OnLevelUpdate(dt)
    if host == nil or logicPaused then return end
    if player == nil or enemy == nil then return end
    dt = math.min(dt, 0.05)

    if roundState == "roundover" then
        roundTimer = roundTimer - dt
        if roundTimer <= 0 then startNewRound() end
        return
    end

    player.lockT = math.max(0, player.lockT - dt)
    enemy.lockT  = math.max(0, enemy.lockT - dt)

    updateCharging(player, dt)
    updateCharging(enemy, dt)

    -- ① 玩家操作（遥控导弹期间移动键控导弹，坦克不动）
    if player.lockT <= 0 and player.rcProj == nil then
        local turn = (input.left and 1 or 0) - (input.right and 1 or 0)
        if turn ~= 0 then
            player.theta = player.theta + turn * CFG.TURN_SPEED * dt
        end
        local throttle = (input.fwd and 1 or 0) - (input.back and 1 or 0)
        if throttle ~= 0 then
            local speed = throttle > 0 and CFG.MOVE_SPEED or CFG.BACK_SPEED
            moveTank(player, math.cos(player.theta) * speed * throttle * dt,
                             math.sin(player.theta) * speed * throttle * dt)
        end
    end
    player.fireCd = math.max(0, player.fireCd - dt)

    -- ② 电脑
    updateEnemyAI(dt)

    -- ③ 加特林按住连射
    if player.fireHeld and player.weapon == "gatling" then tryFire(player) end
    if enemy.fireHeld  and enemy.weapon  == "gatling" then tryFire(enemy)  end

    -- ④ 坦克互推
    resolveTanks(player, enemy)

    -- ⑤ 弹射物 / 命中
    updateProjectiles(dt)
    checkProjHits()

    -- ⑥ 地雷 / 补给箱拾取
    updateMines(dt)
    updateCratePickups()

    -- ⑦ 补给箱定时刷新
    crateTimer = crateTimer - dt
    if crateTimer <= 0 then
        if #crates < CFG.CRATE_MAX then spawnCrate() end
        crateTimer = CFG.CRATE_SPAWN_MIN + math.random() * CFG.CRATE_SPAWN_VAR
    end

    -- ⑧ 光束 / 闪光动画
    updateBeams(dt)
    updateEffects(dt)

    -- ⑨ 坦克画面同步
    syncParts(player.visual, player.x, player.y, player.theta)
    syncParts(enemy.visual, enemy.x, enemy.y, enemy.theta)
end

function OnUpdate(dt)
end

function OnDestroy()
    print("[坦克动荡] OnDestroy，开始清理")
    if host ~= nil then
        pcall(function() host:RemoveAllKeyEventListeners() end)
    end
    for _, ctl in ipairs(createdCtrls) do
        destroyControl(ctl)
    end
    createdCtrls = {}
    print("[坦克动荡] 清理完成")
end
