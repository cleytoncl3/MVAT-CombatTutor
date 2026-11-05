--[[
    MVAT - Tutor de Combate (WoW Classic / Classic Era / Forever)
    ------------------------------------------------------------------
    Assistente 100% INFORMATIVO e VISUAL. Nao executa nenhuma acao,
    nao lanca feiticos, nao clica e nao altera barras de acao.

    Estrutura do arquivo:
      1. Configuracao / SavedVariables
      2. Camada de compatibilidade de API (Classic antigo x C_Spell novo)
      3. Livro de feiticos (somente o que ja foi aprendido)
      4. Leitura de atalhos (keybinds) independente do addon de barras
      5. Coleta de contexto de combate (auras, casts, grupo, inimigos)
      6. Construtores de regras (interrupt, dispel, buff, cura...)
      7. Tabelas de regras por classe
      8. Motor de decisao
      9. HUD flutuante (ancora propria, compativel com ElvUI)
     10. Eventos e comandos de chat (/mvat e /tutor)
]]

local ADDON_NAME = ...

---------------------------------------------------------------------------
-- 1. CONFIGURACAO
---------------------------------------------------------------------------
local DEFAULTS = {
    point = "CENTER", relPoint = "CENTER", x = 0, y = -180,
    scale = 1.0,
    locked = true,
    enabled = true,
    combatOnly = false,  -- true = so mostra em combate
    aoe = 3,             -- n. de inimigos para considerar "area / farm"
    showText = true,     -- mostra o motivo da sugestao abaixo do icone
}

local DB -- preenchido no ADDON_LOADED

local UPDATE_INTERVAL = 0.10   -- avaliacao 10x por segundo (leve)
local GROUP_SCAN_INTERVAL = 0.25

---------------------------------------------------------------------------
-- 2. COMPATIBILIDADE DE API
---------------------------------------------------------------------------
local C_Spell = C_Spell
local GetTime = GetTime

-- VALORES SECRETOS (WoW Forever / motor moderno): em combate a API pode devolver
-- valores "secretos". Comparar, somar ou testar um deles gera erro de Lua, entao
-- TODA leitura passa por Pub/Is: valor secreto vira nil/false ("desconhecido") e
-- a regra que dependia dele simplesmente nao dispara.
local issecret = type(issecretvalue) == "function" and issecretvalue or function() return false end
local function Pub(v) if issecret(v) then return nil end return v end
local function Is(v) if issecret(v) then return false end return v and true or false end
local function PubAll(...)
    for i = 1, select("#", ...) do if issecret((select(i, ...))) then return end end
    return ...
end

local function UnitExists(u) return Is(_G.UnitExists(u)) end
local function UnitIsDeadOrGhost(u) return Is(_G.UnitIsDeadOrGhost(u)) end
local function UnitIsUnit(a, b) return Is(_G.UnitIsUnit(a, b)) end
local function UnitCanAttack(a, b) return Is(_G.UnitCanAttack(a, b)) end
local function UnitIsDead(u) return Is(_G.UnitIsDead(u)) end
local function UnitAffectingCombat(u) return Is(_G.UnitAffectingCombat(u)) end

-- Retorna nome localizado e icone a partir do Spell ID (funciona em ptBR e enUS)
local function SpellInfo(id)
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(id)
        if info then return Pub(info.name), Pub(info.iconID) end
        return nil
    end
    local name, _, icon = GetSpellInfo(id)
    return Pub(name), Pub(icon)
end

-- Recarga desconhecida (secreta) e tratada como pronta: o jogo ainda impede o
-- uso, e o addon prefere sugerir a ficar mudo.
local function SpellCooldown(spell)
    if C_Spell and C_Spell.GetSpellCooldown then
        local cd = C_Spell.GetSpellCooldown(spell)
        if cd then return Pub(cd.startTime) or 0, Pub(cd.duration) or 0 end
        return 0, 0
    end
    local start, duration = GetSpellCooldown(spell)
    return Pub(start) or 0, Pub(duration) or 0
end

-- true = usavel, false = nao, nil = desconhecido
local function SpellUsable(spell)
    local usable
    if C_Spell and C_Spell.IsSpellUsable then usable = C_Spell.IsSpellUsable(spell)
    else usable = IsUsableSpell(spell) end
    if issecret(usable) then return nil end
    return usable and true or false
end

-- true = no alcance, false = fora de alcance, nil = sem alcance ou desconhecido
local function SpellInRange(spell, unit)
    local r
    if C_Spell and C_Spell.IsSpellInRange then r = C_Spell.IsSpellInRange(spell, unit)
    else r = IsSpellInRange(spell, unit) end
    if r == nil or issecret(r) then return nil end
    return r == true or r == 1
end

-- No Forever a leitura de auras por indice nao devolve um valor secreto: ela
-- GERA ERRO ("Auras cannot be accessed when secret"). Antes de varrer auras,
-- testamos com pcall (mesma tecnica do EllesmereUI). Resultado cacheado por frame.
local restrictedStamp, restrictedValue = -1, false
local function AurasRestricted()
    local now = GetTime()
    if now == restrictedStamp then return restrictedValue end
    restrictedStamp = now
    restrictedValue = false
    if C_Secrets and C_Secrets.ShouldAurasBeSecret then
        local ok, v = pcall(C_Secrets.ShouldAurasBeSecret)
        if not ok or issecret(v) or v then restrictedValue = true; return true end
    end
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
        and not pcall(C_UnitAuras.GetAuraDataByIndex, "player", 1, "HELPFUL") then
        restrictedValue = true
    end
    return restrictedValue
end

-- Itera auras de uma unidade: fn(name, dispelType, source, expiration, stacks)
-- retornar true dentro de fn interrompe a iteracao. Auras secretas sao puladas.
-- Retorna false quando as auras estao bloqueadas (nada foi lido).
local function ForEachAura(unit, filter, fn)
    if AurasRestricted() then return false end
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 40 do
            local ok, a = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, filter)
            if not ok then return false end
            if not a or issecret(a) then return true end
            local name = Pub(a.name)
            if name and fn(name, Pub(a.dispelName), Pub(a.sourceUnit), Pub(a.expirationTime), Pub(a.applications)) then
                return true
            end
        end
    else
        for i = 1, 40 do
            local ok, name, _, count, dtype, _, expiration, source = pcall(UnitAura, unit, i, filter)
            if not ok then return false end
            if name == nil then return true end
            name = Pub(name)
            if name and fn(name, Pub(dtype), Pub(source), Pub(expiration), Pub(count)) then return true end
        end
    end
    return true
end

-- Consulta de UMA aura do jogador pelo Spell ID, permitida em combate quando o
-- jogo libera aquele feitico (C_Secrets.ShouldSpellAuraBeSecret == false).
-- true = ativa, false = ausente, nil = desconhecido.
local function PlayerAuraByID(id)
    if not (C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID) then return nil end
    if C_Secrets and C_Secrets.ShouldSpellAuraBeSecret then
        local ok, secret = pcall(C_Secrets.ShouldSpellAuraBeSecret, id)
        if not ok or issecret(secret) or secret ~= false then return nil end
    end
    local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, id)
    if not ok or issecret(aura) then return nil end
    return aura ~= nil
end

-- Porcentagem de vida, ou nil quando a vida esta secreta
local function UnitPct(unit)
    local cur, max = Pub(UnitHealth(unit)), Pub(UnitHealthMax(unit))
    if not cur or not max or max == 0 then return nil end
    return cur / max * 100
end

