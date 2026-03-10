-- 该脚本的body点击左键以后向前方发射快子光矛
#version 2
#include "script/include/common.lua"

---@diagnostic disable: undefined-global
---@diagnostic disable: duplicate-set-field


server = server or {}

-- 服务端飞船状态表：以刚体ID为键，存储每艘飞船的全部运行时数据
server.ships = server.ships or {}

local defaultShipType = "enigmaticCruiser"

-- 服务端函数：确保某个飞船在状态表中存在。
-- 如果找不到，则按默认飞船模板补一份可计算的完整初始状态，避免出现 nil。
function server.ensureShipState(shipBodyId, shipType)
    DebugWatch("server.ensureShipState", 111111)
    if shipBodyId == nil or shipBodyId == 0 then
        return nil
    end
    if server.ships[shipBodyId] == nil then
        server.onBodyRegister(shipBodyId, shipType or defaultShipType)
    end
    return server.ships[shipBodyId]
end

-- 服务端函数：注册飞船刚体。在每个飞船刚体被创建的第一帧调用。
-- shipType 与 shipData 中的键对应（例如 "enigmaticCruiser"）
-- 注意：静态不变数据（shieldRadius、HP上限、回复速率等）始终从 shipData[shipType] 取，
--       此处只存会在运行时发生变化的状态。
function server.onBodyRegister(shipBodyId, shipType)
    DebugWatch("server.onBodyRegister", 111111)
    local resolvedShipType = shipType or defaultShipType
    local template = (shipData and shipData[resolvedShipType]) or (shipData and shipData[defaultShipType]) or {}
    -- 按 xSlotNum 初始化 x 槽武器状态列表
    -- 每个槽只记录：当前装备的武器类型 + 当前冷却剩余时间
    -- 默认武器为 tachyonLance，cd=0 表示可立即开火
    local xSlots = {}
    local xSlotNum = template.xSlotNum or 1
    for i = 1, xSlotNum do
        xSlots[i] = {
            weaponType = "tachyonLance",
            cd = 0,
        }
    end

    server.ships[shipBodyId] = {
        id = shipBodyId,
        shipType = template.shipType or resolvedShipType,
        shieldHP = template.shieldHP or 0,
        armorHP = template.armorHP or 0,
        bodyHP = template.bodyHP or 0,
        xSlots = xSlots,
    }
end

-- x 槽控制模块从外部抽取为独立文件：script/xslotControl.lua
#include "xSlotControl.lua"

-- 服务端初始化
function server.init()
    DebugWatch("server.init", 111111)
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
    server.launchTime = 0.2

    -- 初始化当前飞船
    server.shipBody = FindBody("launcher", false)

    -- 注册飞船并加载飞船数据
    server.onBodyRegister(server.shipBody, defaultShipType)

end

-- 在tick中使用到的变量:
-- server.weaponState 当前武器状态("idle"/"charging"/"launching")
-- server.weaponStateLastTick 武器在上一帧的状态(用于检测状态变化的第一帧)
-- server.chargeTime 飞船充能所需时间
-- server.launchTime 飞船发射持续时间
function server.serverTick(dt)
    DebugWatch("server.serverTick", 112221)
    server.xSlotControlTick(dt)
end


#include "client/client.lua"


-- 客户端 tick：只调用总控函数
function client.tick(dt)
    DebugWatch("client.tick", 111111)
    client.clientTick(dt)
end

function client.draw()
end

function server.tick(dt)
    DebugWatch("server.tick", 111111)
    server.serverTick(dt)
end


