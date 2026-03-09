-- 命中点爆炸性粒子特效模块
-- 格式：全局变量、特效 tick 函数（每帧调用）、开始函数
-- 外部调用：client.hitPointFxStart(isHit, endPos, normal)

---@diagnostic disable: undefined-global

client = client or {}

client.hitPointFx = client.hitPointFx or {
    nextId = 1,
    items = {
        -- [id] = { startTime=number, played=false, isHit=bool, pos=Vec, normal=Vec }
    }
}

local function _safeNormalize(v, fallback)
    local l = VecLength(v)
    if l < 0.0001 then
        return fallback
    end
    return VecScale(v, 1.0 / l)
end

local function _buildPerpBasis(n)
    local upWorld = Vec(0, 1, 0)
    local t1 = VecCross(upWorld, n)
    t1 = _safeNormalize(t1, Vec(1, 0, 0))
    local t2 = VecCross(n, t1)
    t2 = _safeNormalize(t2, Vec(0, 1, 0))
    return t1, t2
end

-- 每帧调用以更新/播放特效
function client.hitPointFxTick(now)
    now = now or GetTime()
    local removeIds = {}
    for id, it in pairs(client.hitPointFx.items) do
        local age = now - (it.startTime or now)
        if not it.played then
            -- 立即播放爆炸性粒子（一次性）
            local pos = it.pos
            local n = it.normal
            if n == nil then n = Vec(0,1,0) end
            n = _safeNormalize(n, Vec(0,1,0))
            local t1, t2 = _buildPerpBasis(n)

            -- 点光
            PointLight(pos, 1.0, 0.8, 0.6, 3.0)

            -- 冲击波粒子（多圈）
            ParticleReset()
            ParticleColor(0.20, 0.95, 1.00, 0.10, 0.35, 1.00)
            ParticleRadius(0.13, 0.03, "easeout")
            ParticleAlpha(0.85, 0.0)
            ParticleGravity(0.0)
            ParticleDrag(0.18)
            ParticleEmissive(18.0, 0.0)
            ParticleCollide(0.0)
            for ring = 1, 4 do
                local baseCount = 20 + ring * 6
                local count = baseCount + math.random(-4, 4)
                local radius = 0.15 * ring + 0.10 * math.random()
                local speedFactor = 5.0 + ring * 2.0
                for i = 1, count do
                    local a = ((i - 1) / count) * math.pi * 2.0
                    local lateral = VecAdd(VecScale(t1, math.cos(a)), VecScale(t2, math.sin(a)))
                    local p = VecAdd(pos, VecScale(lateral, radius))
                    local vel = VecAdd(VecScale(lateral, speedFactor + 2.0 * math.random()), VecScale(n, 1.5 * math.random()))
                    SpawnParticle(p, vel, 0.16 + 0.12 * math.random())
                end
            end

            -- 飞溅粒子（周围随机喷射）
            ParticleReset()
            ParticleColor(0.95, 1.0, 1.0, 0.25, 0.95, 1.0)
            ParticleRadius(0.09, 0.02, "easeout")
            ParticleAlpha(0.9, 0.0)
            ParticleGravity(0.0)
            ParticleDrag(0.15)
            ParticleEmissive(16.0, 0.0)
            ParticleCollide(0.0)
            local splashCount = 24
            for i = 1, splashCount do
                local randDir = VecAdd(VecScale(n, 1.0), VecScale(t1, (math.random() - 0.5) * 1.6), VecScale(t2, (math.random() - 0.5) * 1.6))
                local randLen = VecLength(randDir)
                if randLen < 0.001 then randLen = 1.0 end
                local dir = VecScale(randDir, 1.0 / randLen)
                local vel = VecScale(dir, 12.0 + 8.0 * math.random())
                SpawnParticle(pos, vel, 0.16 + 0.10 * math.random())
            end

            it.played = true
        end

        -- 移除已播放且超过短时生命期的条目
        if age > 0.5 then
            table.insert(removeIds, id)
        end
    end

    for _, id in ipairs(removeIds) do
        client.hitPointFx.items[id] = nil
    end
end

-- 开始一个命中点特效
function client.hitPointFxStart(isHit, endPos, normal)
    if endPos == nil or endPos == false then return end
    local id = client.hitPointFx.nextId or 1
    client.hitPointFx.nextId = id + 1
    client.hitPointFx.items[id] = {
        startTime = GetTime(),
        played = false,
        isHit = isHit,
        pos = endPos,
        normal = normal,
    }
end

return client.hitPointFx