---------------------------------------------------------------------------
-- 3. LIVRO DE FEITICOS
---------------------------------------------------------------------------
-- Todas as habilidades usadas pelas regras. O nome e resolvido via ID, entao
-- qualquer rank aprendido conta (o addon compara pelo nome localizado).
local ID = {
    -- Guerreiro
    PUMMEL = 6552, SHIELD_BASH = 72, SHIELD_WALL = 871, LAST_STAND = 12975, SHIELD_BLOCK = 2565,
    EXECUTE = 5308, OVERPOWER = 7384, REVENGE = 6572, BATTLE_SHOUT = 6673, SUNDER = 7386,
    HEROIC_STRIKE = 78, CLEAVE = 845, THUNDER_CLAP = 6343, WHIRLWIND = 1680, BLOODTHIRST = 23881,
    MORTAL_STRIKE = 12294, SHIELD_SLAM = 23922, REND = 772, SWEEPING = 12292, DEMO_SHOUT = 1160,
    INTIM_SHOUT = 5246, TAUNT = 355, BERSERKER_RAGE = 18499,
    -- Ladino
    KICK = 1766, GOUGE = 1776, EVASION = 5277, VANISH = 1856, SINISTER = 1752, EVISCERATE = 2098,
    SND = 5171, RIPOSTE = 14251, BLADE_FLURRY = 13877, KIDNEY = 408, ADRENALINE = 13750,
    -- Mago
    COUNTERSPELL = 2139, REMOVE_LESSER_CURSE = 475, ICE_BLOCK = 11958, FROST_NOVA = 122,
    FROSTBOLT = 116, FIREBALL = 133, FIRE_BLAST = 2136, ARCANE_EXPLOSION = 1449, BLIZZARD = 10,
    CONE_OF_COLD = 120, MANA_SHIELD = 1463, ICE_BARRIER = 11426, ARCANE_INTELLECT = 1459,
    FROST_ARMOR = 168, ICE_ARMOR = 7302, MAGE_ARMOR = 6117, EVOCATION = 12051,
    MAGE_CLEARCAST = 12536, PRESENCE_OF_MIND = 12043, PYROBLAST = 11366, ARCANE_POWER = 12042,
    COMBUSTION = 11129, SCORCH = 2948, ARCANE_MISSILES = 5143,
    -- Sacerdote
    PW_SHIELD = 17, WEAKENED_SOUL = 6788, RENEW = 139, LESSER_HEAL = 2050, HEAL = 2054,
    FLASH_HEAL = 2061, GREATER_HEAL = 2060, DISPEL_MAGIC = 527, CURE_DISEASE_P = 528,
    ABOLISH_DISEASE = 552, FADE = 586, PSYCHIC_SCREAM = 8122, SILENCE = 15487, SWP = 589,
    MIND_BLAST = 8092, MIND_FLAY = 15407, SMITE = 585, INNER_FIRE = 588, PW_FORT = 1243,
    INNER_FOCUS = 14751, HOLY_FIRE = 14914, SHADOWFORM = 15473, DESPERATE_PRAYER = 13908,
    -- Paladino
    SOR = 21084, SOTC = 21082, SOC = 20375, SOL = 20165, SOW = 20166, SOJ = 20164,
    JUDGEMENT = 20271, HOJ = 853, DIVINE_SHIELD = 642, DIVINE_PROT = 498, BOP = 1022,
    LOH = 633, HOLY_LIGHT = 635, FOL = 19750, PURIFY = 1152, CLEANSE = 4987,
    CONSECRATION = 26573, HOLY_SHIELD = 20925, EXORCISM = 879, HOW = 24275,
    BOM = 19740, BOW = 19742, BOK = 20217, BOSANC = 20911,
    DEVOTION = 465, RET_AURA = 7294, RIGHTEOUS_FURY = 25780, HOLY_SHOCK = 20473,
    -- Cacador
    SERPENT = 1978, MARK = 1130, ARCANE_SHOT = 3044, MULTI = 2643, AIMED = 19434,
    RAPTOR = 2973, MONGOOSE = 1495, WING_CLIP = 2974, FEIGN = 5384, DETERRENCE = 19263,
    HAWK = 13165, MONKEY = 13163, RAPID_FIRE = 3045, MEND_PET = 136, DISENGAGE = 781,
    CONCUSSIVE = 5116, SCATTER = 19503, VOLLEY = 1510,
    -- Bruxo
    SHADOW_BOLT = 686, CORRUPTION = 172, COA = 980, IMMOLATE = 348, LIFE_TAP = 1454,
    DRAIN_LIFE = 689, DEATH_COIL = 6789, HOWL = 5484, SHADOWBURN = 17877, HELLFIRE = 1949,
    RAIN_OF_FIRE = 5740, DEMON_SKIN = 687, DEMON_ARMOR = 706, SHADOW_TRANCE = 17941,
    DRAIN_SOUL = 1120, COW = 702, COE = 1490, COS = 17862, COR = 704, COT = 1714,
    -- Xama
    EARTH_SHOCK = 8042, CURE_POISON_S = 526, CURE_DISEASE_S = 2870, PURGE = 370,
    LIGHTNING_BOLT = 403, CHAIN_LIGHTNING = 421, FLAME_SHOCK = 8050, FROST_SHOCK = 8056,
    HEALING_WAVE = 331, LHW = 8004, CHAIN_HEAL = 1064, LIGHTNING_SHIELD = 324,
    ROCKBITER = 8017, FLAMETONGUE = 8024, WINDFURY = 8232, STORMSTRIKE = 17364,
    SHAMAN_CLEARCAST = 16246, GROUNDING = 8177, SEARING = 3599, MAGMA = 8190,
    FIRE_NOVA = 1535, NS_SHAMAN = 16188, ELEM_MASTERY = 16166,
    -- Druida
    BASH = 5211, FERAL_CHARGE = 16979, REMOVE_CURSE = 2782, CURE_POISON_D = 8946,
    ABOLISH_POISON = 2893, BARKSKIN = 22812, FRENZIED = 22842, MOONFIRE = 8921, WRATH = 5176,
    STARFIRE = 2912, INSECT_SWARM = 5570, REJUV = 774, REGROWTH = 8936, HEALING_TOUCH = 5185,
    SWIFTMEND = 18562, MOTW = 1126, THORNS = 467, BEAR = 5487, DIRE_BEAR = 9634, CAT = 768,
    CLAW = 1082, RAKE = 1822, RIP = 1079, BITE = 22568, SHRED = 5221, MAUL = 6807,
    SWIPE = 779, DEMO_ROAR = 99, GROWL = 6795, HURRICANE = 16914, DRUID_CLEARCAST = 16870,
    TIGERS_FURY = 5217, FAERIE_FIRE = 770, FAERIE_FIRE_FERAL = 16857, NS_DRUID = 17116,
}

local N, ICON = {}, {}   -- N[key] = nome localizado, ICON[key] = textura
local known = {}         -- known[nomeLocalizado] = true
local RANKID = {}        -- RANKID[key] = Spell ID do rank que o jogador aprendeu

-- Pelo nome, o jogo devolve o maior rank aprendido (para consultar a aura certa)
local function ResolveRankIDs()
    wipe(RANKID)
    if not (C_Spell and C_Spell.GetSpellInfo) then return end
    for key, name in pairs(N) do
        if known[name] then
            local ok, info = pcall(C_Spell.GetSpellInfo, name)
            local sid = ok and info and Pub(info.spellID)
            if type(sid) == "number" then RANKID[key] = sid end
        end
    end
end

local function ResolveNames()
    for key, id in pairs(ID) do
        local name, icon = SpellInfo(id)
        if name then N[key], ICON[key] = name, icon end
    end
end

local function AddKnown(name) if name then known[name] = true end end

-- Varre o Spellbook: so sugere o que o jogador JA aprendeu no nivel atual.
local function ScanSpellbook()
    wipe(known)
    if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and Enum and Enum.SpellBookSpellBank then
        local bank = Enum.SpellBookSpellBank.Player
        for t = 1, C_SpellBook.GetNumSpellBookSkillLines() do
            local line = C_SpellBook.GetSpellBookSkillLineInfo(t)
            if line then
                for i = line.itemIndexOffset + 1, line.itemIndexOffset + line.numSpellBookItems do
                    AddKnown(C_SpellBook.GetSpellBookItemName(i, bank))
                end
            end
        end
    else
        local book = BOOKTYPE_SPELL or "spell"
        for t = 1, GetNumSpellTabs() do
            local _, _, offset, num = GetSpellTabInfo(t)
            for i = offset + 1, offset + num do
                AddKnown(GetSpellBookItemName(i, book))
            end
        end
    end
end

local function Known(key)
    local name = N[key]
    return name ~= nil and known[name] == true
end

-- Pronto para uso: aprendido, usavel (mana/recurso/reativo/postura), fora de
-- recarga (ignora o GCD) e no alcance da unidade, quando aplicavel.
local function Ready(key, unit)
    local name = N[key]
    if not name or not known[name] then return false end
    if SpellUsable(name) == false then return false end
    local start, duration = SpellCooldown(name)
    if start > 0 and duration > 1.6 and (start + duration - GetTime()) > 0.25 then return false end
    if unit and unit ~= "player" and UnitExists(unit) and SpellInRange(name, unit) == false then
        return false
    end
    return true
end

---------------------------------------------------------------------------
-- 4. LEITURA DE ATALHOS (KEYBINDS)
---------------------------------------------------------------------------
-- Le o mapa de bindings do jogo. Nao depende de nenhum addon de barras:
--  a) binding direto do feitico ("SPELL Nome")
--  b) slot de acao onde o feitico esta -> comando de binding da Blizzard
--  c) comandos usados por ElvUI / Bartender4 / Dominos para o mesmo slot
local keyCache = {}

local SLOT_COMMANDS = {
    -- { primeiroSlot, ultimoSlot, comando Blizzard, n. da barra ElvUI }
    { 1, 12, "ACTIONBUTTON", 1 },
    { 13, 24, nil, 2 },
    { 25, 36, "MULTIACTIONBAR3BUTTON", 3 },
    { 37, 48, "MULTIACTIONBAR4BUTTON", 4 },
    { 49, 60, "MULTIACTIONBAR2BUTTON", 5 },
    { 61, 72, "MULTIACTIONBAR1BUTTON", 6 },
    { 73, 120, "ACTIONBUTTON", nil },     -- barras de postura/forma/furtividade
}

local function FirstKey(...)
    for i = 1, select("#", ...) do
        local cmd = select(i, ...)
        if cmd then
            local key = GetBindingKey(cmd)
            if key then return key end
        end
    end
end

