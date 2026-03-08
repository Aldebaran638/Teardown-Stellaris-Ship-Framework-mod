-- 该脚本的body点击左键以后向前方发射快子光矛
#version 2
#include "script/include/common.lua"

---@diagnostic disable: undefined-global
---@diagnostic disable: duplicate-set-field


server = server or {}

-- 外来数据
-- 对于外来数据.当前阶段没有将这些数据分离的情况下,需要将这些函数放在server里,因为它们在server里被大量调用.至于client,要是用的话由server传进去
local firePosOffsetShip = Vec(0,0,4) -- 发射点相对于飞船中心的偏移
local fireDirRelative = Vec(0,0,1) -- 发射方向
local weaponType = "tachyonLance" -- 武器类型,用于客户端渲染时区分不同武器的特效
local maxRange = 2000 -- 武器最大射程
local shieldRadius = 7 --  球形护盾半径

function server.init()
    serverTime = 0
    -- 当前武器状态:
    -- "idle"      空闲
    -- "charging"  充能中
    -- "launching" 发射中
    server.weaponState = "idle"

    -- 上一帧武器状态(用于检测状态变化的第一帧)
    server.weaponStateLastTick = "idle"

    -- 充能所需时间
    server.chargeTime = 20

    -- 发射持续时间
    server.launchTime = 0

    -- 初始化当前飞船
    server.shipBody = FindBody("launcher", false)

end

-- 服务端函数:接收来自客户端的发射请求,设置蓄力时间为非0
function server_handleFireRequest()
    DebugWatch("server_receiveFireRequest", 111111111111111)
    if server.weaponState == "idle" then
        server.weaponState = "charging"
        server.chargeTime = 1
    end
end

-- x槽武器 计算命中点信息的统一函数
-- 参数:发射刚体ID 起始发射点 发射方向
-- 返回值: 激光结束点,命中目标ID(如果没有命中或者命中的是非群星body则为无效值),是否命中,是否命中的shape所属的body是群星body
-- 逻辑:
--   - 未命中任何 shape: isHit=false,isHitStellarisBody=false,hitTarget=0,endPos=最远点
--   - 命中 shape 但其父 Body 无 tag "stellarisShip": isHit=true,isHitStellarisBody=false,hitTarget=0,endPos=命中点
--   - 命中 shape 且其父 Body 有 tag "stellarisShip": isHit=true,isHitStellarisBody=true,hitTarget=该父 Body 的 handle,endPos=命中点
function server.xslot_computeHitResult(shipBodyId, firePosOffset, fireDirRelative)
    local function _xslot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
        local endPosStr
        if endPos == nil then
            endPosStr = "nil"
        elseif VecStr ~= nil then
            endPosStr = VecStr(endPos)
        else
            endPosStr = tostring(endPos)
        end
        DebugWatch(
            "xslot_computeHitResult",
            string.format(
                "endPos=%s hitTarget=%s isHit=%s isHitStellarisBody=%s",
                endPosStr,
                tostring(hitTarget),
                tostring(isHit),
                tostring(isHitStellarisBody)
            )
        )
    end

    local function _raySphereEntryT(origin, dirUnit, center, radius)
        DebugWatch("origin", origin)
        DebugWatch("dirUnit", dirUnit)
        DebugWatch("center", center)
        DebugWatch("radius", radius)
        -- 求射线 p=origin+dir*t 与球 |p-center|=radius 的入射点 t（最小非负解）
        local oc = VecSub(origin, center)
        local b = 2.0 * VecDot(oc, dirUnit)
        local c = VecDot(oc, oc) - radius * radius
        local disc = b * b - 4.0 * c
        if disc < 0.0 then
            return nil
        end
        local s = math.sqrt(disc)
        local t1 = (-b - s) * 0.5
        local t2 = (-b + s) * 0.5
        if t1 >= 0.0 then
            return t1
        end
        if t2 >= 0.0 then
            return t2
        end
        return nil
    end

    -- 默认无效值约定：Body handle 用 0 代表无效
    local invalidTarget = 0

    if shipBodyId == nil or shipBodyId == 0 or firePosOffset == nil or fireDirRelative == nil then
        local endPos, hitTarget, isHit, isHitStellarisBody = Vec(0, 0, 0), invalidTarget, false, false
        _xslot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
        return endPos, hitTarget, isHit, isHitStellarisBody
    end

    -- 1) 将发射点偏移转换成世界坐标
    local shipT = GetBodyTransform(shipBodyId)
    local origin = TransformToParentPoint(shipT, firePosOffset)

    -- 2) 将相对方向转换成世界方向向量，并归一化
    local dir = TransformToParentVec(shipT, fireDirRelative)
    local dirLen = VecLength(dir)
    if dirLen < 0.0001 then
        dir = TransformToParentVec(shipT, Vec(0, 0, -1))
        dirLen = VecLength(dir)
    end
    if dirLen < 0.0001 then
        dir = Vec(0, 0, -1)
        dirLen = 1.0
    end
    dir = VecScale(dir, 1.0 / dirLen)

    -- 3) 射线检测
    QueryRequire("physical")
    QueryRejectBody(shipBodyId)
    local hit, dist, _normal, shape = QueryRaycast(origin, dir, maxRange)
    DebugWatch("server.xslot_computeHitResult",3)
    if not hit then
        local endPos = VecAdd(origin, VecScale(dir, maxRange))
        local hitTarget, isHit, isHitStellarisBody = invalidTarget, false, false
        _xslot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
        return endPos, hitTarget, isHit, isHitStellarisBody
    end

    local endPos = VecAdd(origin, VecScale(dir, dist))
    if shape == nil or shape == 0 then
        local hitTarget, isHit, isHitStellarisBody = invalidTarget, true, false
        _xslot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
        return endPos, hitTarget, isHit, isHitStellarisBody
    end

    local targetBody = GetShapeBody(shape)
    if targetBody ~= nil and targetBody ~= 0 and HasTag(targetBody, "stellarisShip") then
        -- 命中群星飞船：把 endPos 修正为护盾球面入射点
        local bodyT = GetBodyTransform(targetBody)
        DebugWatch("bodyT",bodyT)
        local comLocal = GetBodyCenterOfMass(targetBody)
        DebugWatch("comLocal",comLocal)
        local center = TransformToParentPoint(bodyT, comLocal)
        DebugWatch("center",center)
        local entryT = _raySphereEntryT(origin, dir, center, shieldRadius)
        DebugWatch("entryT",entryT)
        if entryT ~= nil and entryT <= maxRange then
            endPos = VecAdd(origin, VecScale(dir, entryT))
            DebugWatch("server.xslot_computeHitResult",4)
        end

        local hitTarget, isHit, isHitStellarisBody = targetBody, true, true
        _xslot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
        return endPos, hitTarget, isHit, isHitStellarisBody
    end

    local hitTarget, isHit, isHitStellarisBody = invalidTarget, true, false
    _xslot_dbgReturn(endPos, hitTarget, isHit, isHitStellarisBody)
    return endPos, hitTarget, isHit, isHitStellarisBody
