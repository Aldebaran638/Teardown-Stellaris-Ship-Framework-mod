#version 2
#include "script/include/common.lua"

------------------------------------------------
-- 实体引用
------------------------------------------------

-- 飞船Vehicle
local shipVeh
-- 飞船Body
local shipBody

-- 武器发射器 Shape（可选，tag: primaryWeaponLauncher）
local laserShape

-- 发射器 Shape（tag: missileLauncher，存在多个）
local missileLauncherShapes = {}

-- 船体 Shape（tag: hull）
local hullShape

-- 推进器 Shape（tag: thruster，存在多个）
local thrusterShapes = {}

-- 引擎 Shape（tag: engine，存在多个）
local engineShapes = {}

-- 小推进器 Shape（tag: smallThruster，存在多个）
local smallThrusterShapes = {}

-- 灯光系统 Shape（tag: secondaryLightSystem / mainLightSystem）
local secondaryLightSystemShape
local mainLightSystemShape

-- 装甲 Shape（tag: armor）
local armorShape

-- 客户端本地玩家 id（通过 IsPlayerLocal 从 GetAllPlayers 中识别）
local localPlayerId = -1

-- 服务器端：时间累计（用 dt 累加，避免依赖 GetTime API）
local serverTime = 0

-- 服务端广播方式：
-- false = 安全的逐个玩家 ClientCall（已验证可用）
-- true  = 使用 ClientCall(0, ...) 作为广播（你已实测两端可见）
local server_useClientCallZeroBroadcast = true

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

------------------------------------------------
-- MSlot 模块 开始
------------------------------------------------

-- 槽位数量（固定 4 个 M 槽）
local MSlot_slotCount = 4

-- 冷却时间（秒）
local MSlot_cooldownTime = 3.0

-- 导弹 XML 路径
local MSlot_missileXmlPath = "MOD/missile/missile.xml"

-- 导弹发射挂点（飞船本地坐标）
local MSlot_missileSpawnLocal = Vec(0, 8, 0)

-- 导弹仰角限制（度），相对飞船本地 Y 轴，正负对称
local MSlot_missilePitchLimit = 30.0

-- 音效：距离阈值（用于近/远音效切换）
local MSlot_audio_nearDistance = 60.0
local MSlot_audio_volume = 5.0

-- 客户端：音效资源
local MSlot_client_fireSounds_near = {}
local MSlot_client_fireSounds_far = {}

-- 服务端：每艘飞船的冷却
-- st = { cooldowns={ [1]=number, [2]=number, [3]=number, [4]=number } }
local MSlot_serverVehicleStates = {}