local function KeyForSlot(slot)
    for _, r in ipairs(SLOT_COMMANDS) do
        if slot >= r[1] and slot <= r[2] then
            local btn = (slot - r[1]) % 12 + 1
            local elvBar = r[4]
            return FirstKey(
                r[3] and (r[3] .. btn),
                elvBar and ("ELVUIBAR" .. elvBar .. "BUTTON" .. btn),
                elvBar and ("CLICK ElvUI_Bar" .. elvBar .. "Button" .. btn .. ":LeftButton"),
                "CLICK BT4Button" .. slot .. ":Keybind",
                "CLICK BT4Button" .. slot .. ":LeftButton",
                "CLICK DominosActionButton" .. slot .. ":HOTKEY",
                "CLICK DominosActionButton" .. slot .. ":LeftButton")
        end
    end
end

-- Formata "SHIFT-2" -> "Shift+2", "CTRL-F1" -> "Ctrl+F1"
local function FormatKey(key)
    if not key then return "" end
    key = key:gsub("SHIFT%-", "Shift+"):gsub("CTRL%-", "Ctrl+"):gsub("ALT%-", "Alt+")
             :gsub("META%-", "Cmd+"):gsub("NUMPAD", "Num"):gsub("BUTTON", "Mouse")
             :gsub("MOUSEWHEELUP", "RodaCima"):gsub("MOUSEWHEELDOWN", "RodaBaixo")
    return key
end

local function SlotSpellName(slot)
    local actionType, id = PubAll(GetActionInfo(slot))
    if actionType == "spell" and id then
        return (SpellInfo(id))
    elseif actionType == "macro" and id then
        local s = Pub(GetMacroSpell(id))
        if type(s) == "number" then return (SpellInfo(s)) end
        return s
    end
end

local function RebuildKeyCache()
    wipe(keyCache)
    for slot = 1, 120 do
        if Is(HasAction(slot)) then
            local name = SlotSpellName(slot)
            if name and not keyCache[name] then
                local key = KeyForSlot(slot)
                if key then keyCache[name] = key end
            end
        end
    end
end

local function GetKeybind(key)
    local name = N[key]
    if not name then return "" end
    local direct = GetBindingKey("SPELL " .. name)
    return FormatKey(direct or keyCache[name])
end

---------------------------------------------------------------------------
-- 5. CONTEXTO DE COMBATE
---------------------------------------------------------------------------
local c = {}                     -- contexto reaproveitado (sem lixo por frame)
local playerBuffs, playerDebuffs, targetMine, targetAny = {}, {}, {}, {}
local groupUnits = {}
local dispelScan = {}            -- [tipo] = unidade com debuff daquele tipo
local lowest = { unit = nil, pct = 100 }
local injuredCount = 0
local lastGroupScan = 0

-- Auras secretas: quando o jogo esconde as auras, "buff ausente" nao pode ser
-- concluido. auraSecret[unit] = true faz as regras de "falta X" ficarem mudas.
local auraSecret = {}

local function CollectAuras(unit, filter, store, mineOnly, tag)
    wipe(store)
    if not UnitExists(unit) then return end
    local now = GetTime()
    local readable = ForEachAura(unit, filter, function(name, _, source, expiration)
        if not mineOnly or source == "player" or source == "pet" then
            local remain = (expiration and expiration > 0) and (expiration - now) or 999
            if not store[name] or store[name] < remain then store[name] = remain end
        end
    end)
    if tag then auraSecret[tag] = not readable end
end

