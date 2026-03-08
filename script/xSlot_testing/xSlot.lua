#version 2
#include "script/include/common.lua"

客户端中武器如何表示:
xSlot武器类型数组全局变量

本地飞船x槽的武器类型.每个数组的最大值需要由框架类型决定
local xSlot_weaponTypes{}
local lSlot_weaponTypes{}
local mSlot_weaponTypes{}
local sSlot_weaponTypes{}
local hSlot_weaponTypes{}
local gSlot_weaponTypes{}

客户端请求安装一个快子光矛:
stellarisShips_client_installWeapon("TachyonLance", "xSlot", 1).武器类型,安装槽位,安装数量


------------------------------------------------
-- xSlot 模块 开始
------------------------------------------------

local xSlot_weaponType_TachyonLance = "TachyonLance"
local xSlot_defaultWeaponType = xSlot_weaponType_TachyonLance

local xSlot_slotCount = 2

-- 冷却时间（秒）
local xSlot_cooldownTime = 4.0

-- 发射点/方向（飞船本地坐标）
local xSlot_muzzleLocal = Vec(0, 0, -6)
local xSlot_dirLocal = Vec(0, 0, -1)

-- 客户端渲染持续时间（秒）
local xSlot_client_beamDuration = 0.15

-- 音效：距离阈值（用于近/远音效切换）
local xSlot_audio_nearDistance = 60.0
local xSlot_audio_volume = 5.0

-- 客户端：活动激光束队列
-- beam = { t=number, weaponType=string, startPos=Vec, endPos=Vec, didHit=bool }
local xSlot_client_activeBeams = {}

-- 客户端：音效资源
local xSlot_client_fireSounds_near = {}
local xSlot_client_fireSounds_far = {}
local xSlot_client_hitSounds_near = {}
local xSlot_client_hitSounds_far = {}

-- 服务端：每艘飞船的武器类型与冷却
-- st = { weaponTypes={ [1]=string, [2]=string }, cooldowns={ [1]=number, [2]=number } }
local xSlot_serverVehicleStates = {}

local function xSlot_clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

local function xSlot_weapon_getMaxDist(weaponType)
    if weaponType == xSlot_weaponType_TachyonLance then
        return 500
    end
    return 500
end

local function xSlot_weapon_getExplosionSize(weaponType)
    if weaponType == xSlot_weaponType_TachyonLance then
        return 4.0
    end
    return 2.0
end

local function xSlot_server_getOrCreateState(veh)
    local st = xSlot_serverVehicleStates[veh]
    if st then
        return st
    end

    st = {
        weaponTypes = {
            [1] = xSlot_defaultWeaponType,
            [2] = xSlot_defaultWeaponType,
        },
        cooldowns = {
            [1] = 0,
            [2] = 0,
        },
    }
    xSlot_serverVehicleStates[veh] = st
    return st
end