-- 工具：夹取
local function MSlot_clamp (v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

-- 客户端：从列表里随机挑一个音效播放
local function MSlot_client_sound_pickAndPlay (list, pos, vol)
    if not pos then return end
    if not list or #list == 0 then return end
    local idx = math.random(1, #list)
    local s = list[idx]
    if s then
        PlaySound(s, pos, vol)
    end
end

-- 客户端：接收服务端广播后播放发射音效（近/远）
local function MSlot_client_playLaunchSound (pos)
    if not pos then return end
    local pT = GetPlayerTransform()
    local d = VecLength(VecSub(pos, pT.pos))
    if d <= MSlot_audio_nearDistance then
        MSlot_client_sound_pickAndPlay(MSlot_client_fireSounds_near, pos, MSlot_audio_volume)
    else
        MSlot_client_sound_pickAndPlay(MSlot_client_fireSounds_far, pos, MSlot_audio_volume)
    end
end

-- 客户端函数：客户端检测用户是否点击 g 键。如果点击，就向服务器发送请求（同时上传摄像机前向用于服务端裁决方向）
local function MSlot_client_tryRequestFire ()
    if not InputPressed("g") then
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

    local camT = GetCameraTransform()
    local camForward = TransformToParentVec(camT, Vec(0, 0, -1))
    camForward = VecNormalize(camForward)

    ServerCall(
        "MSlot_ServerRequestFire",
        localPlayerId,
        camForward[1], camForward[2], camForward[3]
    )
end

-- 服务端：获取或创建某艘飞船的 MSlot 状态
local function MSlot_server_getOrCreateState (veh)
    local st = MSlot_serverVehicleStates[veh]
    if st then
        return st
    end

    st = {
        cooldowns = {
            [1] = 0,
            [2] = 0,
            [3] = 0,
            [4] = 0,
        },
    }

    MSlot_serverVehicleStates[veh] = st
    return st
end

-- 服务端：根据“客户端上传的摄像机前向”计算导弹发射方向（世界坐标），并限制仰角
local function MSlot_server_getMissileLaunchDirection (shipBodyHandle, camFx, camFy, camFz)
    if not shipBodyHandle or shipBodyHandle == 0 then
        return Vec(0, 0, -1)
    end

    local shipT = GetBodyTransform(shipBodyHandle)

    local camForward = Vec(camFx or 0, camFy or 0, camFz or 0)
    if VecLength(camForward) < 0.001 then
        camForward = TransformToParentVec(shipT, Vec(0, 0, -1))
    end
    camForward = VecNormalize(camForward)

    -- 转换到飞船本地坐标系
    local localDir = TransformToLocalVec(shipT, camForward)

    -- 在本地坐标系下计算水平分量长度（X-Z 平面）和仰角
    local horzLen = math.sqrt(localDir[1] * localDir[1] + localDir[3] * localDir[3])
    local elevation = math.deg(math.atan2(localDir[2], horzLen))

    -- 限制仰角到合法范围
    elevation = MSlot_clamp(elevation, -MSlot_missilePitchLimit, MSlot_missilePitchLimit)
    local elevRad = math.rad(elevation)

    -- 用夹角后的仰角重建本地方向向量，保持原来的 X-Z 比例
    local newLocalDir
    if horzLen < 0.0001 then
        newLocalDir = Vec(0, math.sin(elevRad), -math.cos(elevRad))
    else
        local hx = localDir[1] / horzLen
        local hz = localDir[3] / horzLen
        newLocalDir = Vec(
            hx * math.cos(elevRad),
            math.sin(elevRad),
            hz * math.cos(elevRad)
        )
    end

    return VecNormalize(TransformToParentVec(shipT, newLocalDir))
end

-- 服务端：广播导弹发射位置给所有客户端
local function MSlot_server_broadcastMissileFired (pos)
    if not pos then
        return
    end

    if server_useClientCallZeroBroadcast then
        ClientCall(0, "MSlot_ClientMissileFired", pos[1], pos[2], pos[3])
        return
    end

    local players = GetAllPlayers()
    for i = 1, #players do
        local p = players[i]
        if IsPlayerValid(p) then
            ClientCall(p, "MSlot_ClientMissileFired", pos[1], pos[2], pos[3])
        end
    end
end

-- 服务端：在飞船指定挂点 Spawn 导弹，并返回发射位置
local function MSlot_server_spawnMissileFromShip (shipBodyHandle, camFx, camFy, camFz)
    if not shipBodyHandle or shipBodyHandle == 0 then
        return nil
    end

    local shipT = GetBodyTransform(shipBodyHandle)

    local missilePos = TransformToParentPoint(shipT, MSlot_missileSpawnLocal)
    local launchDir = MSlot_server_getMissileLaunchDirection(shipBodyHandle, camFx, camFy, camFz)
    local missileRot = QuatLookAt(missilePos, VecAdd(missilePos, launchDir))
    local missileT = Transform(missilePos, missileRot)

    local handles = Spawn(MSlot_missileXmlPath, missileT)

    local missileBody = 0
    for i = 1, #handles do
        if GetEntityType(handles[i]) == "body" then
            missileBody = handles[i]
            break
        end
    end

    if missileBody ~= 0 then
        SetTag(missileBody, "owner_body", tostring(shipBodyHandle))
    end

    return missilePos
end

-- 服务端函数：维护 4 槽冷却，接收客户端请求后找到第一个冷却为 0 的槽位并发射导弹
function MSlot_ServerRequestFire (playerId, camFx, camFy, camFz)
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

    local st = MSlot_server_getOrCreateState(veh)

    for i = 1, MSlot_slotCount do
        if (st.cooldowns[i] or 0) <= 0 then
            local pos = MSlot_server_spawnMissileFromShip(body, camFx, camFy, camFz)
            if not pos then
                return
            end
            st.cooldowns[i] = MSlot_cooldownTime
            MSlot_server_broadcastMissileFired(pos)
            return
        end
    end
end

-- RPC：server -> client
function MSlot_ClientMissileFired (x, y, z)
    local pos = Vec(x, y, z)
    MSlot_client_playLaunchSound(pos)
end

-- 服务端 tick：递减冷却
local function MSlot_server_tick (dt)
    for _, st in pairs(MSlot_serverVehicleStates) do
        for i = 1, MSlot_slotCount do
            local cd = st.cooldowns[i] or 0
            if cd > 0 then
                st.cooldowns[i] = math.max(0, cd - (dt or 0))
            end
        end
    end
end

-- 客户端 tick：检测输入并请求
local function MSlot_client_tick (dt)
    MSlot_client_tryRequestFire()
end

-- 服务端 init
local function MSlot_server_init ()
    MSlot_serverVehicleStates = {}
end

-- 客户端 init：加载音效资源
local function MSlot_client_init ()
    MSlot_client_fireSounds_near = {
        LoadSound("MOD/audio/missile_fire_01.ogg"),
        LoadSound("MOD/audio/missile_fire_02.ogg"),
    }

    MSlot_client_fireSounds_far = {
        LoadSound("MOD/audio/distance_missile_fire_01.ogg"),
        LoadSound("MOD/audio/distance_missile_fire_02.ogg"),
        LoadSound("MOD/audio/distance_missile_fire_03.ogg"),
    }
end

------------------------------------------------
-- MSlot 模块 结束
------------------------------------------------

------------------------------------------------
-- 网络/输入模块 开始
------------------------------------------------

-- 功能1：计算本地玩家 id（通过 IsPlayerLocal 探测）
local function client_refreshLocalPlayerId()
    if localPlayerId ~= -1 then
        return
    end
    local players = GetAllPlayers()
    for i = 1, #players do
        local p = players[i]
        if IsPlayerValid(p) and IsPlayerLocal(p) then
            localPlayerId = p
            return
        end
    end
end

-- 功能2：客户端 tick 总控（tick 函数只调用这个）
local function client_tick_main(dt)
    dt = dt or (1 / math.max(1, GetFps()))
    client_refreshLocalPlayerId()
    xSlot_client_tick(dt)
    MSlot_client_tick(dt)
    fallenEmpireCruiser_move_client_tick(dt)
    fallenEmpireCruiser_engineDraw_client_tick(dt)
    fallenEmpireCruiser_shipWorld_client_tick(dt)
    fallenEmpireCruiser_drivenShipBodies_client_tick(dt)
    fallenEmpireCruiser_engineAudio_client_tick(dt)
    fallenEmpireCruiser_thrusterAudio_client_tick(dt)
    fallenEmpireCruiser_camera_client_tick(dt)
    fallenEmpireCruiser_attitudeControl_client_tick(dt)
end

------------------------------------------------
-- 网络/输入模块 结束
------------------------------------------------

------------------------------------------------
-- fallenEmpireCruiser_driverLock 模块 开始
------------------------------------------------

-- 服务端：同一艘飞船只能有一个驾驶者（跨模块共享：move / attitudeControl）
local fallenEmpireCruiser_driverLock_byVehicle = {}

local function fallenEmpireCruiser_driverLock_tryAcquire(veh, playerId)
    if not veh or veh == 0 or not IsPlayerValid(playerId) then
        return false
    end

    local cur = fallenEmpireCruiser_driverLock_byVehicle[veh]
    if cur and cur ~= playerId and IsPlayerValid(cur) then
        local ok2, veh2 = pcall(GetPlayerVehicle, cur)
        if ok2 and veh2 == veh then
            return false
        end
    end

    fallenEmpireCruiser_driverLock_byVehicle[veh] = playerId
    return true
end

local function fallenEmpireCruiser_driverLock_get(veh)
    return fallenEmpireCruiser_driverLock_byVehicle[veh]
end

local function fallenEmpireCruiser_driverLock_clear(veh)
    fallenEmpireCruiser_driverLock_byVehicle[veh] = nil
end

local function fallenEmpireCruiser_driverLock_server_tick(dt)
    for veh, driverId in pairs(fallenEmpireCruiser_driverLock_byVehicle) do
        if not veh or veh == 0 or (not driverId) or (not IsPlayerValid(driverId)) then
            fallenEmpireCruiser_driverLock_byVehicle[veh] = nil
        else
            local ok, curVeh = pcall(GetPlayerVehicle, driverId)
            if (not ok) or curVeh ~= veh then
                fallenEmpireCruiser_driverLock_byVehicle[veh] = nil
            end
        end
    end
end

------------------------------------------------
-- fallenEmpireCruiser_driverLock 模块 结束
------------------------------------------------

------------------------------------------------
-- antiG 模块 开始
------------------------------------------------

-- 抗重力加速度（用于抵消重力用），近似取 g=10
local antiG_accel = 10.0

-- 服务器端：获取 shipBody 的质量，并为 shipBody 施加竖直向上的抗重力“力”（以每帧冲量方式实现）
-- shipBody: body handle
-- dt: 秒
local function antiG_server_apply(shipBody, dt)
    if not shipBody or shipBody == 0 then
        return
    end

    dt = dt or 0

    local okMass, mass = pcall(GetBodyMass, shipBody)
    if (not okMass) or (not mass) or mass == 0 then
        return
    end

    local okT, t = pcall(GetBodyTransform, shipBody)
    if (not okT) or (not t) then
        return
    end

    local antiGImpulse = VecScale(Vec(0, 1, 0), mass * antiG_accel * dt)
    ApplyBodyImpulse(shipBody, t.pos, antiGImpulse)
end

------------------------------------------------
-- antiG 模块 结束
------------------------------------------------

------------------------------------------------
-- pV2Damping 模块 开始
------------------------------------------------

-- 阻尼系数 p（力的大小 = p * v^2）
-- 注：这里的“力”用每帧冲量 dt 来实现：impulse = force * dt
local pV2Damping_p = 0.05

-- 速度过小则不施加（避免抖动/除零）
local pV2Damping_minSpeed = 0.05

-- 服务器端：始终给飞船提供一个大小为 p*v^2、方向反向于飞船运动方向的力
-- shipBody: body handle
-- dt: 秒
local function pV2Damping_server_apply(shipBody, dt)
    if not shipBody or shipBody == 0 then
        return
    end

    dt = dt or 0
    if dt <= 0 then
        return
    end

    local okVel, vel = pcall(GetBodyVelocity, shipBody)
    if (not okVel) or (not vel) then
        return
    end

    local speed = VecLength(vel)
    if speed < pV2Damping_minSpeed then
        return
    end

    local okT, t = pcall(GetBodyTransform, shipBody)
    if (not okT) or (not t) then
        return
    end

    local vDir = VecScale(vel, 1.0 / speed)
    local mass = GetBodyMass(shipBody)

    -- 你想要的“加速度大小”
    local accelMag = pV2Damping_p * speed * speed

    -- 真实物理需要的力
    local forceMag = mass * accelMag

    local force = VecScale(vDir, -forceMag)
    local impulse = VecScale(force, dt)
    ApplyBodyImpulse(shipBody, t.pos, impulse)
end

------------------------------------------------
-- pV2Damping 模块 结束
------------------------------------------------

------------------------------------------------
-- fallenEmpireCruiser_move 模块 开始
------------------------------------------------

-- 推进加速度（局部 Z 轴），数值越大推进越猛
local fallenEmpireCruiser_move_thrustAccel = 30.0

-- 服务端输入过期时间（防止卡住持续推进）
local fallenEmpireCruiser_move_inputTimeout = 0.25

-- 客户端上报节流（秒）
local fallenEmpireCruiser_move_clientSendInterval = 0.05

-- 客户端本地计时（不依赖 GetTime）
local fallenEmpireCruiser_move_clientTime = 0

-- 客户端上次上报状态
local fallenEmpireCruiser_move_clientLastSendTime = -999
local fallenEmpireCruiser_move_clientLastW = false
local fallenEmpireCruiser_move_clientLastS = false
local fallenEmpireCruiser_move_clientLastInShip = false

-- 服务端缓存的载具状态（vehicleId -> state）
-- state = { driverId=number, w=bool, s=bool, t=number, body=handle, thrusters={...}, thrustersT=number }
local fallenEmpireCruiser_move_serverVehicleStates = {}

-- 功能0：判断是否是“飞船载具”（用 tag=ship 识别）
local function fallenEmpireCruiser_move_isShipVehicle(veh)
    if not veh or veh == 0 then
        return false
    end
    local ok, has = pcall(HasTag, veh, "ship")
    return ok and has
end

-- 功能0：获取载具 body
local function fallenEmpireCruiser_move_getVehicleBodySafe(veh)
    local ok, body = pcall(GetVehicleBody, veh)
    if not ok or not body or body == 0 then
        return 0
    end
    return body
end

-- 功能0：获取某艘飞船上的 thruster shapes（仅该载具内）
local function fallenEmpireCruiser_move_collectThrustersForVehicle(veh)
    local body = fallenEmpireCruiser_move_getVehicleBodySafe(veh)
    if body == 0 then
        return {}, 0
    end

    -- 优先：从 body 的 shapes 里按 tag 过滤
    local ok, bodyShapes = pcall(GetBodyShapes, body)
    if ok and bodyShapes then
        local res = {}
        for i = 1, #bodyShapes do
            local sh = bodyShapes[i]
            if sh and sh ~= 0 then
                local okTag, has = pcall(HasTag, sh, "thruster")
                if okTag and has then
                    res[#res + 1] = sh
                end
            end
        end
        return res, body
    end

    -- 回退：全局找 thruster，再按 body 过滤
    local all = FindShapes("thruster", true) or {}
    local res = {}
    for i = 1, #all do
        local sh = all[i]
        if sh and sh ~= 0 then
            local okBody, shBody = pcall(GetShapeBody, sh)
            if okBody and shBody == body then
                res[#res + 1] = sh
            end
        end
    end
    return res, body
end

-- 功能1：客户端检测按键并向服务端上报（只上报按键状态，不决定方向）
local function fallenEmpireCruiser_move_client_reportInput(dt)
    fallenEmpireCruiser_move_clientTime = fallenEmpireCruiser_move_clientTime + (dt or 0)

    if localPlayerId == -1 then
        return
    end

    local myVeh = GetPlayerVehicle()
    local isInShip = fallenEmpireCruiser_move_isShipVehicle(myVeh)

    local wDown = false
    local sDown = false
    if isInShip then
        wDown = InputDown("w")
        sDown = InputDown("s")
    end

    local changed = (wDown ~= fallenEmpireCruiser_move_clientLastW)
        or (sDown ~= fallenEmpireCruiser_move_clientLastS)
        or (isInShip ~= fallenEmpireCruiser_move_clientLastInShip)

    local due = (fallenEmpireCruiser_move_clientTime - fallenEmpireCruiser_move_clientLastSendTime) >= fallenEmpireCruiser_move_clientSendInterval

    if changed or due then
        ServerCall(
            "fallenEmpireCruiser_move_ReportInput",
            localPlayerId,
            wDown and 1 or 0,
            sDown and 1 or 0
        )

        fallenEmpireCruiser_move_clientLastSendTime = fallenEmpireCruiser_move_clientTime
        fallenEmpireCruiser_move_clientLastW = wDown
        fallenEmpireCruiser_move_clientLastS = sDown
        fallenEmpireCruiser_move_clientLastInShip = isInShip
    end
end

-- 功能2：服务端接收移动请求（RPC：client -> server）
-- 注意：ServerCall 触发时，服务端执行同名的全局函数
function fallenEmpireCruiser_move_ReportInput(playerId, wDown, sDown)
    if not IsPlayerValid(playerId) then
        return
    end

    -- 服务端校验：只接受“正在驾驶某艘 ship 飞船载具”的玩家上报
    local ok, veh = pcall(GetPlayerVehicle, playerId)
    if not ok then
        return
    end
    if not fallenEmpireCruiser_move_isShipVehicle(veh) then
        return
    end

    -- 跨模块单驾驶者锁（move / attitudeControl 共用）
    if not fallenEmpireCruiser_driverLock_tryAcquire(veh, playerId) then
        return
    end

    local st = fallenEmpireCruiser_move_serverVehicleStates[veh]
    if not st then
        st = { driverId = nil, w = false, s = false, t = -999, body = 0, thrusters = {}, thrustersT = -999 }
        fallenEmpireCruiser_move_serverVehicleStates[veh] = st
    end

    -- 必须存在该载具自身的 thruster shapes，否则不做任何事情
    if (serverTime - (st.thrustersT or -999)) > 0.5 then
        st.thrusters, st.body = fallenEmpireCruiser_move_collectThrustersForVehicle(veh)
        st.thrustersT = serverTime
    end
    if not st.thrusters or #st.thrusters == 0 then
        return
    end

    st.driverId = playerId
    st.w = (wDown == 1)
    st.s = (sDown == 1)
    st.t = serverTime
end

-- 功能3：服务端根据最新输入为飞船添加推进力（方向由服务端按飞船朝向决定）
local function fallenEmpireCruiser_move_server_applyImpulse(dt)
    for veh, st in pairs(fallenEmpireCruiser_move_serverVehicleStates) do
        if not veh or veh == 0 or not st then
            fallenEmpireCruiser_move_serverVehicleStates[veh] = nil
        else
            -- 驾驶者必须有效、仍在驾驶该载具、且输入未过期
            if not st.driverId or not IsPlayerValid(st.driverId) then
                fallenEmpireCruiser_move_serverVehicleStates[veh] = nil
            else
                local okVeh, curVeh = pcall(GetPlayerVehicle, st.driverId)
                if (not okVeh) or curVeh ~= veh then
                    fallenEmpireCruiser_move_serverVehicleStates[veh] = nil
                elseif (serverTime - (st.t or -999)) > fallenEmpireCruiser_move_inputTimeout then
                    fallenEmpireCruiser_move_serverVehicleStates[veh] = nil
                else
                    if not fallenEmpireCruiser_move_isShipVehicle(veh) then
                        fallenEmpireCruiser_move_serverVehicleStates[veh] = nil
                    else
                        -- 确保 body / thrusters 可用
                        if not st.body or st.body == 0 then
                            st.body = fallenEmpireCruiser_move_getVehicleBodySafe(veh)
                        end
                        if (serverTime - (st.thrustersT or -999)) > 1.0 then
                            st.thrusters, st.body = fallenEmpireCruiser_move_collectThrustersForVehicle(veh)
                            st.thrustersT = serverTime
                        end
                        if not st.body or st.body == 0 or not st.thrusters or #st.thrusters == 0 then
                            -- 该船没有推进器就不驱动
                        else
                            local t = GetBodyTransform(st.body)
                            local mass = GetBodyMass(st.body)

                            -- 悬浮：抵消重力（让飞船基本悬浮）
                            -- 使用 antiG 模块处理重力抵消

                            -- 推进：根据输入在机体前后方向施加冲量（局部 Z 轴）
                            local localAcc = Vec(0, 0, 0)
                            if st.w then
                                localAcc = VecAdd(localAcc, Vec(0, 0, -fallenEmpireCruiser_move_thrustAccel))
                            end
                            if st.s then
                                localAcc = VecAdd(localAcc, Vec(0, 0, fallenEmpireCruiser_move_thrustAccel))
                            end

                            if localAcc[1] ~= 0 or localAcc[2] ~= 0 or localAcc[3] ~= 0 then
                                local accWorld = TransformToParentVec(t, localAcc)
                                local impulse = VecScale(accWorld, mass * dt)
                                ApplyBodyImpulse(st.body, t.pos, impulse)
                            end
                        end
                    end
                end
            end
        end
    end
end

-- 功能4：客户端 tick 总控（tick 函数只调用这个）
function fallenEmpireCruiser_move_client_tick(dt)
    fallenEmpireCruiser_move_client_reportInput(dt)
end

-- 功能5：服务端 tick 总控（tick 函数只调用这个）
local function fallenEmpireCruiser_move_server_tick(dt)
    fallenEmpireCruiser_move_server_applyImpulse(dt or 0)
end

------------------------------------------------
-- fallenEmpireCruiser_move 模块 结束
------------------------------------------------

------------------------------------------------
-- fallenEmpireCruiser_engineDraw 模块 开始
------------------------------------------------

-- 全场扫描 shapes 的刷新间隔（秒）
local fallenEmpireCruiser_engineDraw_refreshInterval = 1.0

-- 粒子生成间隔（秒）：越小越密
local fallenEmpireCruiser_engineDraw_spawnInterval = 0.06

-- 每次生成的最大粒子数量（避免场景里太多引擎导致卡顿）
local fallenEmpireCruiser_engineDraw_maxParticlesPerBurst = 48

-- 内部状态
local fallenEmpireCruiser_engineDraw_time = 0
local fallenEmpireCruiser_engineDraw_nextRefreshTime = 0
local fallenEmpireCruiser_engineDraw_spawnAccum = 0
local fallenEmpireCruiser_engineDraw_shapes = {}

-- 功能1：刷新全场 engine/thruster/smallThruster shapes 列表
local function fallenEmpireCruiser_engineDraw_refreshShapes()
    local combined = {}

    local engines = FindShapes("engine", true) or {}
    local thrusters = FindShapes("thruster", true) or {}
    local smallThrusters = FindShapes("smallThruster", true) or {}

    for i = 1, #engines do combined[#combined + 1] = engines[i] end
    for i = 1, #thrusters do combined[#combined + 1] = thrusters[i] end
    for i = 1, #smallThrusters do combined[#combined + 1] = smallThrusters[i] end

    fallenEmpireCruiser_engineDraw_shapes = combined
end

-- 功能2：在一个位置生成“微微燃烧”的光晕粒子（无尾焰：速度恒为 0）
local function fallenEmpireCruiser_engineDraw_spawnHalo(pos, intensity)
    ParticleReset()
    ParticleType("plain")
    ParticleGravity(0)
    ParticleDrag(8)

    -- 轻微燃烧：偏橙黄、较高自发光、较小半径
    local r = 1.0
    local g = 0.55
    local b = 0.15
    ParticleColor(r, g, b)
    ParticleEmissive(2.8 * intensity, 0)
    ParticleRadius(0.06, 0)

    -- 无尾焰：不赋予初速度
    SpawnParticle(pos, Vec(0, 0, 0), 0.12)
end

-- 功能3：客户端 tick 总控（tick 函数只调用这个）
function fallenEmpireCruiser_engineDraw_client_tick(dt)
    fallenEmpireCruiser_engineDraw_time = fallenEmpireCruiser_engineDraw_time + (dt or 0)

    if fallenEmpireCruiser_engineDraw_time >= fallenEmpireCruiser_engineDraw_nextRefreshTime then
        fallenEmpireCruiser_engineDraw_refreshShapes()
        fallenEmpireCruiser_engineDraw_nextRefreshTime = fallenEmpireCruiser_engineDraw_time + fallenEmpireCruiser_engineDraw_refreshInterval
    end

    fallenEmpireCruiser_engineDraw_spawnAccum = fallenEmpireCruiser_engineDraw_spawnAccum + (dt or 0)
    if fallenEmpireCruiser_engineDraw_spawnAccum < fallenEmpireCruiser_engineDraw_spawnInterval then
        return
    end
    fallenEmpireCruiser_engineDraw_spawnAccum = 0

    local shapes = fallenEmpireCruiser_engineDraw_shapes
    if not shapes or #shapes == 0 then
        return
    end

    local maxN = math.min(#shapes, fallenEmpireCruiser_engineDraw_maxParticlesPerBurst)
    for i = 1, maxN do
        local sh = shapes[i]
        if sh and sh ~= 0 then
            local t = GetShapeWorldTransform(sh)

            -- 轻微随机抖动，模拟“燃烧闪烁”，但不形成尾焰
            local jitter = 0.03
            local flicker = 0.7 + 0.3 * math.abs(math.sin(fallenEmpireCruiser_engineDraw_time * 9.0 + i))
            local p = TransformToParentPoint(t, Vec(
                (math.random() - 0.5) * 2 * jitter,
                (math.random() - 0.5) * 2 * jitter,
                (math.random() - 0.5) * 2 * jitter
            ))
            fallenEmpireCruiser_engineDraw_spawnHalo(p, flicker)
        end
    end
end

------------------------------------------------
-- fallenEmpireCruiser_engineDraw 模块 结束
------------------------------------------------

------------------------------------------------
-- fallenEmpireCruiser_localShip 模块 开始
------------------------------------------------

-- 功能1：获取“本地玩家当前驾驶的飞船”（tag=ship）上下文
-- 返回：isDriving, veh, body, tBody, velBody
local function fallenEmpireCruiser_localShip_get()
    local veh = GetPlayerVehicle()
    if not veh or veh == 0 then
        return false, 0, 0, nil, Vec(0, 0, 0)
    end

    local okTag, has = pcall(HasTag, veh, "ship")
    if (not okTag) or (not has) then
        return false, 0, 0, nil, Vec(0, 0, 0)
    end

    local okBody, body = pcall(GetVehicleBody, veh)
    if (not okBody) or (not body) or body == 0 then
        return false, 0, 0, nil, Vec(0, 0, 0)
    end

    local t = GetBodyTransform(body)
    local vel = GetBodyVelocity(body)
    return true, veh, body, t, vel
end

------------------------------------------------
-- fallenEmpireCruiser_localShip 模块 结束
------------------------------------------------

------------------------------------------------
-- fallenEmpireCruiser_shipWorld 模块 开始
------------------------------------------------

-- 纯客户端：缓存全场 tag=ship 的 vehicles，供音频等模块使用
local fallenEmpireCruiser_shipWorld_refreshInterval = 0.5
local fallenEmpireCruiser_shipWorld_time = 0
local fallenEmpireCruiser_shipWorld_nextRefreshTime = 0
local fallenEmpireCruiser_shipWorld_bodies = {}

local function fallenEmpireCruiser_shipWorld_refresh()
    local bodies = {}

    local okFind, found = pcall(FindBodies, "ship", true)
    if okFind and type(found) == "table" then
        bodies = found
    else
        -- 回退：只找一艘（即使场上多艘也不至于报错）
        local okOne, one = pcall(FindBody, "ship", true)
        if okOne and one and one ~= 0 then
            bodies = { one }
        end
    end

    fallenEmpireCruiser_shipWorld_bodies = bodies
end

function fallenEmpireCruiser_shipWorld_client_tick(dt)
    fallenEmpireCruiser_shipWorld_time = fallenEmpireCruiser_shipWorld_time + (dt or 0)
    if fallenEmpireCruiser_shipWorld_time >= fallenEmpireCruiser_shipWorld_nextRefreshTime then
        fallenEmpireCruiser_shipWorld_refresh()
        fallenEmpireCruiser_shipWorld_nextRefreshTime = fallenEmpireCruiser_shipWorld_time + fallenEmpireCruiser_shipWorld_refreshInterval
    end
end

local function fallenEmpireCruiser_shipWorld_getVehicles()
    -- 兼容旧调用点：返回 ship bodies
    return fallenEmpireCruiser_shipWorld_bodies or {}
end

------------------------------------------------
-- fallenEmpireCruiser_shipWorld 模块 结束
------------------------------------------------

------------------------------------------------
-- fallenEmpireCruiser_drivenShipBodies 模块 开始
------------------------------------------------

-- 纯客户端：找出“当前有人驾驶的 ship 飞船 body”，用于音频等
local fallenEmpireCruiser_drivenShipBodies_refreshInterval = 0.1
local fallenEmpireCruiser_drivenShipBodies_time = 0
local fallenEmpireCruiser_drivenShipBodies_nextRefreshTime = 0
local fallenEmpireCruiser_drivenShipBodies_bodies = {}

local function fallenEmpireCruiser_drivenShipBodies_refresh()
    local bodies = {}
    local seen = {}

    local players = GetAllPlayers() or {}
    for i = 1, #players do
        local p = players[i]
        if IsPlayerValid(p) then
            local okVeh, veh = pcall(GetPlayerVehicle, p)
            if okVeh and veh and veh ~= 0 then
                local okTag, has = pcall(HasTag, veh, "ship")
                if okTag and has then
                    local okBody, body = pcall(GetVehicleBody, veh)
                    if okBody and body and body ~= 0 and not seen[body] then
                        seen[body] = true
                        bodies[#bodies + 1] = body
                    end
                end
            end
        end
    end

    fallenEmpireCruiser_drivenShipBodies_bodies = bodies
end

function fallenEmpireCruiser_drivenShipBodies_client_tick(dt)
    fallenEmpireCruiser_drivenShipBodies_time = fallenEmpireCruiser_drivenShipBodies_time + (dt or 0)
    if fallenEmpireCruiser_drivenShipBodies_time >= fallenEmpireCruiser_drivenShipBodies_nextRefreshTime then
        fallenEmpireCruiser_drivenShipBodies_refresh()
        fallenEmpireCruiser_drivenShipBodies_nextRefreshTime = fallenEmpireCruiser_drivenShipBodies_time + fallenEmpireCruiser_drivenShipBodies_refreshInterval
    end
end

local function fallenEmpireCruiser_drivenShipBodies_get()
    return fallenEmpireCruiser_drivenShipBodies_bodies or {}
end

------------------------------------------------
-- fallenEmpireCruiser_drivenShipBodies 模块 结束
------------------------------------------------

------------------------------------------------
-- fallenEmpireCruiser_engineAudio 模块 开始
------------------------------------------------

local fallenEmpireCruiser_engineAudio_loop = 0
local fallenEmpireCruiser_engineAudio_volume = 10.0

local function fallenEmpireCruiser_engineAudio_init()
    fallenEmpireCruiser_engineAudio_loop = LoadLoop("MOD/audio/engine.ogg")
end

function fallenEmpireCruiser_engineAudio_client_tick(dt)
    if fallenEmpireCruiser_engineAudio_loop and fallenEmpireCruiser_engineAudio_loop ~= 0 then
        local bodies = fallenEmpireCruiser_drivenShipBodies_get()
        for i = 1, #bodies do
            local body = bodies[i]
            if body and body ~= 0 then
                local t = GetBodyTransform(body)
                PlayLoop(fallenEmpireCruiser_engineAudio_loop, t.pos, fallenEmpireCruiser_engineAudio_volume)
            end
        end
    end
end

------------------------------------------------
-- fallenEmpireCruiser_engineAudio 模块 结束
------------------------------------------------

------------------------------------------------
-- fallenEmpireCruiser_thrusterAudio 模块 开始
------------------------------------------------

local fallenEmpireCruiser_thrusterAudio_loop = 0

local fallenEmpireCruiser_thrusterAudio_speedForMaxVol = 30.0
local fallenEmpireCruiser_thrusterAudio_maxVol = 5.0

local function fallenEmpireCruiser_thrusterAudio_clamp(x, a, b)
    if x < a then return a end
    if x > b then return b end
    return x
end

local function fallenEmpireCruiser_thrusterAudio_init()
    fallenEmpireCruiser_thrusterAudio_loop = LoadLoop("MOD/audio/move.ogg")
end

function fallenEmpireCruiser_thrusterAudio_client_tick(dt)
    if fallenEmpireCruiser_thrusterAudio_loop and fallenEmpireCruiser_thrusterAudio_loop ~= 0 then
        local bodies = fallenEmpireCruiser_drivenShipBodies_get()
        for i = 1, #bodies do
            local body = bodies[i]
            if body and body ~= 0 then
                local t = GetBodyTransform(body)
                local vel = GetBodyVelocity(body)
                local speed = VecLength(vel or Vec(0, 0, 0))
                local k = fallenEmpireCruiser_thrusterAudio_clamp(speed / fallenEmpireCruiser_thrusterAudio_speedForMaxVol, 0.0, 1.0)
                local vol = k * fallenEmpireCruiser_thrusterAudio_maxVol
                PlayLoop(fallenEmpireCruiser_thrusterAudio_loop, t.pos, vol)
            end
        end
    end
end

------------------------------------------------
-- fallenEmpireCruiser_thrusterAudio 模块 结束
------------------------------------------------

------------------------------------------------
-- fallenEmpireCruiser_camera 模块 开始
------------------------------------------------

local fallenEmpireCruiser_camera_atFront = false

-- 前置相机位置（飞船本地坐标）
local fallenEmpireCruiser_camera_frontLocalOffset = Vec(0, 0, -4)

local fallenEmpireCruiser_camera_radiusBack = 18
local fallenEmpireCruiser_camera_radiusMin = 4
local fallenEmpireCruiser_camera_radiusMax = 40
local fallenEmpireCruiser_camera_zoomSpeed = 5

local fallenEmpireCruiser_camera_yaw = 0
local fallenEmpireCruiser_camera_pitch = -20
local fallenEmpireCruiser_camera_targetYaw = 0
local fallenEmpireCruiser_camera_targetPitch = -20

local fallenEmpireCruiser_camera_rotateSensitivity = 0.12
local fallenEmpireCruiser_camera_lerpSpeed = 6

-- 缓存上一帧的相机 Transform：避免在某些情况下 draw 阶段回落到游戏默认摄像机
local fallenEmpireCruiser_camera_lastActive = false
local fallenEmpireCruiser_camera_lastTransform = nil

-- 从 tick 缓存“当前驾驶的飞船 body”，供 draw 阶段每帧计算相机用
local fallenEmpireCruiser_camera_cachedIsDriving = false
local fallenEmpireCruiser_camera_cachedBody = 0
local fallenEmpireCruiser_camera_cachedDt = 0

local function fallenEmpireCruiser_camera_yawPitchFromDir(dir)
    dir = VecNormalize(dir)
    local yawRaw = math.deg(math.atan2(-dir[3], dir[1]))
    local yaw = fallenEmpireCruiser_camera_normalizeAngleDeg(yawRaw - 90.0)
    local horiz = math.sqrt(dir[1] * dir[1] + dir[3] * dir[3])
    local pitch = math.deg(math.atan2(dir[2], horiz))
    pitch = fallenEmpireCruiser_camera_clamp(pitch, -80, 80)
    return yaw, pitch
end

local function fallenEmpireCruiser_camera_dirFromYawPitch(yawDeg, pitchDeg)
    local yaw = math.rad(yawDeg)
    local pitch = math.rad(pitchDeg)
    local cp = math.cos(pitch)
    local sp = math.sin(pitch)
    -- yaw=0 面向 -Z
    return Vec(cp * math.sin(yaw), sp, -cp * math.cos(yaw))
end

-- 右键：短按切前/后视；长按（仅后视）自由观察
local fallenEmpireCruiser_camera_rmbDown = false
local fallenEmpireCruiser_camera_rmbHoldTime = 0
local fallenEmpireCruiser_camera_freeLookActive = false
local fallenEmpireCruiser_camera_longPressThreshold = 0.25

-- 切到前置相机后，下一帧用飞船朝向初始化相机 yaw/pitch（避免跳变）
local fallenEmpireCruiser_camera_pendingInitToShipForward = false

function fallenEmpireCruiser_camera_isLongPressActive()
    return fallenEmpireCruiser_camera_rmbDown and (fallenEmpireCruiser_camera_rmbHoldTime >= fallenEmpireCruiser_camera_longPressThreshold)
end

local function fallenEmpireCruiser_camera_clamp(x, a, b)
    if x < a then return a end
    if x > b then return b end
    return x
end

local function fallenEmpireCruiser_camera_normalizeAngleDeg(a)
    a = a % 360
    if a > 180 then a = a - 360 end
    if a < -180 then a = a + 360 end
    return a
end

local function fallenEmpireCruiser_camera_shortestAngleDiff(from, to)
    local d = fallenEmpireCruiser_camera_normalizeAngleDeg(to - from)
    return d
end

local function fallenEmpireCruiser_camera_handleRmb(dt)
    -- 按下立刻切换前/后视，并在切入时立即用飞船朝向初始化 yaw/pitch/targets
    if InputPressed("rmb") then
        fallenEmpireCruiser_camera_rmbDown = true
        fallenEmpireCruiser_camera_rmbHoldTime = 0

        if fallenEmpireCruiser_camera_atFront then
            -- 已在前视，按下就切回后视
            fallenEmpireCruiser_camera_atFront = false
            fallenEmpireCruiser_camera_freeLookActive = false
        else
            -- 立刻切到前视，并立即用当前飞船朝向初始化相机方向（避免帧跳变）
            fallenEmpireCruiser_camera_atFront = true
            fallenEmpireCruiser_camera_freeLookActive = false

            local body = fallenEmpireCruiser_camera_cachedBody
            if body and body ~= 0 then
                local shipT = GetBodyTransform(body)
                local shipForward = VecNormalize(TransformToParentVec(shipT, Vec(0, 0, -1)))
                local yaw, pitch = fallenEmpireCruiser_camera_yawPitchFromDir(shipForward)
                fallenEmpireCruiser_camera_yaw = yaw
                fallenEmpireCruiser_camera_pitch = pitch
                fallenEmpireCruiser_camera_targetYaw = yaw
                fallenEmpireCruiser_camera_targetPitch = pitch
            end
        end
    end

    -- 处理长按进入 free-look（保持你原有的长按语义）
    if fallenEmpireCruiser_camera_rmbDown then
        fallenEmpireCruiser_camera_rmbHoldTime = fallenEmpireCruiser_camera_rmbHoldTime + (dt or 0)
        if (not fallenEmpireCruiser_camera_atFront)
            and (fallenEmpireCruiser_camera_rmbHoldTime >= fallenEmpireCruiser_camera_longPressThreshold)
            and (not fallenEmpireCruiser_camera_freeLookActive) then
            fallenEmpireCruiser_camera_freeLookActive = true
        end
    end

    -- 释放时结束按下/长按状态
    if InputReleased("rmb") then
        fallenEmpireCruiser_camera_rmbDown = false
        fallenEmpireCruiser_camera_rmbHoldTime = 0
        if fallenEmpireCruiser_camera_freeLookActive then
            fallenEmpireCruiser_camera_freeLookActive = false
        end
    end
end

local function fallenEmpireCruiser_camera_update(isDriving, body, dt)
    if not isDriving or not body or body == 0 then
        fallenEmpireCruiser_camera_lastActive = false
        fallenEmpireCruiser_camera_lastTransform = nil
        return
    end

    local shipT = GetBodyTransform(body)

    fallenEmpireCruiser_camera_handleRmb(dt)

    local didInitToShipForward = false

    -- 切到前置相机的同一帧就初始化朝向，避免出现一帧跳变
    if fallenEmpireCruiser_camera_atFront and fallenEmpireCruiser_camera_pendingInitToShipForward then
        local shipForward = VecNormalize(TransformToParentVec(shipT, Vec(0, 0, -1)))
        local yaw, pitch = fallenEmpireCruiser_camera_yawPitchFromDir(shipForward)
        fallenEmpireCruiser_camera_yaw = -yaw
        fallenEmpireCruiser_camera_pitch = -pitch
        fallenEmpireCruiser_camera_targetYaw = -yaw
        fallenEmpireCruiser_camera_targetPitch = -pitch
        fallenEmpireCruiser_camera_pendingInitToShipForward = false
        didInitToShipForward = true
    end

    local mx = InputValue("mousedx") or 0
    local my = InputValue("mousedy") or 0
    local wheel = InputValue("mousewheel") or 0

    local camPos
    local camRot

    if fallenEmpireCruiser_camera_atFront then
        -- 前置相机：短按右键切入时，立即对齐“飞船朝向”；位置固定在飞船本地 (0,0,-4)
        camPos = TransformToParentPoint(shipT, fallenEmpireCruiser_camera_frontLocalOffset)
        local sens = fallenEmpireCruiser_camera_rotateSensitivity

        -- 切换到前置相机的这一帧：忽略鼠标微抖，确保“方向一定是飞船朝向方向”
        if not didInitToShipForward then
            -- 前置相机转动逻辑与后置一致
            fallenEmpireCruiser_camera_targetYaw = fallenEmpireCruiser_camera_normalizeAngleDeg(fallenEmpireCruiser_camera_targetYaw + mx * sens)
            fallenEmpireCruiser_camera_targetPitch = fallenEmpireCruiser_camera_clamp(fallenEmpireCruiser_camera_targetPitch - my * sens, -80, 80)
        end

        local k = math.min(1.0, fallenEmpireCruiser_camera_lerpSpeed * (dt or 0))
        local yawDelta = fallenEmpireCruiser_camera_shortestAngleDiff(fallenEmpireCruiser_camera_yaw, fallenEmpireCruiser_camera_targetYaw)
        fallenEmpireCruiser_camera_yaw = fallenEmpireCruiser_camera_normalizeAngleDeg(fallenEmpireCruiser_camera_yaw + yawDelta * k)
        fallenEmpireCruiser_camera_pitch = fallenEmpireCruiser_camera_pitch + (fallenEmpireCruiser_camera_targetPitch - fallenEmpireCruiser_camera_pitch) * k
        fallenEmpireCruiser_camera_pitch = fallenEmpireCruiser_camera_clamp(fallenEmpireCruiser_camera_pitch, -80, 80)

        local fwd = fallenEmpireCruiser_camera_dirFromYawPitch(fallenEmpireCruiser_camera_yaw, fallenEmpireCruiser_camera_pitch)
        local outTarget = VecAdd(camPos, fwd)
        camRot = QuatLookAt(camPos, outTarget)
    else
        if wheel ~= 0 then
            fallenEmpireCruiser_camera_radiusBack = fallenEmpireCruiser_camera_clamp(
                fallenEmpireCruiser_camera_radiusBack - wheel * fallenEmpireCruiser_camera_zoomSpeed,
                fallenEmpireCruiser_camera_radiusMin,
                fallenEmpireCruiser_camera_radiusMax
            )
        end

        -- 简化：后视相机的角度由鼠标直接控制（自由观察时更灵敏/不回正）
        local sens = fallenEmpireCruiser_camera_rotateSensitivity
        if fallenEmpireCruiser_camera_freeLookActive then
            sens = sens * 1.0
        end

        fallenEmpireCruiser_camera_targetYaw = fallenEmpireCruiser_camera_normalizeAngleDeg(fallenEmpireCruiser_camera_targetYaw - mx * sens)
        fallenEmpireCruiser_camera_targetPitch = fallenEmpireCruiser_camera_clamp(fallenEmpireCruiser_camera_targetPitch - my * sens, -80, 80)

        -- 轻微平滑（避免突然抖动）
        local k = math.min(1.0, fallenEmpireCruiser_camera_lerpSpeed * (dt or 0))
        local yawDelta = fallenEmpireCruiser_camera_shortestAngleDiff(fallenEmpireCruiser_camera_yaw, fallenEmpireCruiser_camera_targetYaw)
        fallenEmpireCruiser_camera_yaw = fallenEmpireCruiser_camera_normalizeAngleDeg(fallenEmpireCruiser_camera_yaw + yawDelta * k)
        fallenEmpireCruiser_camera_pitch = fallenEmpireCruiser_camera_pitch + (fallenEmpireCruiser_camera_targetPitch - fallenEmpireCruiser_camera_pitch) * k
        fallenEmpireCruiser_camera_pitch = fallenEmpireCruiser_camera_clamp(fallenEmpireCruiser_camera_pitch, -80, 80)

        local baseOffset = Vec(0, 0, fallenEmpireCruiser_camera_radiusBack)
        local orbitRot = QuatEuler(fallenEmpireCruiser_camera_pitch, fallenEmpireCruiser_camera_yaw, 0)
        local offsetWorld = QuatRotateVec(orbitRot, baseOffset)
        camPos = VecAdd(shipT.pos, offsetWorld)
        camRot = QuatLookAt(camPos, shipT.pos)
    end

    AttachCameraTo(0)
    local camT = Transform(camPos, camRot)
    fallenEmpireCruiser_camera_lastActive = true
    fallenEmpireCruiser_camera_lastTransform = camT
    SetCameraTransform(camT)
end

function fallenEmpireCruiser_camera_client_tick(dt)
    local isDriving, _, body = fallenEmpireCruiser_localShip_get()

    fallenEmpireCruiser_camera_cachedIsDriving = isDriving
    fallenEmpireCruiser_camera_cachedBody = body or 0
    fallenEmpireCruiser_camera_cachedDt = dt or 0

    -- tick 阶段设置一次相机：Teardown 的主视角通常以 tick 为准
    fallenEmpireCruiser_camera_update(isDriving, body, dt)
end

function fallenEmpireCruiser_camera_client_draw()
    -- draw 阶段再补一次：防止引擎/其他 UI 绘制阶段覆写相机
    if not fallenEmpireCruiser_camera_lastActive then
        return
    end
    if not fallenEmpireCruiser_camera_lastTransform then
        return
    end
    AttachCameraTo(0)
    SetCameraTransform(fallenEmpireCruiser_camera_lastTransform)
end

------------------------------------------------
-- fallenEmpireCruiser_camera 模块 结束
------------------------------------------------

------------------------------------------------
-- fallenEmpireCruiser_attitudeControl 模块 开始
------------------------------------------------

-- 客户端：不在长按右键时，上报当前摄像机朝向（前/后相机都适用）
-- 服务端：根据上报的朝向，平滑转向并自动回正（参考 test4.lua 的实现风格）

local fallenEmpireCruiser_attitudeControl_clientTime = 0
local fallenEmpireCruiser_attitudeControl_clientLastSendTime = -999
local fallenEmpireCruiser_attitudeControl_clientSendInterval = 0.05

local fallenEmpireCruiser_attitudeControl_inputTimeout = 0.25

local fallenEmpireCruiser_attitudeControl_maxPitch = 80
local fallenEmpireCruiser_attitudeControl_maxYawOffset = 120

local fallenEmpireCruiser_attitudeControl_kP_yaw = 2.0
local fallenEmpireCruiser_attitudeControl_kP_pitch = 2.0
local fallenEmpireCruiser_attitudeControl_maxYawSpeed = 90.0
local fallenEmpireCruiser_attitudeControl_maxPitchSpeed = 60.0

-- 服务端状态（vehicleId -> st）
-- st = { driverId=number, body=handle, t=number, aimYaw=number, aimPitch=number }
local fallenEmpireCruiser_attitudeControl_serverVehicleStates = {}

local function fallenEmpireCruiser_attitudeControl_clamp(v, a, b)
    if v < a then return a end
    if v > b then return b end
    return v
end

local function fallenEmpireCruiser_attitudeControl_normalizeAngleDeg(a)
    return (a + 180) % 360 - 180
end

local function fallenEmpireCruiser_attitudeControl_shortestAngleDiff(a, b)
    local d = (b - a + 180) % 360 - 180
    return d
end

local function fallenEmpireCruiser_attitudeControl_getShipYaw(t)
    local forward = TransformToParentVec(t, Vec(0, 0, -1))
    forward = VecNormalize(forward)
    local yawRaw = math.deg(math.atan2(-forward[3], forward[1]))
    return fallenEmpireCruiser_attitudeControl_normalizeAngleDeg(yawRaw - 90.0)
end

local function fallenEmpireCruiser_attitudeControl_getShipPitch(t)
    local forward = TransformToParentVec(t, Vec(0, 0, -1))
    forward = VecNormalize(forward)
    local horiz = math.sqrt(forward[1] * forward[1] + forward[3] * forward[3])
    local pitch = math.deg(math.atan2(forward[2], horiz))
    return pitch
end

local function fallenEmpireCruiser_attitudeControl_dirToYawPitch(dir)
    dir = VecNormalize(dir)
    local yawRaw = math.deg(math.atan2(-dir[3], dir[1]))
    local yaw = fallenEmpireCruiser_attitudeControl_normalizeAngleDeg(yawRaw - 90.0)
    local horiz = math.sqrt(dir[1] * dir[1] + dir[3] * dir[3])
    local pitch = math.deg(math.atan2(dir[2], horiz))
    pitch = fallenEmpireCruiser_attitudeControl_clamp(pitch, -fallenEmpireCruiser_attitudeControl_maxPitch, fallenEmpireCruiser_attitudeControl_maxPitch)
    return yaw, pitch
end

function fallenEmpireCruiser_attitudeControl_client_tick(dt)
    fallenEmpireCruiser_attitudeControl_clientTime = fallenEmpireCruiser_attitudeControl_clientTime + (dt or 0)

    if localPlayerId == -1 then
        return
    end

    local myVeh = GetPlayerVehicle()
    local okTag, has = pcall(HasTag, myVeh, "ship")
    if (not okTag) or (not has) then
        return
    end

    -- 长按右键：自由观察，不上报
    if fallenEmpireCruiser_camera_isLongPressActive() then
        return
    end

    local due = (fallenEmpireCruiser_attitudeControl_clientTime - fallenEmpireCruiser_attitudeControl_clientLastSendTime) >= fallenEmpireCruiser_attitudeControl_clientSendInterval
    if not due then
        return
    end

    local camT = GetCameraTransform()
    local camForward = TransformToParentVec(camT, Vec(0, 0, -1))
    camForward = VecNormalize(camForward)

    ServerCall(
        "fallenEmpireCruiser_attitudeControl_ReportCameraDir",
        localPlayerId,
        camForward[1],
        camForward[2],
        camForward[3]
    )

    fallenEmpireCruiser_attitudeControl_clientLastSendTime = fallenEmpireCruiser_attitudeControl_clientTime
end

-- RPC: client -> server
function fallenEmpireCruiser_attitudeControl_ReportCameraDir(playerId, dx, dy, dz)
    if not IsPlayerValid(playerId) then
        return
    end

    local okVeh, veh = pcall(GetPlayerVehicle, playerId)
    if (not okVeh) or (not veh) or veh == 0 then
        return
    end
    local okTag, has = pcall(HasTag, veh, "ship")
    if (not okTag) or (not has) then
        return
    end

    -- 单驾驶者锁（跨模块共享）
    if not fallenEmpireCruiser_driverLock_tryAcquire(veh, playerId) then
        return
    end

    local dir = Vec(dx or 0, dy or 0, dz or 0)
    if VecLength(dir) < 0.0001 then
        return
    end

    local st = fallenEmpireCruiser_attitudeControl_serverVehicleStates[veh]
    if not st then
        st = { driverId = playerId, body = 0, t = -999, aimYaw = 0, aimPitch = 0 }
        fallenEmpireCruiser_attitudeControl_serverVehicleStates[veh] = st
    end

    local okBody, body = pcall(GetVehicleBody, veh)
    if (not okBody) or (not body) or body == 0 then
        return
    end

    st.driverId = playerId
    st.body = body
    st.t = serverTime

    local shipT = GetBodyTransform(body)
    local aimYaw, aimPitch = fallenEmpireCruiser_attitudeControl_dirToYawPitch(dir)

    -- 限制相对偏航，避免绕到背后导致翻转
    local currentYaw = fallenEmpireCruiser_attitudeControl_getShipYaw(shipT)
    local yawDiff = fallenEmpireCruiser_attitudeControl_shortestAngleDiff(currentYaw, aimYaw)
    yawDiff = fallenEmpireCruiser_attitudeControl_clamp(yawDiff, -fallenEmpireCruiser_attitudeControl_maxYawOffset, fallenEmpireCruiser_attitudeControl_maxYawOffset)
    st.aimYaw = fallenEmpireCruiser_attitudeControl_normalizeAngleDeg(currentYaw + yawDiff)
    st.aimPitch = aimPitch
end

local function fallenEmpireCruiser_attitudeControl_server_applyRotation(dt)
    for veh, st in pairs(fallenEmpireCruiser_attitudeControl_serverVehicleStates) do
        if not veh or veh == 0 or (not st) then
            fallenEmpireCruiser_attitudeControl_serverVehicleStates[veh] = nil
        else
            if not st.driverId or not IsPlayerValid(st.driverId) then
                fallenEmpireCruiser_attitudeControl_serverVehicleStates[veh] = nil
            else
                local okVeh, curVeh = pcall(GetPlayerVehicle, st.driverId)
                if (not okVeh) or curVeh ~= veh then
                    fallenEmpireCruiser_attitudeControl_serverVehicleStates[veh] = nil
                elseif (serverTime - (st.t or -999)) > fallenEmpireCruiser_attitudeControl_inputTimeout then
                    -- 超时：不再继续转向
                else
                    local body = st.body
                    if not body or body == 0 then
                        local okBody, b = pcall(GetVehicleBody, veh)
                        if okBody then body = b end
                        st.body = body
                    end
                    if body and body ~= 0 then
                        local t = GetBodyTransform(body)

                        -- 根据当前朝向与目标朝向误差设置角速度（Yaw+Pitch）
                        local currentYaw = fallenEmpireCruiser_attitudeControl_getShipYaw(t)
                        local currentPitch = fallenEmpireCruiser_attitudeControl_getShipPitch(t)
                        local yawError = fallenEmpireCruiser_attitudeControl_shortestAngleDiff(currentYaw, st.aimYaw or 0)
                        local pitchError = fallenEmpireCruiser_attitudeControl_clamp((st.aimPitch or 0) - currentPitch, -fallenEmpireCruiser_attitudeControl_maxPitch, fallenEmpireCruiser_attitudeControl_maxPitch)

                        local yawSpeedDeg = fallenEmpireCruiser_attitudeControl_clamp(yawError * fallenEmpireCruiser_attitudeControl_kP_yaw, -fallenEmpireCruiser_attitudeControl_maxYawSpeed, fallenEmpireCruiser_attitudeControl_maxYawSpeed)
                        local pitchSpeedDeg = fallenEmpireCruiser_attitudeControl_clamp(pitchError * fallenEmpireCruiser_attitudeControl_kP_pitch, -fallenEmpireCruiser_attitudeControl_maxPitchSpeed, fallenEmpireCruiser_attitudeControl_maxPitchSpeed)

                        local yawSpeedRad = yawSpeedDeg * math.pi / 180.0
                        local pitchSpeedRad = pitchSpeedDeg * math.pi / 180.0

                        local localAngVel = Vec(pitchSpeedRad, yawSpeedRad, 0)
                        local worldAngVel = TransformToParentVec(t, localAngVel)
                        SetBodyAngularVelocity(body, worldAngVel)
                    end
                end
            end
        end
    end
end

local function fallenEmpireCruiser_attitudeControl_server_tick(dt)
    fallenEmpireCruiser_attitudeControl_server_applyRotation(dt or 0)
end

------------------------------------------------
-- fallenEmpireCruiser_attitudeControl 模块 结束
------------------------------------------------

------------------------------------------------
-- fallenEmpireCruiser_stabilizeShipRoll 模块 开始
------------------------------------------------

-- PD 参数（可调）
local fallenEmpireCruiser_stabilizeShipRoll_kP = 35.0
local fallenEmpireCruiser_stabilizeShipRoll_kD = 6.0

-- “施加转向力”的力臂长度（世界单位）：越大越容易回正，但也更“硬”
local fallenEmpireCruiser_stabilizeShipRoll_arm = 3.5

-- 最大扭矩（单位是“近似扭矩”，最终会换算成冲量对）；防止过冲
local fallenEmpireCruiser_stabilizeShipRoll_maxTorque = 6000.0

-- 死区：误差很小时不处理，避免抖动
local fallenEmpireCruiser_stabilizeShipRoll_deadZoneRad = 0.002


-- fallenEmpireCruiser_stabilizeShipRoll_clamp 描述：夹取
local function fallenEmpireCruiser_stabilizeShipRoll_clamp (x, a, b)
    if x < a then return a end
    if x > b then return b end
    return x
end

-- fallenEmpireCruiser_stabilizeShipRoll_projOnPlane 描述：将 v 投影到“法向为 n 的平面”上
local function fallenEmpireCruiser_stabilizeShipRoll_projOnPlane (v, n)
    return VecSub(v, VecScale(n, VecDot(v, n)))
end

-- fallenEmpireCruiser_stabilizeShipRoll_apply 描述：对单个飞船 body 施加 roll 回正（PD 控制，使用冲量对产生扭矩）
local function fallenEmpireCruiser_stabilizeShipRoll_apply (body, dt)
    if not body or body == 0 then
        return
    end

    dt = dt or 0
    if dt <= 0 then
        return
    end

    local t = GetBodyTransform(body)
    local forwardNow = VecNormalize(TransformToParentVec(t, Vec(0, 0, -1)))
    local upNow = VecNormalize(TransformToParentVec(t, Vec(0, 1, 0)))
    local rightNow = VecNormalize(TransformToParentVec(t, Vec(1, 0, 0)))

    -- 目标：让飞船 up 尽量对齐世界上方，但只修正“绕 forward 的滚转”
    local worldUp = Vec(0, 1, 0)

    local upPlanar = fallenEmpireCruiser_stabilizeShipRoll_projOnPlane(upNow, forwardNow)
    local worldUpPlanar = fallenEmpireCruiser_stabilizeShipRoll_projOnPlane(worldUp, forwardNow)
    local upLen = VecLength(upPlanar)
    local wLen = VecLength(worldUpPlanar)
    if upLen < 0.0001 or wLen < 0.0001 then
        return
    end
    upPlanar = VecScale(upPlanar, 1 / upLen)
    worldUpPlanar = VecScale(worldUpPlanar, 1 / wLen)

    -- 计算绕 forward 的有符号 roll 误差（弧度）
    local sinPhi = VecDot(forwardNow, VecCross(upPlanar, worldUpPlanar))
    local cosPhi = fallenEmpireCruiser_stabilizeShipRoll_clamp(VecDot(upPlanar, worldUpPlanar), -1.0, 1.0)
    local rollError = math.atan2(sinPhi, cosPhi)

    if math.abs(rollError) < fallenEmpireCruiser_stabilizeShipRoll_deadZoneRad then
        return
    end

    local angVel = GetBodyAngularVelocity(body)
    local rollRate = VecDot(angVel, forwardNow)

    -- PD：扭矩指令（正负代表绕 forward 的方向）
    local torqueCmd = (-rollError * fallenEmpireCruiser_stabilizeShipRoll_kP) - (rollRate * fallenEmpireCruiser_stabilizeShipRoll_kD)
    torqueCmd = fallenEmpireCruiser_stabilizeShipRoll_clamp(torqueCmd, -fallenEmpireCruiser_stabilizeShipRoll_maxTorque, fallenEmpireCruiser_stabilizeShipRoll_maxTorque)

    local arm = math.max(0.1, fallenEmpireCruiser_stabilizeShipRoll_arm)
    local force = torqueCmd / (2.0 * arm)
    local impulseMag = force * dt

    -- 质心世界坐标
    local comLocal = GetBodyCenterOfMass(body)
    local comWorld = TransformToParentPoint(t, comLocal)

    -- 在质心左右施加一对反向冲量：产生绕 forward 的扭矩，净力为 0
    local p1 = VecAdd(comWorld, VecScale(rightNow, arm))
    local p2 = VecSub(comWorld, VecScale(rightNow, arm))

    local impulse = VecScale(upNow, impulseMag)
    ApplyBodyImpulse(body, p1, impulse)
    ApplyBodyImpulse(body, p2, VecScale(impulse, -1))
end

-- fallenEmpireCruiser_stabilizeShipRoll_server_tick 描述：服务端 tick（对飞船施加 roll 回正）
local function fallenEmpireCruiser_stabilizeShipRoll_server_tick (dt)
    if shipBody and shipBody ~= 0 then
        fallenEmpireCruiser_stabilizeShipRoll_apply(shipBody, dt)
        return
    end

    local okFind, bodies = pcall(FindBodies, "ship", true)
    if okFind and type(bodies) == "table" then
        for i = 1, #bodies do
            fallenEmpireCruiser_stabilizeShipRoll_apply(bodies[i], dt)
        end
    end
end

------------------------------------------------
-- fallenEmpireCruiser_stabilizeShipRoll 模块 结束
------------------------------------------------

------------------------------------------------
-- fallenEmpireCruiser_crosshair 模块 开始
------------------------------------------------

local fallenEmpireCruiser_crosshair_distance = 200
local fallenEmpireCruiser_crosshair_size = 8

function fallenEmpireCruiser_crosshair_client_draw()
    local isDriving, _, body = fallenEmpireCruiser_localShip_get()
    if not isDriving or not body or body == 0 then
        return
    end

    local t = GetBodyTransform(body)

    -- 准星逻辑（按 test4.lua 原版）：始终沿飞船本体正前方（本地 -Z）投射
    local forwardLocal = Vec(0, 0, -1)
    local rayOrigin = TransformToParentPoint(t, VecScale(forwardLocal, 2))
    local forwardWorldDir = TransformToParentVec(t, forwardLocal)
    forwardWorldDir = VecNormalize(forwardWorldDir)

    local hit, hitDist = QueryRaycast(rayOrigin, forwardWorldDir, fallenEmpireCruiser_crosshair_distance)
    local forwardWorldPoint
    if hit then
        forwardWorldPoint = VecAdd(rayOrigin, VecScale(forwardWorldDir, hitDist))
    else
        forwardWorldPoint = TransformToParentPoint(t, VecScale(forwardLocal, fallenEmpireCruiser_crosshair_distance))
    end

    -- 只在“摄像机前方”时才画十字，避免在身后也出现
    local camT = GetCameraTransform()
    local camForward = TransformToParentVec(camT, Vec(0, 0, -1))
    camForward = VecNormalize(camForward)
    local dirToPoint = VecNormalize(VecSub(forwardWorldPoint, camT.pos))
    local dot = VecDot(camForward, dirToPoint)
    if dot <= 0 then
        return
    end

    local sx, sy = UiWorldToPixel(forwardWorldPoint)
    if not sx or not sy then
        return
    end

    UiPush()
        UiAlign("center middle")
        UiTranslate(sx, sy)
        UiColor(1, 1, 1, 1)
        local s = fallenEmpireCruiser_crosshair_size
        local th = 1
        UiRect(s * 2, th)
        UiRect(th, s * 2)
    UiPop()
end

------------------------------------------------
-- fallenEmpireCruiser_crosshair 模块 结束
------------------------------------------------

------------------------------------------------
-- 初始化
------------------------------------------------

function server.init()
    shipVeh  = FindVehicle("ship", false)
    shipBody = GetVehicleBody(shipVeh)

    -- 按飞船 XML 引入所有 shape（vox 节点 tags）
    laserShape = FindShape("primaryWeaponLauncher", false)
    missileLauncherShapes = FindShapes("missileLauncher", false) or {}
    hullShape = FindShape("hull", false)
    thrusterShapes = FindShapes("thruster", false) or {}
    engineShapes = FindShapes("engine", false) or {}
    smallThrusterShapes = FindShapes("smallThruster", false) or {}
    secondaryLightSystemShape = FindShape("secondaryLightSystem", false)
    mainLightSystemShape = FindShape("mainLightSystem", false)
    armorShape = FindShape("armor", false)

    if shipVeh == 0 then
        DebugPrint("[test6] FindVehicle('ship') 失败：请确认 vehicle 上有 tag=ship")
    end
    serverTime = 0

    -- xSlot 模块初始化
    xSlot_server_init()

    -- MSlot 模块初始化
    MSlot_server_init()

    -- fallenEmpireCruiser_move 模块初始化
    fallenEmpireCruiser_move_serverVehicleStates = {}

    -- fallenEmpireCruiser_driverLock / attitudeControl 模块初始化
    fallenEmpireCruiser_driverLock_byVehicle = {}
    fallenEmpireCruiser_attitudeControl_serverVehicleStates = {}
end

function client.init()
    shipVeh  = FindVehicle("ship", false)
    shipBody = GetVehicleBody(shipVeh)

    -- 按飞船 XML 引入所有 shape（vox 节点 tags）
    laserShape = FindShape("primaryWeaponLauncher", false)
    missileLauncherShapes = FindShapes("missileLauncher", false) or {}
    hullShape = FindShape("hull", false)
    thrusterShapes = FindShapes("thruster", false) or {}
    engineShapes = FindShapes("engine", false) or {}
    smallThrusterShapes = FindShapes("smallThruster", false) or {}
    secondaryLightSystemShape = FindShape("secondaryLightSystem", false)
    mainLightSystemShape = FindShape("mainLightSystem", false)
    armorShape = FindShape("armor", false)

    if shipVeh == 0 then
        DebugPrint("[test6] FindVehicle('ship') 失败：请确认 vehicle 上有 tag=ship")
    end
    if not laserShape or laserShape == 0 then
        DebugPrint("[test6] FindShape('primaryWeaponLauncher') 未找到：将回退为飞船朝向发射")
    end

    -- 识别本地玩家 id（不依赖可能不存在的 GetPlayerId API）
    localPlayerId = -1
    local players = GetAllPlayers()
    for i = 1, #players do
        local p = players[i]
        if IsPlayerValid(p) and IsPlayerLocal(p) then
            localPlayerId = p
            break
        end
    end

    -- fallenEmpireCruiser_move 模块初始化
    fallenEmpireCruiser_move_clientTime = 0
    fallenEmpireCruiser_move_clientLastSendTime = -999
    fallenEmpireCruiser_move_clientLastW = false
    fallenEmpireCruiser_move_clientLastS = false
    fallenEmpireCruiser_move_clientLastInShip = false

    -- fallenEmpireCruiser_engineDraw 模块初始化
    fallenEmpireCruiser_engineDraw_time = 0
    fallenEmpireCruiser_engineDraw_nextRefreshTime = 0
    fallenEmpireCruiser_engineDraw_spawnAccum = 0
    fallenEmpireCruiser_engineDraw_shapes = {}

    -- fallenEmpireCruiser_shipWorld 模块初始化
    fallenEmpireCruiser_shipWorld_time = 0
    fallenEmpireCruiser_shipWorld_nextRefreshTime = 0
    fallenEmpireCruiser_shipWorld_bodies = {}

    -- fallenEmpireCruiser_attitudeControl 模块初始化
    fallenEmpireCruiser_attitudeControl_clientTime = 0
    fallenEmpireCruiser_attitudeControl_clientLastSendTime = -999

    -- fallenEmpireCruiser_drivenShipBodies 模块初始化
    fallenEmpireCruiser_drivenShipBodies_time = 0
    fallenEmpireCruiser_drivenShipBodies_nextRefreshTime = 0
    fallenEmpireCruiser_drivenShipBodies_bodies = {}

    -- fallenEmpireCruiser_engineAudio / thrusterAudio 模块初始化
    fallenEmpireCruiser_engineAudio_init()
    fallenEmpireCruiser_thrusterAudio_init()

    -- xSlot 模块初始化
    xSlot_client_init()

    -- MSlot 模块初始化
    MSlot_client_init()
end

------------------------------------------------
-- 生命周期入口
------------------------------------------------

-- 客户端 tick：只调用总控函数
function client.tick(dt)
    client_tick_main(dt)
end

function client.draw()
    fallenEmpireCruiser_camera_client_draw()
    fallenEmpireCruiser_crosshair_client_draw()
end

local function server_tick_main(dt)
    serverTime = serverTime + (dt or 0)
    xSlot_server_tick(dt or 0)
    MSlot_server_tick(dt or 0)
    antiG_server_apply(shipBody, dt)
    pV2Damping_server_apply(shipBody, dt)
    fallenEmpireCruiser_move_server_tick(dt or 0)
    fallenEmpireCruiser_attitudeControl_server_tick(dt or 0)
    fallenEmpireCruiser_stabilizeShipRoll_server_tick(dt or 0)
    DebugWatch("serverTime", serverTime)
    DebugWatch("server_useClientCallZeroBroadcast", server_useClientCallZeroBroadcast)
end

function server.tick(dt)
    server_tick_main(dt)
end