local function RefreshGroupUnits()
    wipe(groupUnits)
    groupUnits[1] = "player"
    if Is(IsInRaid()) then
        for i = 1, Pub(GetNumGroupMembers()) or 0 do
            local u = "raid" .. i
            if not UnitIsUnit(u, "player") then groupUnits[#groupUnits + 1] = u end
        end
    elseif Is(IsInGroup()) then
        for i = 1, Pub(GetNumSubgroupMembers()) or 0 do groupUnits[#groupUnits + 1] = "party" .. i end
    end
end

-- Varre o grupo (4x por segundo): debuffs dissipaveis e aliado mais ferido.
local function ScanGroup()
    RefreshGroupUnits()
    wipe(dispelScan)
    lowest.unit, lowest.pct = nil, 100
    injuredCount = 0
    for _, u in ipairs(groupUnits) do
        if UnitExists(u) and not UnitIsDeadOrGhost(u) and Is(UnitIsConnected(u)) and Is(UnitIsVisible(u)) then
            local pct = UnitPct(u)  -- nil = vida secreta: aliado ignorado para cura
            if pct and pct < 80 then injuredCount = injuredCount + 1 end
            if pct and pct < lowest.pct then lowest.unit, lowest.pct = u, pct end
            ForEachAura(u, "HARMFUL", function(name, dtype)
                if dtype and dtype ~= "" and not dispelScan[dtype] then
                    dispelScan[dtype] = { unit = u, name = name }
                end
            end)
        end
    end
end

local function UnitInMyGroup(unit)
    if not UnitExists(unit) then return false end
    return UnitIsUnit(unit, "player") or Is(UnitInParty(unit)) or Pub(UnitInRaid(unit)) ~= nil
end

-- Cast do alvo. Campos secretos viram "desconhecido": sem duracao assume 1s,
-- sem a flag de interrupcao assume interrompivel (o jogo recusa se nao for).
local function ReadTargetCast()
    if not c.hostile then return nil end
    local name, _, _, _, endMS, _, _, notInt = UnitCastingInfo("target")
    if name == nil then
        name, _, _, _, endMS, _, notInt = UnitChannelInfo("target")
    end
    if name == nil then return nil end
    local cast = c.castData
    cast.name = Pub(name) or "feitico do inimigo"
    endMS = Pub(endMS)
    cast.remaining = endMS and (endMS / 1000 - GetTime()) or 1
    notInt = Pub(notInt)
    cast.interruptible = not notInt
    cast.onGroup = UnitInMyGroup("targettarget")
    cast.onMe = UnitExists("targettarget") and UnitIsUnit("targettarget", "player")
    return cast
end

-- Habilidades corpo a corpo usadas como "sonda" de alcance (funcionam em qualquer unidade)
local MELEE_PROBES = { "SINISTER", "HEROIC_STRIKE", "CLAW", "MAUL", "RAPTOR", "STORMSTRIKE", "JUDGEMENT" }

local function Near(unit)
    for _, key in ipairs(MELEE_PROBES) do
        if Known(key) then
            local r = SpellInRange(N[key], unit)
            if r ~= nil then return r end
        end
    end
    -- CheckInteractDistance e restrito em combate: so e usado fora dele.
    if not InCombatLockdown() then
        local ok, r = pcall(CheckInteractDistance, unit, 3)
        if ok and r ~= nil and not issecret(r) then return r and true or false end
    end
    return UnitExists(unit .. "target") and UnitIsUnit(unit .. "target", "player")
end

-- Conta inimigos em combate pelas placas de nome (o log de combate e proibido
-- para addons no Forever).
local function CountEnemies()
    local total, near = 0, 0
    for i = 1, 40 do
        local u = "nameplate" .. i
        if UnitExists(u) and UnitCanAttack("player", u) and not UnitIsDead(u) and UnitAffectingCombat(u) then
            total = total + 1
            if Near(u) then near = near + 1 end
        end
    end
    return total, near
end

local CREATURE_UNDEAD = { ["Undead"] = true, ["Morto-vivo"] = true, ["Morta-viva"] = true }
local CREATURE_DEMON  = { ["Demon"] = true, ["Demônio"] = true }

local function BuildContext()
    c.now = GetTime()
    c.inCombat = UnitAffectingCombat("player")
    -- Valores desconhecidos (secretos) recebem um padrao "neutro" que nao
    -- dispara regras: vida 100%, recurso 0, mana 100%.
    c.hp = UnitPct("player") or 100
    c.hpKnown = UnitPct("player") ~= nil
    local maxPow, pow = Pub(UnitPowerMax("player")), Pub(UnitPower("player"))
    c.power = pow or 0
    c.powerPct = (pow and maxPow and maxPow > 0) and (pow / maxPow * 100) or 0
    local maxMana, mana = Pub(UnitPowerMax("player", 0)), Pub(UnitPower("player", 0))
    c.manaPct = (mana and maxMana and maxMana > 0) and (mana / maxMana * 100) or 100
    c.cp = Pub(GetComboPoints("player", "target")) or 0
    c.grouped = Is(IsInGroup())

    c.target = UnitExists("target")
    c.hostile = c.target and UnitCanAttack("player", "target") and not UnitIsDead("target")
    c.thp = c.target and UnitPct("target") or 100
    local class = c.target and Pub(UnitClassification("target")) or "normal"
    c.elite = class == "elite" or class == "worldboss" or class == "rareelite"
              or (c.target and Pub(UnitLevel("target")) == -1)
    c.melee = c.hostile and Near("target")
    local ctype = c.target and Pub(UnitCreatureType("target"))
    c.undeadOrDemon = ctype and (CREATURE_UNDEAD[ctype] or CREATURE_DEMON[ctype]) or false
    c.threat = (c.hostile and UnitThreatSituation and Pub(UnitThreatSituation("player", "target"))) or 0
    c.targetOnAlly = c.hostile and UnitExists("targettarget") and not UnitIsUnit("targettarget", "player")
                     and UnitInMyGroup("targettarget")

    CollectAuras("player", "HELPFUL", playerBuffs, false, "player")
    CollectAuras("player", "HARMFUL", playerDebuffs)
    CollectAuras("target", "HARMFUL", targetMine, true, "target")
    CollectAuras("target", "HARMFUL", targetAny)

    c.castData = c.castData or {}
    c.cast = ReadTargetCast()
    c.enemies, c.near = CountEnemies()
    c.aoe = c.enemies >= DB.aoe
    c.meleeAoe = c.near >= DB.aoe

    if c.now - lastGroupScan > GROUP_SCAN_INTERVAL then
        lastGroupScan = c.now
        ScanGroup()
    end
    c.dispel = dispelScan
    c.lowest, c.lowestPct, c.injured = lowest.unit, lowest.pct, injuredCount
    c.petHp = UnitExists("pet") and UnitPct("pet") or 100
end

-- Ajudantes de leitura de estado (por chave do ID).
-- Buff/OnTarget = "tenho certeza que ESTA ativo".
-- Lacks/NotOnTarget = "tenho certeza que NAO esta" (falso se as auras estao secretas).
-- Com as auras bloqueadas, os buffs do jogador ainda podem ser consultados um a
-- um pelo Spell ID do rank que o jogador tem (quando o jogo libera aquele feitico).
local function Buff(key)
    if not N[key] then return false end
    if auraSecret.player then return PlayerAuraByID(RANKID[key] or ID[key]) == true end
    return playerBuffs[N[key]]
end
local function Debuff(key) return N[key] and playerDebuffs[N[key]] end
local function OnTarget(key) return N[key] and targetMine[N[key]] end         -- debuff MEU no alvo
local function OnTargetAny(key) return N[key] and targetAny[N[key]] end       -- debuff de qualquer um
local function Lacks(key)
    if not N[key] then return false end
    if auraSecret.player then return PlayerAuraByID(RANKID[key] or ID[key]) == false end
    return not playerBuffs[N[key]]
end
local function NotOnTarget(key) return not auraSecret.target and not OnTarget(key) end
local function NotOnTargetAny(key) return not auraSecret.target and not OnTargetAny(key) end
local function AnyOnTarget(...) for i = 1, select("#", ...) do if OnTarget((select(i, ...))) then return true end end end

-- true = tem, false = nao tem, nil = desconhecido (auras secretas)
local function UnitHasAura(unit, key, filter)
    local name, found = N[key], false
    if not name then return false end
    local readable = ForEachAura(unit, filter, function(n) if n == name then found = true; return true end end)
    if not readable then
        if unit == "player" or UnitIsUnit(unit, "player") then return PlayerAuraByID(ID[key]) end
        return nil
    end
    return found
end
local function UnitLacksAura(unit, key, filter) return UnitHasAura(unit, key, filter) == false end

-- Forma/postura ativa pela barra de formas (nao depende de auras, que podem
-- estar secretas). Retorna o nome localizado da forma ou nil.
local function ActiveFormName()
    local n = Pub(GetNumShapeshiftForms and GetNumShapeshiftForms()) or 0
    for i = 1, n do
        local _, active, _, sid = GetShapeshiftFormInfo(i)
        if Is(active) then
            sid = Pub(sid)
            return sid and (SpellInfo(sid)) or nil
        end
    end
end
local function InForm(...)
    local form = ActiveFormName()
    if not form then return false end
    for i = 1, select("#", ...) do if N[(select(i, ...))] == form then return true end end
    return false
end

local function TargetHasMagicBuff()
    local found = false
    ForEachAura("target", "HELPFUL", function(_, dtype) if dtype == "Magic" then found = true; return true end end)
    return found
end

---------------------------------------------------------------------------
-- 6. CONSTRUTORES DE REGRAS
---------------------------------------------------------------------------
-- Cada regra: { pick = {chaves...}, cat = categoria, unit = unidade|func,
--               when = func(c, unit) -> bool, msg = texto|func }
-- A primeira regra (na ordem) cuja condicao for verdadeira E cuja habilidade
-- estiver aprendida e pronta e exibida.

local function R(cat, pick, when, msg, unit)
    if type(pick) == "string" then pick = { pick } end
    return { cat = cat, pick = pick, when = when, msg = msg, unit = unit }
end

local function UnitLabel(unit)
    if not unit or unit == "player" then return "voce" end
    return Pub(UnitName(unit)) or "aliado"
end

-- Interrupcao: alvo hostil castando algo interrompivel
local function Interrupt(pick)
    return R("INTERRUPT", pick, function(c)
        return c.cast and c.cast.interruptible and c.cast.remaining > 0.15
    end, function(c) return "Interrompa: " .. c.cast.name end, "target")
end

-- Dissipar: tipos = { "Poison", "Disease", "Curse", "Magic" }
local function Dispel(pick, types)
    local rule = R("DISPEL", pick, nil, nil, nil)
    rule.unit = function(c)
        for _, t in ipairs(types) do
            local d = c.dispel[t]
            if d then rule._d = d; return d.unit end
        end
    end
    rule.when = function(c, unit) return unit ~= nil end
    rule.msg = function() return "Remova " .. rule._d.name .. " de " .. UnitLabel(rule._d.unit) end
    return rule
end

-- Buff proprio ausente. "family" = buffs equivalentes (qualquer um satisfaz)
local function SelfBuff(pick, family, inCombatToo)
    family = family or (type(pick) == "table" and pick or { pick })
    return R("BUFF", pick, function(c)
        if c.inCombat and not inCombatToo then return false end
        -- so sugere com certeza de que NENHUM buff da familia esta ativo
        for _, k in ipairs(family) do if not Lacks(k) then return false end end
        return true
    end, "Buff ausente", "player")
end

-- Cura no aliado mais ferido (inclui voce)
local function HealLowest(pick, threshold, extra)
    return R("HEAL", pick, function(c, unit)
        return unit and c.lowestPct < threshold and (not extra or extra(c, unit))
    end, function(c) return string.format("Cure %s (%d%%)", UnitLabel(c.lowest), c.lowestPct) end,
    function(c) return c.lowest end)
end

local function Emergency(pick, hpBelow, extra, msg)
    return R("EMERGENCY", pick, function(c)
        return c.inCombat and c.hp < hpBelow and (not extra or extra(c))
    end, msg or "Vida baixa! Use agora")
end

-- Cast pesado nao-interrompivel vindo em voce -> defensiva
local function BigCastDefense(pick, msg)
    return R("DEFENSIVE", pick, function(c)
        return c.cast and c.cast.onMe and (not c.cast.interruptible or c.elite) and c.cast.remaining < 2
    end, msg or function(c) return "Mitigue: " .. c.cast.name end)
end

local function Taunt(pick, isTank)
    return R("TAUNT", pick, function(c) return c.grouped and isTank(c) and c.targetOnAlly end,
        function() return "Alvo atacando " .. (Pub(UnitName("targettarget")) or "aliado") .. "! Provoque" end, "target")
end

-- Habilidade ofensiva sobre o alvo hostil
local function Hit(cat, pick, when, msg)
    return R(cat, pick, function(c, u) return c.hostile and (not when or when(c, u)) end, msg, "target")
end

---------------------------------------------------------------------------
-- 7. REGRAS POR CLASSE
---------------------------------------------------------------------------
local CLASS_RULES = {}

CLASS_RULES.WARRIOR = function()
    local function tank() return Pub(GetShapeshiftForm()) == 2 end -- Postura Defensiva
    return {
        Emergency("SHIELD_WALL", 25),
        Emergency("LAST_STAND", 30),
        Emergency("INTIM_SHOUT", 35, function(c) return c.near >= 2 end, "Cercado! Medo em area"),
        Interrupt({ "PUMMEL", "SHIELD_BASH" }),
        BigCastDefense("SHIELD_BLOCK"),
        Taunt("TAUNT", tank),
        SelfBuff("BATTLE_SHOUT", nil, true),
        Hit("COMBO", "EXECUTE", nil, "Alvo < 20%: Executar!"),
        Hit("COMBO", "OVERPOWER", nil, "Alvo esquivou: Sobrepujar!"),
        Hit("COMBO", "REVENGE", nil, "Bloqueio/Esquiva: Revanche!"),
        R("AOE", "SWEEPING", function(c) return c.inCombat and c.meleeAoe end, "Varios mobs: ative Golpes Amplos"),
        Hit("AOE", "WHIRLWIND", function(c) return c.near >= 2 end,
            function() return Buff("SWEEPING") and "COMBO Golpes Amplos -> Redemoinho" or "Varios mobs: Redemoinho" end),
        Hit("AOE", "THUNDER_CLAP", function(c) return c.meleeAoe and NotOnTargetAny("THUNDER_CLAP") end, "Area: Trovoada"),
        Hit("AOE", "DEMO_SHOUT", function(c) return c.meleeAoe and NotOnTargetAny("DEMO_SHOUT") end, "Area: Grito Desmoralizante"),
        Hit("AOE", "CLEAVE", function(c) return c.near >= 2 and c.power >= 40 end, "Raiva sobrando: Cutilada"),
        Hit("ROTATION", "SHIELD_SLAM", nil, "Golpe de Escudo"),
        Hit("ROTATION", { "BLOODTHIRST", "MORTAL_STRIKE" }, nil, "Golpe principal"),
        Hit("ROTATION", "SUNDER", function(c) return tank() and NotOnTarget("SUNDER") end, "Gere ameaca: Fender Armadura"),
        Hit("ROTATION", "REND", function(c) return c.thp > 30 and NotOnTarget("REND") end, "Aplique Dilacerar"),
        Hit("ROTATION", "HEROIC_STRIKE", function(c) return c.power >= 50 end, "Raiva alta: Golpe Heroico"),
    }
end

CLASS_RULES.ROGUE = function()
    return {
        Emergency("VANISH", 15, nil, "Quase morto: Sumir"),
        Emergency("EVASION", 50, function(c) return c.threat >= 2 or not c.grouped end, "Apanhando: Evasao"),
        Interrupt("KICK"),
        Interrupt("GOUGE"),
        Hit("INTERRUPT", "KIDNEY", function(c) return c.cast and c.cp >= 1 end, "Sem Chute: Golpe nos Rins"),
        R("AOE", "BLADE_FLURRY", function(c) return c.inCombat and c.near >= 2 end, "Varios mobs: Rajada de Laminas"),
        Hit("COMBO", "RIPOSTE", nil, "Aparou! Ripostar"),
        Hit("COMBO", "SND", function(c) return c.cp >= 2 and Lacks("SND") and c.thp > 25 end,
            "Pontos de combo: ative Picar"),
        Hit("COMBO", "EVISCERATE", function(c) return c.cp >= 5 or (c.cp >= 2 and c.thp < 15) end,
            function(c) return c.cp .. " pontos: Eviscerar!" end),
        R("ROTATION", "ADRENALINE", function(c) return c.inCombat and c.elite end, "Elite/chefe: Adrenalina"),
        Hit("ROTATION", "SINISTER", nil, "Gere pontos: Golpe Sinistro"),
    }
end

CLASS_RULES.MAGE = function()
    local function filler()
        if Known("PYROBLAST") or Known("COMBUSTION") or not Known("FROSTBOLT") then return { "FIREBALL", "FROSTBOLT" } end
        return { "FROSTBOLT", "FIREBALL" }
    end
    local fill = filler()
    return {
        Emergency("ICE_BLOCK", 20),
        R("EMERGENCY", "FROST_NOVA", function(c) return c.inCombat and c.melee and c.hp < 70 end,
            "Inimigo colado: Nova Congelante e afaste-se"),
        Interrupt("COUNTERSPELL"),
        Dispel("REMOVE_LESSER_CURSE", { "Curse" }),
        R("DEFENSIVE", "ICE_BARRIER", function(c) return c.inCombat and c.hp < 80 and Lacks("ICE_BARRIER") end, "Escudo: Barreira de Gelo"),
        R("DEFENSIVE", "MANA_SHIELD", function(c) return c.inCombat and c.hp < 40 and Lacks("MANA_SHIELD") end, "Vida baixa: Escudo de Mana"),
        R("COMBO", "EVOCATION", function(c) return c.inCombat and c.manaPct < 12 end, "Sem mana: Evocacao"),
        Hit("COMBO", "PYROBLAST", function() return Buff("PRESENCE_OF_MIND") end, "COMBO Presenca da Mente -> Piroblasto"),
        R("COMBO", "ARCANE_EXPLOSION", function(c) return Buff("MAGE_CLEARCAST") and c.meleeAoe end, "COMBO Clarividencia -> Explosao Arcana gratis"),
        Hit("COMBO", fill, function() return Buff("MAGE_CLEARCAST") end, "COMBO Clarividencia -> feitico forte gratis"),
        R("COMBO", "PRESENCE_OF_MIND", function(c) return c.hostile and c.inCombat end, "Prepare: Presenca da Mente (depois Piroblasto)"),
        R("COMBO", { "ARCANE_POWER", "COMBUSTION" }, function(c) return c.hostile and c.inCombat and c.elite end, "Elite/chefe: ative cooldown de dano"),
        R("AOE", "FROST_NOVA", function(c) return c.inCombat and c.meleeAoe and NotOnTargetAny("FROST_NOVA") end, "FARM: Nova Congelante -> Explosao Arcana"),
        R("AOE", "CONE_OF_COLD", function(c) return c.meleeAoe and c.hostile end, "Area: Cone de Gelo"),
        R("AOE", "ARCANE_EXPLOSION", function(c) return c.meleeAoe end, "Mobs agrupados: Explosao Arcana"),
        R("AOE", "BLIZZARD", function(c) return c.enemies >= DB.aoe + 1 and not c.meleeAoe end, "Mobs a distancia: Nevasca"),
        Hit("ROTATION", "PYROBLAST", function(c) return not c.inCombat end, "Abertura: Piroblasto"),
        Hit("ROTATION", "FIRE_BLAST", function(c) return c.thp < 30 or c.melee end, "Instantaneo: Impacto de Fogo"),
        Hit("ROTATION", fill, nil, "Dano principal"),
        SelfBuff("ARCANE_INTELLECT"),
        SelfBuff({ "MAGE_ARMOR", "ICE_ARMOR", "FROST_ARMOR" }),
    }
end

CLASS_RULES.PRIEST = function()
    local function canShield(c, u) return UnitLacksAura(u, "WEAKENED_SOUL", "HARMFUL") and UnitLacksAura(u, "PW_SHIELD", "HELPFUL") end
    return {
        Emergency("DESPERATE_PRAYER", 30),
        R("EMERGENCY", "PW_SHIELD", function(c) return c.inCombat and c.hp < 50 and canShield(c, "player") end, "Vida baixa: Escudo em voce", "player"),
        Emergency("PSYCHIC_SCREAM", 40, function(c) return c.near >= 1 end, "Cercado: Grito Psiquico"),
        R("DEFENSIVE", "FADE", function(c) return c.grouped and c.threat >= 2 end, "Voce puxou aggro: Desvanecer"),
        Interrupt("SILENCE"),
        Dispel("DISPEL_MAGIC", { "Magic" }),
        Dispel({ "ABOLISH_DISEASE", "CURE_DISEASE_P" }, { "Disease" }),
        HealLowest("PW_SHIELD", 40, canShield),
        HealLowest({ "FLASH_HEAL", "HEAL", "LESSER_HEAL" }, 40),
        R("COMBO", { "GREATER_HEAL", "HEAL" }, function(c, u) return Buff("INNER_FOCUS") and u and c.lowestPct < 70 end,
            "COMBO Foco Interior -> cura grande gratis", function(c) return c.lowest end),
        HealLowest({ "GREATER_HEAL", "HEAL", "LESSER_HEAL" }, 60),
        HealLowest("RENEW", 85, function(c, u) return UnitLacksAura(u, "RENEW", "HELPFUL") end),
        Hit("COMBO", "MIND_BLAST", function() return Buff("INNER_FOCUS") end, "COMBO Foco Interior -> Explosao Mental"),
        SelfBuff("SHADOWFORM", nil, true),
        Hit("ROTATION", "SWP", function(c) return NotOnTarget("SWP") and c.thp > 20 end, "Aplique Palavra Sombria: Dor"),
        Hit("ROTATION", "HOLY_FIRE", function(c) return not c.inCombat end, "Abertura: Fogo Sagrado"),
        Hit("ROTATION", "MIND_BLAST", nil, "Explosao Mental"),
        Hit("ROTATION", { "MIND_FLAY", "SMITE" }, nil, "Dano continuo"),
        SelfBuff("PW_FORT"),
        SelfBuff("INNER_FIRE"),
    }
end

CLASS_RULES.PALADIN = function()
    local SEALS = { "SOC", "SOR", "SOTC", "SOL", "SOW", "SOJ" }
    local function hasSeal() for _, k in ipairs(SEALS) do if Buff(k) then return true end end end
    return {
        Emergency("DIVINE_SHIELD", 20, nil, "Quase morto: Escudo Divino"),
        Emergency("LOH", 12, nil, "Ultimo recurso: Imposicao das Maos"),
        Emergency("DIVINE_PROT", 25),
        R("EMERGENCY", "BOP", function(c, u) return c.inCombat and u and u ~= "player" and c.lowestPct < 20 end,
            function(c) return "Salve " .. UnitLabel(c.lowest) .. ": Bencao de Protecao" end, function(c) return c.lowest end),
        Interrupt("HOJ"),
        Dispel({ "CLEANSE", "PURIFY" }, { "Poison", "Disease" }),
        Dispel("CLEANSE", { "Magic" }),
        HealLowest("HOLY_SHOCK", 50),
        HealLowest("HOLY_LIGHT", 45),
        HealLowest("FOL", 75),
        R("COMBO", { "SOC", "SOR" }, function(c) return (c.hostile or c.inCombat) and not auraSecret.player and not hasSeal() end,
            "Sem selo: ative o Selo (depois Julgamento)", "player"),
        Hit("COMBO", "JUDGEMENT", function() return hasSeal() end, "COMBO Selo ativo -> Julgamento (e reaplique o selo)"),
        Hit("COMBO", "HOW", nil, "Alvo < 20%: Martelo da Colera"),
        R("AOE", "CONSECRATION", function(c) return c.meleeAoe and c.manaPct > 30 end, "Varios mobs: Consagracao"),
        R("ROTATION", "HOLY_SHIELD", function(c) return c.inCombat and Buff("RIGHTEOUS_FURY") and Lacks("HOLY_SHIELD") end, "Tank: Escudo Sagrado"),
        Hit("ROTATION", "EXORCISM", function(c) return c.undeadOrDemon end, "Morto-vivo/Demonio: Exorcismo"),
        SelfBuff({ "DEVOTION", "RET_AURA" }, { "DEVOTION", "RET_AURA" }, true),
        SelfBuff({ "BOM", "BOW", "BOK" }, { "BOM", "BOW", "BOK", "BOSANC" }),
    }
end

CLASS_RULES.HUNTER = function()
    return {
        R("EMERGENCY", "FEIGN", function(c) return c.inCombat and c.grouped and c.threat >= 2 and c.hp < 60 end, "Aggro em voce: Fingir de Morto"),
        Emergency("DETERRENCE", 35, function(c) return c.melee end, "Apanhando corpo a corpo: Dissuasao"),
        R("HEAL", "MEND_PET", function(c) return c.inCombat and c.petHp < 40 end, "Pet morrendo: Curar Ajudante", "pet"),
        Hit("INTERRUPT", "SCATTER", function(c) return c.cast and c.cast.interruptible end, function(c) return "Interrompa: " .. c.cast.name end),
        R("BUFF", "HAWK", function(c) return c.hostile and not c.melee and Lacks("HAWK") end, "Combate a distancia: Aspecto do Falcao", "player"),
        Hit("COMBO", "MONGOOSE", function(c) return c.melee end, "Alvo esquivou: Mordida do Mangusto"),
        Hit("ROTATION", "WING_CLIP", function(c) return c.melee and NotOnTarget("WING_CLIP") and not c.grouped end, "Colado: Cortar Asas e afaste-se"),
        Hit("ROTATION", "RAPTOR", function(c) return c.melee end, "Corpo a corpo: Golpe do Raptor"),
        Hit("ROTATION", "MARK", function(c) return NotOnTargetAny("MARK") and (c.elite or c.thp > 60) end, "Marque o alvo"),
        Hit("AOE", { "VOLLEY", "MULTI" }, function(c) return c.aoe end, "Varios mobs: dano em area"),
        R("ROTATION", "RAPID_FIRE", function(c) return c.hostile and c.inCombat and c.elite end, "Elite/chefe: Disparo Rapido"),
        Hit("ROTATION", "SERPENT", function(c) return NotOnTarget("SERPENT") and c.thp > 30 end, "Aplique Picada da Serpente"),
        Hit("ROTATION", "AIMED", function(c) return not c.melee end, "Tiro Mirado"),
        Hit("ROTATION", "MULTI", function(c) return not c.melee end, "Tiro Multiplo"),
        Hit("ROTATION", "ARCANE_SHOT", function(c) return not c.melee end, "Tiro Arcano"),
    }
end

CLASS_RULES.WARLOCK = function()
    local CURSES = { "COA", "COE", "COS", "COR", "COW", "COT" }
    local function anyCurse() return AnyOnTarget(unpack(CURSES)) end
    return {
        Emergency("DEATH_COIL", 35, nil, "Vida baixa: Espiral da Morte (cura)"),
        Emergency("HOWL", 40, function(c) return c.near >= 2 end, "Cercado: Uivo do Terror"),
        Interrupt("DEATH_COIL"),
        Hit("COMBO", "SHADOW_BOLT", function() return Buff("SHADOW_TRANCE") end, "COMBO Transe Sombrio -> Seta Sombria instantanea!"),
        Hit("COMBO", "SHADOWBURN", function(c) return c.thp < 20 end, "Finalize: Queimadura Sombria"),
        Hit("COMBO", "DRAIN_SOUL", function(c) return c.thp < 12 and (Pub(GetItemCount(6265)) or 99) < 5 end, "Alvo morrendo: Drenar Alma (fragmento)"),
        R("COMBO", "LIFE_TAP", function(c) return c.manaPct < 25 and c.hp > 60 end, "Mana baixa, vida alta: Toque da Vida", "player"),
        Hit("ROTATION", "DRAIN_LIFE", function(c) return c.hp < 45 end, "Recupere vida: Drenar Vida"),
        Hit("AOE", "RAIN_OF_FIRE", function(c) return c.aoe and not c.meleeAoe end, "Varios mobs: Chuva de Fogo"),
        R("AOE", "HELLFIRE", function(c) return c.meleeAoe and c.hp > 50 end, "Mobs colados: Fogo do Inferno"),
        Hit("ROTATION", "CORRUPTION", function(c) return NotOnTarget("CORRUPTION") and c.thp > 20 end, "Aplique Corrupcao"),
        Hit("ROTATION", "COA", function(c) return not auraSecret.target and not anyCurse() and c.thp > 30 end, "Aplique uma Maldicao"),
        Hit("ROTATION", "IMMOLATE", function(c) return NotOnTarget("IMMOLATE") and c.thp > 30 end, "Aplique Imolar"),
        Hit("ROTATION", "SHADOW_BOLT", nil, "Seta Sombria"),
        SelfBuff({ "DEMON_ARMOR", "DEMON_SKIN" }),
    }
end

CLASS_RULES.SHAMAN = function()
    local function weaponMissing() local mh = GetWeaponEnchantInfo(); return mh ~= nil and not issecret(mh) and not mh end
    local function noFireTotem()
        if not GetTotemInfo then return false end
        local has = GetTotemInfo(1)
        return not issecret(has) and not has
    end
    return {
        R("EMERGENCY", "NS_SHAMAN", function(c) return c.inCombat and c.lowestPct < 30 end, "Emergencia: Rapidez da Natureza -> Onda Curativa"),
        R("COMBO", "HEALING_WAVE", function(c, u) return Buff("NS_SHAMAN") and u and c.lowestPct < 60 end,
            "COMBO Rapidez da Natureza -> Onda Curativa instantanea", function(c) return c.lowest end),
        Interrupt("EARTH_SHOCK"),
        R("DEFENSIVE", "GROUNDING", function(c) return c.cast and c.cast.onGroup end, "Feitico vindo: Totem de Aterramento"),
        Dispel("CURE_POISON_S", { "Poison" }),
        Dispel("CURE_DISEASE_S", { "Disease" }),
        HealLowest({ "LHW", "HEALING_WAVE" }, 40),
        HealLowest("CHAIN_HEAL", 75, function(c) return c.injured >= 3 end),
        HealLowest("HEALING_WAVE", 60),
        Hit("DISPEL", "PURGE", function() return TargetHasMagicBuff() end, "Inimigo com buff magico: Expurgar"),
        R("BUFF", { "WINDFURY", "FLAMETONGUE", "ROCKBITER" }, function(c) return weaponMissing() end, "Encante a arma", "player"),
        SelfBuff("LIGHTNING_SHIELD", nil, true),
        Hit("COMBO", "CHAIN_LIGHTNING", function(c) return (Buff("SHAMAN_CLEARCAST") or Buff("ELEM_MASTERY")) and c.enemies >= 2 end, "COMBO Clarividencia -> Cadeia de Raios"),
        Hit("COMBO", "LIGHTNING_BOLT", function() return Buff("SHAMAN_CLEARCAST") or Buff("ELEM_MASTERY") end, "COMBO Clarividencia -> Raio"),
        R("COMBO", "ELEM_MASTERY", function(c) return c.hostile and c.inCombat and c.elite end, "Elite/chefe: Dominio Elemental"),
        Hit("ROTATION", "STORMSTRIKE", nil, "Ataque de Tempestade"),
        R("AOE", { "MAGMA", "FIRE_NOVA" }, function(c) return c.meleeAoe and noFireTotem() end, "Varios mobs: totem de fogo em area"),
        Hit("AOE", "CHAIN_LIGHTNING", function(c) return c.enemies >= 2 end, "Varios mobs: Cadeia de Raios"),
        R("ROTATION", "SEARING", function(c) return c.hostile and c.inCombat and noFireTotem() end, "Totem Calcinante"),
        Hit("ROTATION", "FLAME_SHOCK", function(c) return NotOnTarget("FLAME_SHOCK") and c.thp > 30 end, "Aplique Choque Flamejante"),
        Hit("ROTATION", "EARTH_SHOCK", function(c) return c.melee and c.manaPct > 50 end, "Choque Terreno"),
        Hit("ROTATION", "LIGHTNING_BOLT", function(c) return not c.melee or not c.inCombat end, "Raio"),
    }
end

CLASS_RULES.DRUID = function()
    local function bear() return InForm("BEAR", "DIRE_BEAR") end
    local function cat() return InForm("CAT") end
    local function caster() return not bear() and not cat() end
    return {
        Emergency("BARKSKIN", 40),
        R("EMERGENCY", "FRENZIED", function(c) return c.inCombat and bear() and c.hp < 40 end, "Urso ferido: Regeneracao Frenetica"),
        R("EMERGENCY", "NS_DRUID", function(c) return c.inCombat and c.lowestPct < 30 and caster() end, "Emergencia: Rapidez da Natureza -> Toque de Cura"),
        R("COMBO", "HEALING_TOUCH", function(c, u) return Buff("NS_DRUID") and u and c.lowestPct < 60 end,
            "COMBO Rapidez da Natureza -> Toque de Cura instantaneo", function(c) return c.lowest end),
        Interrupt({ "FERAL_CHARGE", "BASH" }),
        Dispel("REMOVE_CURSE", { "Curse" }),
        Dispel({ "ABOLISH_POISON", "CURE_POISON_D" }, { "Poison" }),
        HealLowest("SWIFTMEND", 40, function(c, u) return UnitHasAura(u, "REJUV", "HELPFUL") or UnitHasAura(u, "REGROWTH", "HELPFUL") end),
        HealLowest("REGROWTH", 45, function() return caster() end),
        HealLowest("HEALING_TOUCH", 55, function() return caster() end),
        HealLowest("REJUV", 85, function(c, u) return caster() and UnitLacksAura(u, "REJUV", "HELPFUL") end),
        Taunt("GROWL", bear),
        -- Urso (tank)
        Hit("COMBO", "MAUL", function() return bear() and Buff("DRUID_CLEARCAST") end, "COMBO Clarividencia -> Espancar gratis"),
        Hit("AOE", "DEMO_ROAR", function(c) return bear() and c.near >= 2 and NotOnTargetAny("DEMO_ROAR") end, "Area: Rugido Desmoralizante"),
        Hit("AOE", "SWIPE", function(c) return bear() and c.near >= 2 end, "Varios mobs: Golpe Giratorio"),
        Hit("ROTATION", "MAUL", function(c) return bear() and c.power >= 15 end, "Espancar"),
        -- Gato (dano)
        Hit("COMBO", "SHRED", function() return cat() and Buff("DRUID_CLEARCAST") end, "COMBO Clarividencia -> Retalhar (por tras)"),
        Hit("COMBO", "RIP", function(c) return cat() and c.cp >= 5 and NotOnTarget("RIP") and c.thp > 40 end, "5 pontos: Rasgar"),
        Hit("COMBO", "BITE", function(c) return cat() and (c.cp >= 5 or (c.cp >= 3 and c.thp < 20)) end, function(c) return c.cp .. " pontos: Mordida Feroz" end),
        R("ROTATION", "TIGERS_FURY", function(c) return cat() and c.hostile and c.inCombat and Lacks("TIGERS_FURY") and c.power >= 80 end, "Furia do Tigre"),
        Hit("ROTATION", "RAKE", function(c) return cat() and NotOnTarget("RAKE") end, "Aplique Rasgadura"),
        Hit("ROTATION", "CLAW", function() return cat() end, "Gere pontos: Garra"),
        -- Conjurador / Equilibrio
        Hit("COMBO", "STARFIRE", function() return caster() and Buff("DRUID_CLEARCAST") end, "COMBO Clarividencia -> Fogo Estelar gratis"),
        R("AOE", "HURRICANE", function(c) return caster() and c.enemies >= DB.aoe + 1 end, "Varios mobs: Furacao"),
        Hit("ROTATION", "FAERIE_FIRE", function(c) return caster() and c.elite and NotOnTargetAny("FAERIE_FIRE") end, "Elite: Fogo Feerico"),
        Hit("ROTATION", "MOONFIRE", function(c) return caster() and NotOnTarget("MOONFIRE") end, "Aplique Fogo Lunar"),
        Hit("ROTATION", "INSECT_SWARM", function(c) return caster() and NotOnTarget("INSECT_SWARM") and c.thp > 30 end, "Aplique Enxame de Insetos"),
        Hit("ROTATION", "STARFIRE", function(c) return caster() and c.thp > 40 end, "Fogo Estelar"),
        Hit("ROTATION", "WRATH", function() return caster() end, "Ira"),
        R("BUFF", "MOTW", function(c) return not c.inCombat and caster() and Lacks("MOTW") end, "Buff ausente", "player"),
        R("BUFF", "THORNS", function(c) return not c.inCombat and caster() and Lacks("THORNS") end, "Buff ausente", "player"),
    }
end

---------------------------------------------------------------------------
-- 8. MOTOR DE DECISAO
---------------------------------------------------------------------------
local CATEGORY = {
    EMERGENCY = { 1.00, 0.15, 0.15, "EMERGENCIA" },
    INTERRUPT = { 1.00, 0.55, 0.00, "INTERROMPER" },
    DEFENSIVE = { 0.90, 0.30, 0.90, "DEFESA" },
    DISPEL    = { 0.65, 0.35, 1.00, "DISSIPAR" },
    HEAL      = { 0.20, 1.00, 0.30, "CURA" },
    TAUNT     = { 1.00, 0.85, 0.20, "PROVOCAR" },
    COMBO     = { 1.00, 0.82, 0.00, "COMBO" },
    AOE       = { 0.20, 0.80, 1.00, "AREA / FARM" },
    ROTATION  = { 0.85, 0.85, 0.85, "DANO" },
    BUFF      = { 0.30, 0.90, 0.90, "BUFF" },
}

local rules = {}
local playerClass

local function LoadClassRules()
    local _, class = UnitClass("player")
    playerClass = class
    local builder = CLASS_RULES[class]
    rules = builder and builder() or {}
end

local function ResolveUnit(rule)
    local u = rule.unit
    if type(u) == "function" then return u(c) end
    return u
end

-- Retorna regra, chave escolhida e unidade da primeira sugestao valida.
local function Evaluate()
    for _, rule in ipairs(rules) do
        local unit = ResolveUnit(rule)
        if (unit == nil and not rule.unit) or (unit and UnitExists(unit)) then
            if not rule.when or rule.when(c, unit) then
                for _, key in ipairs(rule.pick) do
                    if Known(key) and Ready(key, unit) then return rule, key, unit end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- 9. HUD FLUTUANTE (ancora propria e independente)
---------------------------------------------------------------------------
local ICON_SIZE = 56
local hud = CreateFrame("Frame", "MVAT_HUD", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
hud:SetSize(ICON_SIZE, ICON_SIZE)
hud:SetFrameStrata("HIGH")
hud:SetClampedToScreen(true)
hud:SetMovable(true)
hud:RegisterForDrag("LeftButton")
hud:Hide()

hud.border = hud:CreateTexture(nil, "BACKGROUND")
hud.border:SetPoint("TOPLEFT", -3, 3)
hud.border:SetPoint("BOTTOMRIGHT", 3, -3)
hud.border:SetColorTexture(1, 1, 1, 1)

hud.icon = hud:CreateTexture(nil, "ARTWORK")
hud.icon:SetAllPoints()
hud.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

hud.key = hud:CreateFontString(nil, "OVERLAY")
hud.key:SetFont(STANDARD_TEXT_FONT, 18, "THICKOUTLINE")
hud.key:SetPoint("BOTTOMRIGHT", -2, 3)
hud.key:SetTextColor(1, 1, 1)

hud.label = hud:CreateFontString(nil, "OVERLAY")
hud.label:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
hud.label:SetPoint("BOTTOM", hud, "TOP", 0, 6)

hud.reason = hud:CreateFontString(nil, "OVERLAY")
hud.reason:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
hud.reason:SetPoint("TOP", hud, "BOTTOM", 0, -6)
hud.reason:SetWidth(260)
hud.reason:SetJustifyH("CENTER")

-- Pulso ao trocar de sugestao
hud.pulse = hud:CreateAnimationGroup()
local grow = hud.pulse:CreateAnimation("Scale")
grow:SetScale(1.18, 1.18); grow:SetDuration(0.10); grow:SetOrder(1)
local shrink = hud.pulse:CreateAnimation("Scale")
shrink:SetScale(1 / 1.18, 1 / 1.18); shrink:SetDuration(0.12); shrink:SetOrder(2)

-- Fundo visivel apenas quando destravado (modo de posicionamento)
hud.mover = hud:CreateTexture(nil, "BACKGROUND", nil, -1)
hud.mover:SetPoint("TOPLEFT", -40, 30)
hud.mover:SetPoint("BOTTOMRIGHT", 40, -40)
hud.mover:SetColorTexture(0, 0.6, 1, 0.25)
hud.mover:Hide()

hud:SetScript("OnDragStart", function(self) if not DB.locked then self:StartMoving() end end)
hud:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    DB.point, DB.relPoint, DB.x, DB.y = point, relPoint, x, y
end)

local function ApplyLayout()
    hud:ClearAllPoints()
    hud:SetPoint(DB.point, UIParent, DB.relPoint, DB.x, DB.y)
    hud:SetScale(DB.scale)
    hud:EnableMouse(not DB.locked)          -- travado = clique atravessa o HUD
    hud.mover:SetShown(not DB.locked)
    hud.reason:SetShown(DB.showText)
end

local current -- chave exibida no momento

local function ShowSuggestion(key, cat, text)
    local col = CATEGORY[cat] or CATEGORY.ROTATION
    hud.icon:SetTexture(ICON[key] or 134400)
    hud.border:SetColorTexture(col[1], col[2], col[3], 0.9)
    hud.label:SetText(col[4])
    hud.label:SetTextColor(col[1], col[2], col[3])
    hud.key:SetText(GetKeybind(key))
    hud.reason:SetText(text or N[key] or "")
    if current ~= key then
        current = key
        hud.pulse:Stop(); hud.pulse:Play()
    end
    hud:Show()
end

local function HideSuggestion()
    current = nil
    if DB.locked then hud:Hide()
    else
        hud.icon:SetTexture(134400) -- "?" para posicionar
        hud.key:SetText("")
        hud.label:SetText("MVAT - arraste para mover")
        hud.label:SetTextColor(0.2, 0.8, 1)
        hud.reason:SetText("/mvat lock para travar")
        hud.border:SetColorTexture(0.2, 0.8, 1, 0.9)
        hud:Show()
    end
end

local testUntil = 0
local combatSnap = { seen = false, active = false, shown = 0 } -- o que estava legivel no ultimo combate

local function DoUpdate()
    if UnitIsDeadOrGhost("player") or Is(UnitOnTaxi("player")) or (Is(IsMounted()) and not UnitAffectingCombat("player")) then
        HideSuggestion(); return
    end
    BuildContext()
    if c.inCombat then
        if not combatSnap.active then -- inicio de um novo combate
            combatSnap.active, combatSnap.seen, combatSnap.shown = true, true, 0
        end
        combatSnap.hp = c.hpKnown
        combatSnap.power = Pub(UnitPower("player")) ~= nil
        combatSnap.auraP, combatSnap.auraT = auraSecret.player, auraSecret.target
    else
        combatSnap.active = false
    end
    if DB.combatOnly and not c.inCombat then HideSuggestion(); return end
    local rule, key, unit = Evaluate()
    if not rule then HideSuggestion(); return end
    if c.inCombat and key ~= current then combatSnap.shown = combatSnap.shown + 1 end
    local text = rule.msg
    if type(text) == "function" then text = text(c, unit) end
    local spell = N[key] or ""
    ShowSuggestion(key, rule.cat, (text and text ~= "" and (text .. "\n|cffaaaaaa" .. spell .. "|r")) or spell)
end

-- Rede de seguranca: se alguma API nova devolver algo inesperado, o addon so
-- esconde o icone neste ciclo em vez de gerar erro de Lua a cada 0,1s.
local lastError
local function Update()
    if not DB or not DB.enabled then hud:Hide(); return end
    if GetTime() < testUntil then return end
    local ok, err = pcall(DoUpdate)
    if not ok then
        lastError = err
        hud:Hide()
    end
end

---------------------------------------------------------------------------
-- 10. EVENTOS E COMANDOS
---------------------------------------------------------------------------
-- O log de combate (COMBAT_LOG_EVENT_UNFILTERED) NAO e usado: no Forever ele e
-- proibido para addons e gera o aviso "so disponivel para a interface da Blizzard".
local core = CreateFrame("Frame")
local elapsed = 0

core:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed >= UPDATE_INTERVAL then
        elapsed = 0
        Update()
    end
end)

local function RefreshSpells()
    ResolveNames()
    ScanSpellbook()
    ResolveRankIDs()
    RebuildKeyCache()
end

core:RegisterEvent("ADDON_LOADED")
core:RegisterEvent("PLAYER_LOGIN")
core:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        MVAT_DB = MVAT_DB or {}
        for k, v in pairs(DEFAULTS) do if MVAT_DB[k] == nil then MVAT_DB[k] = v end end
        DB = MVAT_DB
        core:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        ApplyLayout()
        RefreshSpells()
        LoadClassRules()
        for _, e in ipairs({ "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB", "PLAYER_LEVEL_UP", "CHARACTER_POINTS_CHANGED",
                             "ACTIONBAR_SLOT_CHANGED", "UPDATE_BINDINGS", "UPDATE_SHAPESHIFT_FORM",
                             "UPDATE_BONUS_ACTIONBAR", "PLAYER_TARGET_CHANGED" }) do
            if not C_EventUtils or not C_EventUtils.IsEventValid or C_EventUtils.IsEventValid(e) then
                core:RegisterEvent(e)
            end
        end
        -- casts apenas do alvo atual (reacao instantanea a interrupts)
        for _, e in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START" }) do
            if not C_EventUtils or not C_EventUtils.IsEventValid or C_EventUtils.IsEventValid(e) then
                core:RegisterUnitEvent(e, "target")
            end
        end
        print("|cff33ccffMVAT|r carregado para " .. (UnitClass("player")) .. ". Digite |cffffff00/mvat|r para opcoes.")
    elseif event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" or event == "PLAYER_LEVEL_UP"
        or event == "CHARACTER_POINTS_CHANGED" then
        RefreshSpells()
        LoadClassRules()
    elseif event == "ACTIONBAR_SLOT_CHANGED" or event == "UPDATE_BINDINGS"
        or event == "UPDATE_SHAPESHIFT_FORM" or event == "UPDATE_BONUS_ACTIONBAR" then
        RebuildKeyCache()
    elseif event == "PLAYER_TARGET_CHANGED"
        or event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        elapsed = UPDATE_INTERVAL -- reavalia imediatamente
    end
end)