local function xSlot_client_sound_pickAndPlay(list, pos, vol)
    if not pos then return end
    if not list or #list == 0 then return end
    local idx = math.random(1, #list)
    local s = list[idx]
    if s then
        PlaySound(s, pos, vol)
    end
end

local function xSlot_client_sound_playFire(weaponType, muzzleWorld)
    if weaponType ~= xSlot_weaponType_TachyonLance then
        return
    end

    local pT = GetPlayerTransform()
    local d = VecLength(VecSub(muzzleWorld, pT.pos))
    if d <= xSlot_audio_nearDistance then
        xSlot_client_sound_pickAndPlay(xSlot_client_fireSounds_near, muzzleWorld, xSlot_audio_volume)
    else
        xSlot_client_sound_pickAndPlay(xSlot_client_fireSounds_far, muzzleWorld, xSlot_audio_volume)
    end
end

local function xSlot_client_sound_playHit(weaponType, hitWorld)
    if weaponType ~= xSlot_weaponType_TachyonLance then
        return
    end

    local pT = GetPlayerTransform()
    local d = VecLength(VecSub(hitWorld, pT.pos))
    if d <= xSlot_audio_nearDistance then
        xSlot_client_sound_pickAndPlay(xSlot_client_hitSounds_near, hitWorld, xSlot_audio_volume)
    else
        xSlot_client_sound_pickAndPlay(xSlot_client_hitSounds_far, hitWorld, xSlot_audio_volume)
    end
end

local function xSlot_client_spawnLaserGlow_Tachyon(pos)
    local radius = 0.4
    for i = 1, 20 do
        ParticleReset()
        ParticleType("plain")
        ParticleCollide(0)
        ParticleRadius(0.03, 0.04)
        ParticleEmissive(20, 30)
        ParticleColor(0.0, 0.1, 1.0)
        ParticleGravity(0)
        ParticleAlpha(0.5, 0.5)

        local offset = Vec(
            (math.random() - 0.5) * 2 * radius,
            (math.random() - 0.5) * 2 * radius,
            (math.random() - 0.5) * 2 * radius
        )

        SpawnParticle(VecAdd(pos, offset), Vec(0, 0, 0), 0.15)
    end
end

-- ==============================
-- 第一层：改进版白色能量核心 快子光矛特效
-- ==============================
local function xSlot_client_drawBeam_Tachyon_1(startPos, endPos, radius)

    radius = radius or 1.5

    local dir = VecSub(endPos, startPos)
    local length = VecLength(dir)
    if length < 0.001 then return end
    dir = VecNormalize(dir)

    -- 构造正交基
    local up = Vec(0,1,0)
    if math.abs(VecDot(dir, up)) > 0.99 then
        up = Vec(1,0,0)
    end

    local right = VecNormalize(VecCross(dir, up))
    local forward = VecNormalize(VecCross(right, dir))

    -- 轴向分层参数
    local layersPerUnit = 8
    local particlesPerLayer = 6

    local totalLayers = math.floor(length * layersPerUnit)

    for layer = 0, totalLayers do

        local h = (layer / totalLayers) * length

        for i = 1, particlesPerLayer do

            -- 径向均匀采样
            local r = radius * math.sqrt(math.random())
            local theta = math.random() * math.pi * 2

            local radial =
                VecAdd(
                    VecScale(right, r * math.cos(theta)),
                    VecScale(forward, r * math.sin(theta))
                )

            local pos =
                VecAdd(
                    startPos,
                    VecAdd(
                        VecScale(dir, h),
                        radial
                    )
                )

            -- 更自然的能量衰减
            local falloff = 1 - (r / radius)^2
            if falloff < 0 then falloff = 0 end

            ParticleReset()
            ParticleType("plain")
            ParticleCollide(0)
            ParticleGravity(0)

            ParticleRadius(radius * 0.22, 0)
            ParticleEmissive(80 * falloff, 120 * falloff)
            ParticleColor(1,1,1)
            ParticleAlpha(0.98, 0)

            -- 微弱轴向流动
            local velocity = VecScale(dir, 2.5)

            SpawnParticle(pos, velocity, 0.06)
        end
    end
end

-- ==============================
-- 第二层：严格单根螺旋 快子光矛特效
-- ==============================
local function xSlot_client_drawBeam_Tachyon_2(startPos, endPos, radius)

    local helixRadius      = (radius or 0.2) * 2.5
    local pitch            = 15.0      -- 每旋转一圈，上升多少单位高度
    local particlesPerUnit = 10       -- 每单位长度粒子密度

    local dir = VecSub(endPos, startPos)
    local length = VecLength(dir)
    if length < 0.001 then return end
    dir = VecNormalize(dir)

    local up = Vec(0, 1, 0)
    if math.abs(VecDot(dir, up)) > 0.99 then
        up = Vec(1, 0, 0)
    end

    local right = VecNormalize(VecCross(dir, up))
    local perp  = VecNormalize(VecCross(right, dir))

    local totalParticles = math.max(2, math.floor(particlesPerUnit * length))

    for i = 0, totalParticles do

        local h = (i / totalParticles) * length

        -- 核心区别在这里
        local angle = 2 * math.pi * (h / pitch)

        local pos = VecAdd(
            VecAdd(startPos, VecScale(dir, h)),
            VecAdd(
                VecScale(right, helixRadius * math.cos(angle)),
                VecScale(perp,  helixRadius * math.sin(angle))
            )
        )

        ParticleReset()
        ParticleType("plain")
        ParticleCollide(0)
        ParticleGravity(0)
        ParticleRadius(0.05, 0)
        ParticleEmissive(10, 0)
        ParticleColor(0, 0.2, 1)
        ParticleAlpha(0.95, 0)

        SpawnParticle(pos, Vec(0,0,0), 0.08)
    end
end

-- 聚能电弧发射器特效
local function xSlot_client_drawBeam_focusedArcEmitters(startPos, endPos)
    local segLength = 5.0
    local jitter = 0.5

    local function rndVec(scale)
        return Vec(
            (math.random() - 0.5) * 4 * scale,
            (math.random() - 0.5) * 4 * scale,
            (math.random() - 0.5) * 4 * scale
        )
    end

    local dist = VecLength(VecSub(endPos, startPos))
    local segments = math.max(1, math.floor(dist / segLength + 0.5))

    local last = startPos
    for i = 1, segments do
        local tt = i / segments
        local p = VecLerp(startPos, endPos, tt)
        p = VecAdd(p, rndVec(jitter * tt))
        DrawLine(last, p, 1, 1, 1)
        xSlot_client_spawnLaserGlow_Tachyon(p)
        last = p
    end
end

local function xSlot_client_drawBeam(weaponType, startPos, endPos)
    if weaponType == xSlot_weaponType_TachyonLance then
        xSlot_client_drawBeam_focusedArcEmitters(startPos, endPos)
        return
    end
    xSlot_client_drawBeam_focusedArcEmitters(startPos, endPos)
end

local function xSlot_client_onLaserBroadcast(weaponType, startPos, endPos, didHit)
    table.insert(xSlot_client_activeBeams, {
        t = xSlot_client_beamDuration,
        weaponType = weaponType or xSlot_defaultWeaponType,
        startPos = startPos,
        endPos = endPos,
        didHit = didHit and true or false,
    })

    xSlot_client_sound_playFire(weaponType, startPos)
    if didHit then
        xSlot_client_sound_playHit(weaponType, endPos)
    end
end

local function xSlot_client_updateAndRender(dt)
    for i = #xSlot_client_activeBeams, 1, -1 do
        local b = xSlot_client_activeBeams[i]
        b.t = (b.t or 0) - (dt or 0)
        if b.t <= 0 then
            table.remove(xSlot_client_activeBeams, i)
        else
            xSlot_client_drawBeam(b.weaponType, b.startPos, b.endPos)
        end
    end
end

-- 客户端主函数：检测左键并上报“发射请求”（不上传方向，方向由服务端裁决）
local function xSlot_client_tryRequestFire()
    if not InputPressed("lmb") then
        return
    end
    if localPlayerId == -1 then
        return
    end

    local myVeh = GetPlayerVehicle()
    if not myVeh or myVeh == 0 then
        return
    end
    if not HasTag(myVeh, "ship") then
        return
    end

    ServerCall("xSlot_ServerRequestFire", localPlayerId)
end

-- 服务端：广播给所有客户端（包含：发射点、命中点、武器类型、是否命中）
local function xSlot_server_broadcast(weaponType, startPos, endPos, didHit)
    local didHitInt = didHit and 1 or 0

    if server_useClientCallZeroBroadcast then
        ClientCall(
            0,
            "xSlot_ClientLaserEvent",
            weaponType,
            startPos[1], startPos[2], startPos[3],
            endPos[1], endPos[2], endPos[3],
            didHitInt
        )
        return
    end

    local players = GetAllPlayers()
    for i = 1, #players do
        local p = players[i]
        if IsPlayerValid(p) then
            ClientCall(
                p,
                "xSlot_ClientLaserEvent",
                weaponType,
                startPos[1], startPos[2], startPos[3],
                endPos[1], endPos[2], endPos[3],
                didHitInt
            )
        end
    end
end

-- 服务端：计算激光世界发射点/命中点，并执行命中效果
local function xSlot_server_fireLaser(body, weaponType)
    local maxDist = xSlot_weapon_getMaxDist(weaponType)
    local t = GetBodyTransform(body)
    local muzzleWorld = TransformToParentPoint(t, xSlot_muzzleLocal)
    local dirWorld = VecNormalize(TransformToParentVec(t, xSlot_dirLocal))

    QueryRejectBody(body)
    local hit, hitDist = QueryRaycast(muzzleWorld, dirWorld, maxDist)
    local endPos
    if hit then
        endPos = VecAdd(muzzleWorld, VecScale(dirWorld, hitDist))
    else
        endPos = VecAdd(muzzleWorld, VecScale(dirWorld, maxDist))
    end

    if hit and weaponType == xSlot_weaponType_TachyonLance then
        Explosion(endPos, xSlot_weapon_getExplosionSize(weaponType))
    end

    return muzzleWorld, endPos, hit
end

-- 服务器主函数：服务端接收客户端发射请求后，按槽位冷却裁决发射
function xSlot_ServerRequestFire(playerId)
    if not IsPlayerValid(playerId) then
        return
    end

    local ok, veh = pcall(GetPlayerVehicle, playerId)
    if (not ok) or (not veh) or veh == 0 then
        return
    end
    if not HasTag(veh, "ship") then
        return
    end

    local body = GetVehicleBody(veh)
    if not body or body == 0 then
        return
    end

    local st = xSlot_server_getOrCreateState(veh)

    -- 槽位 1
    if (st.cooldowns[1] or 0) <= 0 then
        local weaponType = st.weaponTypes[1] or xSlot_defaultWeaponType
        local startPos, endPos, didHit = xSlot_server_fireLaser(body, weaponType)
        st.cooldowns[1] = xSlot_cooldownTime
        xSlot_server_broadcast(weaponType, startPos, endPos, didHit)
        return
    end

    -- 槽位 2
    if (st.cooldowns[2] or 0) <= 0 then
        local weaponType = st.weaponTypes[2] or xSlot_defaultWeaponType
        local startPos, endPos, didHit = xSlot_server_fireLaser(body, weaponType)
        st.cooldowns[2] = xSlot_cooldownTime
        xSlot_server_broadcast(weaponType, startPos, endPos, didHit)
        return
    end
end

-- RPC：server -> client
function xSlot_ClientLaserEvent(weaponType, sx, sy, sz, ex, ey, ez, didHitInt)
    local startPos = Vec(sx, sy, sz)
    local endPos = Vec(ex, ey, ez)
    local didHit = (didHitInt or 0) ~= 0
    xSlot_client_onLaserBroadcast(weaponType, startPos, endPos, didHit)
end

local function xSlot_server_tick(dt)
    for _, st in pairs(xSlot_serverVehicleStates) do
        for i = 1, xSlot_slotCount do
            local cd = st.cooldowns[i] or 0
            if cd > 0 then
                st.cooldowns[i] = math.max(0, cd - (dt or 0))
            end
        end
    end
end

local function xSlot_client_tick(dt)
    xSlot_client_tryRequestFire()
    xSlot_client_updateAndRender(dt)
end

local function xSlot_server_init()
    xSlot_serverVehicleStates = {}
end

local function xSlot_client_init()
    xSlot_client_fireSounds_near = {
        LoadSound("MOD/audio/tachyon_lance_fire_01.ogg"),
        LoadSound("MOD/audio/tachyon_lance_fire_02.ogg"),
        LoadSound("MOD/audio/tachyon_lance_fire_03.ogg"),
    }

    xSlot_client_fireSounds_far = {
        LoadSound("MOD/audio/distance_tachyon_lance_fire_01.ogg"),
        LoadSound("MOD/audio/distance_tachyon_lance_fire_02.ogg"),
        LoadSound("MOD/audio/distance_tachyon_lance_fire_03.ogg"),
    }

    xSlot_client_hitSounds_near = {
        LoadSound("MOD/audio/tachyon_lance_hit_01.ogg"),
        LoadSound("MOD/audio/tachyon_lance_hit_02.ogg"),
        LoadSound("MOD/audio/tachyon_lance_hit_03wav.ogg"),
    }

    xSlot_client_hitSounds_far = {
        LoadSound("MOD/audio/distance_tachyon_lance_hit_01.ogg"),
        LoadSound("MOD/audio/distance_tachyon_lance_hit_02.ogg"),
        LoadSound("MOD/audio/distance_tachyon_lance_hit_03.ogg"),
    }
end

------------------------------------------------
-- xSlot 模块 结束
------------------------------------------------