end

-- 根据命中信息结算效果
-- 如果isHitStellarisBody为true则说明命中的是群星飞船,命中后服务器不做任何事情.如果isHitStellarisBody为false但isHit为true则说明命中的是非群星飞船,在命中点产生一次半径为4的爆炸.如果isHit为false则说明没有命中,不产生任何事情.
function server.xslot_applyHitResult(endPos,isHit,isHitStellarisBody)
    if not isHit then
        return
    end
    if isHitStellarisBody then
        return
    end
    if endPos == nil then
        return
    end

    -- Teardown API: Explosion(pos, size) 其中 size 范围 0.5 - 4.0
    Explosion(endPos, 4.0)
end

-- 广播 开始充能

function server_broadcastChargingStart(shipBodyId, firePosOffsetShip, weaponType)
    -- 广播给所有客户端
    ClientCall(0, "client_ReceiveBroadcastChargingStart", shipBodyId, firePosOffsetShip, weaponType)
end

-- 广播 开始发射
-- 参数:发射刚体ID,发射点,命中点,是否命中,命中角度,是否命中群星飞船(暂定命中群星飞船就一定会触发护盾特效),武器类型
function server.broadcastLaunchingStart(shipBodyId, firePoint, hitPoint, didHit, hitTarget, didHitStellarisBody, weaponType)
    ClientCall(0, "client_ReceiveBroadcastLaunchingStart", shipBodyId, firePoint, hitPoint, didHit, hitTarget, didHitStellarisBody, weaponType)
end

-- 广播 武器回到 idle
function server_broadcastWeaponIdle(shipBodyId)
    -- 广播给所有客户端：该 ship 的 xSlot 回到 idle
    ClientCall(0, "client_ReceiveBroadcastWeaponIdle", shipBodyId)
end

-- 在tick中使用到的变量:
-- server.weaponState 当前武器状态("idle"/"charging"/"launching")
-- server.weaponStateLastTick 武器在上一帧的状态(用于检测状态变化的第一帧)
-- server.chargeTime 飞船充能所需时间
-- server.launchTime 飞船发射持续时间
function server.serverTick(dt)
    local state = server.weaponState
    DebugWatch("weaponState", state)
    ------------------------------------------------
    -- 状态持续逻辑
    ------------------------------------------------
    if state == "charging" then
        server.chargeTime = server.chargeTime - dt
        if server.chargeTime <= 0 then
            -- 结束蓄力,开始发射的第一帧
            -- 切换到发射状态
            server.weaponState = "launching"
            server.launchTime = 0.2
        end
    elseif state == "launching" then
        server.launchTime = server.launchTime - dt
        if server.launchTime <= 0 then
            -- 结束发射的第一帧
            -- 切换回空闲状态
            server.weaponState = "idle"
        end
    elseif state == "idle" then
    end
    ------------------------------------------------
    -- 状态变化检测(统一处理第一帧逻辑)
    ------------------------------------------------
    if server.weaponState ~= server.weaponStateLastTick then
        if server.weaponState == "charging" then
            -- 开始蓄力的第一帧,需要广播蓄力信息:广播发射刚体,发射点(相对于飞船)以及武器类型
            server_broadcastChargingStart(server.shipBody, firePosOffsetShip, weaponType)
        elseif server.weaponState == "launching" then
            -- 根据发射点和飞船朝向计算命中点,命中倾斜角以及命中信息(是否直接命中船体or命中非群星飞船)
            local endPos, hitTarget, isHit, isHitStellarisBody = server.xslot_computeHitResult(server.shipBody,firePosOffsetShip,fireDirRelative)
            -- 根据信息结算 命中效果
            server.xslot_applyHitResult(endPos,isHit,isHitStellarisBody)
            -- 广播发射信息
            server.broadcastLaunchingStart(server.shipBody,firePosOffsetShip, endPos, isHit, hitTarget, isHitStellarisBody, weaponType)
        elseif server.weaponState == "idle" then
            -- 广播 结束发射信息
            server_broadcastWeaponIdle(server.shipBody)
        end
    end
    server.weaponStateLastTick = server.weaponState
end


#include "client/client.lua"


-- 客户端 tick：只调用总控函数
function client.tick(dt)
    client.clientTick(dt)
end

function client.draw()
end

function server.tick(dt)
    serverTime = serverTime + (dt or 0)
    server.serverTick(dt)
end