local function Msg(text) print("|cff33ccffMVAT|r " .. text) end

local function Slash(input)
    local cmd, arg = (input or ""):lower():match("^(%S*)%s*(.-)$")
    if cmd == "unlock" or cmd == "destravar" then
        DB.locked = false; ApplyLayout(); HideSuggestion(); Msg("Destravado: arraste o icone. Use /mvat lock para travar.")
    elseif cmd == "lock" or cmd == "travar" then
        DB.locked = true; ApplyLayout(); hud:Hide(); Msg("Travado e posicao salva.")
    elseif cmd == "" then
        DB.locked = not DB.locked; ApplyLayout()
        if DB.locked then hud:Hide() else HideSuggestion() end
        Msg(DB.locked and "Travado." or "Destravado: arraste o icone.")
        Msg("Comandos: lock | unlock | scale <0.5-3> | aoe <n> | combat | text | test | reset | on | off")
    elseif cmd == "scale" or cmd == "escala" then
        local v = tonumber(arg)
        if v and v >= 0.5 and v <= 3 then DB.scale = v; ApplyLayout(); Msg("Escala: " .. v)
        else Msg("Use: /mvat scale 1.2  (entre 0.5 e 3)") end
    elseif cmd == "aoe" or cmd == "area" then
        local v = tonumber(arg)
        if v and v >= 2 and v <= 10 then DB.aoe = math.floor(v); Msg("Modo area a partir de " .. DB.aoe .. " inimigos.")
        else Msg("Use: /mvat aoe 3  (entre 2 e 10)") end
    elseif cmd == "combat" or cmd == "combate" then
        DB.combatOnly = not DB.combatOnly; Msg(DB.combatOnly and "Mostrando so em combate." or "Mostrando tambem fora de combate (buffs).")
    elseif cmd == "text" or cmd == "texto" then
        DB.showText = not DB.showText; ApplyLayout(); Msg(DB.showText and "Texto de motivo ligado." or "Texto de motivo desligado.")
    elseif cmd == "reset" then
        for k, v in pairs(DEFAULTS) do DB[k] = v end
        ApplyLayout(); Msg("Posicao e opcoes restauradas.")
    elseif cmd == "on" then DB.enabled = true; Msg("Ativado.")
    elseif cmd == "off" then DB.enabled = false; hud:Hide(); Msg("Desativado.")
    elseif cmd == "test" or cmd == "teste" then
        local key
        for k in pairs(ID) do if Known(k) then key = k; break end end
        if key then
            testUntil = GetTime() + 5
            ShowSuggestion(key, "COMBO", "Teste do HUD (5s)\n|cffaaaaaa" .. N[key] .. "|r")
        else Msg("Nenhuma habilidade conhecida encontrada.") end
    elseif cmd == "debug" then
        local count = 0
        for _, rule in ipairs(rules) do for _, k in ipairs(rule.pick) do if Known(k) then count = count + 1 end end end
        Msg(string.format("Classe %s | %d regras | %d habilidades aprendidas usadas | inimigos %s",
            tostring(playerClass), #rules, count, tostring(c.enemies)))
    elseif cmd == "diag" then
        local function yn(v) return v and "|cffff5555SECRETO|r" or "|cff55ff55liberado|r" end
        local function should(fn)
            if not (C_Secrets and C_Secrets[fn]) then return "n/d" end
            local ok, v = pcall(C_Secrets[fn])
            if not ok or issecret(v) then return "?" end
            return tostring(v)
        end
        local _, build, _, iface = GetBuildInfo()
        Msg("Diagnostico (build " .. tostring(build) .. ", interface " .. tostring(iface) .. ")")
        Msg("Agora: auras=" .. should("ShouldAurasBeSecret") .. " recargas=" .. should("ShouldCooldownsBeSecret")
            .. " | leitura de auras " .. yn(AurasRestricted()))
        if combatSnap.seen then
            Msg("Ultimo combate: vida " .. yn(not combatSnap.hp) .. " | recurso " .. yn(not combatSnap.power)
                .. " | auras proprias " .. yn(combatSnap.auraP) .. " | auras do alvo " .. yn(combatSnap.auraT))
            Msg("Sugestoes mostradas no ultimo combate: " .. combatSnap.shown)
        else
            Msg("Entre em combate uma vez e rode /mvat diag de novo.")
        end
        Msg("Ultimo erro capturado: " .. (lastError and tostring(lastError) or "nenhum"))
        lastError = nil -- o proximo diag mostra so erros novos
    else
        Msg("Comandos: lock | unlock | scale <0.5-3> | aoe <n> | combat | text | test | reset | on | off | debug | diag")
    end
end

SLASH_MVAT1, SLASH_MVAT2 = "/mvat", "/tutor"
SlashCmdList.MVAT = Slash
