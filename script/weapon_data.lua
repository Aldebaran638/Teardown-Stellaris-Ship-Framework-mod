-- 统一武器数据表
-- 将多个武器的参数放在一起，便于维护与扩展
weaponData = weaponData or {}

-- 快子光矛武器数据
weaponData.tachyonLance = {
    weaponType = "tachyonLance", -- 武器类型标识，用于客户端渲染选择特效
    maxRange = 2000, -- 武器最大射程
    damageMin = 780, -- 武器最小伤害
    damageMax = 1950, -- 武器最大伤害
    shieldFix = 0.5, -- 护盾伤害修正
    armorFix = 2, -- 装甲伤害修正
    bodyFix = 1.5, -- 机体伤害修正
    CD = 1.5, -- 冷却时间
}

-- 可以在此处继续添加更多武器配置，例如：
-- weaponData.plasmaCannon = { ... }
