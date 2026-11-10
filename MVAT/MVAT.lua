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
    textSize = 12,       -- tamanho da letra do texto abaixo do icone (independente da escala)
    locked = true,
    enabled = true,
    combatOnly = false,  -- true = so mostra em combate
    aoe = 3,             -- n. de inimigos para considerar "area / farm"
    showText = true,     -- mostra o motivo da sugestao abaixo do icone
    barOnly = true,      -- so sugere habilidades que estao nas suas barras de acao
    seal = "auto",       -- Paladino: "auto" escolhe o selo pelo contexto; ou fixe um selo
    purge = true,        -- painel "LIMPAR": debuffs do grupo que a sua classe consegue remover
    ecasts = true,       -- painel de casts de OUTROS inimigos (chefe, elites, quem mira em voce)
    pos = false,         -- posicoes salvas dos paineis de aviso: DB.pos[id] = { x, y }
    roles = false,       -- papel por classe: DB.roles[CLASSE] = "auto" | "dps" | "tank" | "heal"
    opts = false,        -- preferencias por classe: DB.opts[CLASSE][chave] = valor
    queue = true,        -- mostra "DEPOIS": as proximas habilidades disponiveis ao lado do icone
    minimap = true,      -- botao do addon na borda do minimapa
    minimapAngle = 215,  -- posicao do botao em volta do minimapa (graus)
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

-- Recarga. Em combate o Forever esconde inicio/duracao, mas "isActive" e
-- "isOnGCD" continuam LIMPOS (mesma leitura que o EllesmereUI usa no FocusKick).
-- Retorna start, duration, active, onGCD (active/onGCD = nil quando desconhecidos).
-- Recarga totalmente desconhecida conta como pronta: o jogo ainda impede o uso.
local function SpellCooldown(spell)
    if C_Spell and C_Spell.GetSpellCooldown then
        local cd = C_Spell.GetSpellCooldown(spell)
        if cd then
            return Pub(cd.startTime) or 0, Pub(cd.duration) or 0, Pub(cd.isActive), Pub(cd.isOnGCD)
        end
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
            if name and fn(name, Pub(a.dispelName), Pub(a.sourceUnit), Pub(a.expirationTime), Pub(a.applications), Pub(a.duration)) then
                return true
            end
        end
    else
        for i = 1, 40 do
            local ok, name, _, count, dtype, _, expiration, source = pcall(UnitAura, unit, i, filter)
            if not ok then return false end
            if name == nil then return true end
            name = Pub(name)
            if name and fn(name, Pub(dtype), Pub(source), Pub(expiration), Pub(count), nil) then return true end
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
    -- extras de papeis/opcoes (IDs do Classic/TBC; so valem se o Forever os mantiver - senao ficam inativos)
    ASPECT_CHEETAH = 5118, ASPECT_BEAST = 13161, ASPECT_PACK = 13159,
    MOLTEN_ARMOR = 30482, WATER_SHIELD = 24398, CONC_AURA = 19746, SANCT_AURA = 20218, FIRE_RES_AURA = 19891,
    RIGHTEOUS_DEFENSE = 31789, POWER_INFUSION = 10060, RIPTIDE = 61295, WILD_GROWTH = 48438, MANGLE = 33878,
    DEFENSIVE_STANCE = 71, LIFEBLOOM = 33763,
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
    HOLY_STRIKE = 679, SEAL_FURY = 1311649, HOLY_WRATH = 2812, TURN_UNDEAD = 2878,
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
    NS_SHAMAN = 16188, ELEM_MASTERY = 16166,
    -- Druida
    BASH = 5211, FERAL_CHARGE = 16979, REMOVE_CURSE = 2782, CURE_POISON_D = 8946,
    ABOLISH_POISON = 2893, BARKSKIN = 22812, FRENZIED = 22842, MOONFIRE = 8921, WRATH = 5176,
    STARFIRE = 2912, INSECT_SWARM = 5570, REJUV = 774, REGROWTH = 8936, HEALING_TOUCH = 5185,
    SWIFTMEND = 18562, MOTW = 1126, THORNS = 467, BEAR = 5487, DIRE_BEAR = 9634, CAT = 768,
    CLAW = 1082, RAKE = 1822, RIP = 1079, BITE = 22568, SHRED = 5221, MAUL = 6807,
    SWIPE = 779, DEMO_ROAR = 99, GROWL = 6795, HURRICANE = 16914, DRUID_CLEARCAST = 16870,
    TIGERS_FURY = 5217, FAERIE_FIRE = 770, FAERIE_FIRE_FERAL = 16857, NS_DRUID = 17116,
    -- Habilidades novas/trocadas do Forever (IDs do treinador)
    CHARGE = 100, VICTORY_RUSH = 402927, SLAM = 1464, BLOODRAGE = 2687, HAMSTRING = 1715, RECKLESSNESS = 1719,
    RETALIATION = 20230, INTERCEPT = 20616, BACKSTAB = 53, AMBUSH = 8676, GARROTE = 703, CHEAP_SHOT = 1833,
    RUPTURE = 1943, FEINT = 1966, MUTILATE = 1241582, ARCANE_BLAST = 1239696, ICE_LANCE = 400640,
    FROSTFIRE = 401502, BLAST_WAVE = 13018, FLAMESTRIKE = 2120, PENANCE = 1240720, PRAYER_OF_MENDING = 1240826,
    SW_DEATH = 1309595, HOLY_NOVA = 15430, BINDING_HEAL = 401937, PRAYER_OF_HEALING = 596,
    DEVOURING_PLAGUE = 2944, COUNTERATTACK = 20909, CONFLAGRATE = 17962, SEARING_PAIN = 5676, SOUL_FIRE = 6353,
    INCINERATE = 1293812, SIPHON_LIFE = 18879, FEAR = 5782, LACERATE = 414644, POUNCE = 9005, RAVAGE = 6785,
    FIRE_NOVA = 408341,
}

-- IDs alternativos (todos os ranks do treinador do Forever) para achar a habilidade mesmo se o ID principal
-- nao existir no cliente. Gerado a partir dos dados do WhatsTraining (Camelot) e do ForeverAuras.
local ALT = {
    CHARGE = {100, 6178, 11578},
    VICTORY_RUSH = {402927},
    SLAM = {1464, 8820, 11604, 11605, 1240193},
    BLOODRAGE = {2687},
    HAMSTRING = {1715, 7372, 7373},
    RECKLESSNESS = {1719},
    RETALIATION = {20230},
    INTERCEPT = {20616, 20617},
    BACKSTAB = {53, 2589, 2590, 2591, 8721, 11279, 11280, 11281},
    AMBUSH = {8676, 8724, 8725, 11267, 11268, 11269},
    GARROTE = {703, 8631, 8632, 8633, 11289, 11290},
    CHEAP_SHOT = {1833},
    RUPTURE = {1943, 8639, 8640, 11273, 11274, 11275},
    FEINT = {1966, 6768, 8637, 11303},
    MUTILATE = {1241582, 1241584},
    ARCANE_BLAST = {1239696, 1239697, 1239699, 1239700},
    ICE_LANCE = {400640, 1240044, 1240045, 1240046, 1240047},
    FROSTFIRE = {401502, 1237312, 1237313},
    BLAST_WAVE = {13018, 13019, 13020, 13021},
    FLAMESTRIKE = {2120, 2121, 8422, 8423, 10215, 10216},
    PENANCE = {1240720, 1240721, 1316995},
    PRAYER_OF_MENDING = {1240826, 1240827},
    SW_DEATH = {1309595, 1309633, 1309635, 1309636},
    HOLY_NOVA = {15430, 15431, 27799, 27800, 27801},
    BINDING_HEAL = {401937, 402837, 1240770, 1240771, 1240772, 1240773, 1240774},
    PRAYER_OF_HEALING = {596, 996, 10960, 10961},
    DEVOURING_PLAGUE = {2944, 19276, 19277, 19278, 19279, 19280},
    COUNTERATTACK = {20909, 20910, 1242634},
    CONFLAGRATE = {17962, 18930, 18931, 18932, 1293818},
    SEARING_PAIN = {5676, 17919, 17920, 17921, 17922, 17923},
    SOUL_FIRE = {6353, 17924},
    INCINERATE = {1293812, 1293813},
    SIPHON_LIFE = {18879, 18880, 18881},
    FEAR = {5782, 6213, 6215},
    LACERATE = {414644, 1235826, 1235827},
    POUNCE = {9005, 9823, 9827},
    RAVAGE = {6785, 6787, 9866, 9867},
    FIRE_NOVA = {408341, 408342, 408343, 408344, 408345},
    ABOLISH_POISON = {2893},
    AIMED = {19434, 20900, 20901, 20902, 20903, 20904},
    ARCANE_EXPLOSION = {1449, 8437, 8438, 8439, 10201, 10202},
    ARCANE_INTELLECT = {1459, 1460, 1461, 10156, 10157},
    ARCANE_MISSILES = {5143, 5144, 5145, 8416, 8417, 10211, 10212},
    ARCANE_SHOT = {3044, 14281, 14282, 14283, 14284, 14285, 14286, 14287},
    BARKSKIN = {22812},
    BASH = {5211, 6798, 8983},
    BATTLE_SHOUT = {6673, 5242, 6192, 11549, 11550, 11551},
    BITE = {22568, 22827, 22828, 22829},
    BLIZZARD = {10, 6141, 8427, 10185, 10186, 10187},
    BLOODTHIRST = {23892, 23893, 23894},
    BOK = {20217},
    BOM = {19740, 19834, 19835, 19836, 19837, 19838},
    BOP = {1022, 5599, 10278},
    BOW = {19742, 19850, 19852, 19853, 19854},
    CHAIN_HEAL = {1064, 10622, 10623},
    CHAIN_LIGHTNING = {421, 930, 2860, 10605},
    CLAW = {3029, 5201, 9849, 9850},
    CLEANSE = {4987},
    CLEAVE = {845, 7369, 11608, 11609, 20569},
    COA = {980, 1014, 6217, 11711, 11712, 11713},
    CONCUSSIVE = {5116},
    CONE_OF_COLD = {120, 8492, 10159, 10160, 10161},
    CONSECRATION = {26573, 20116, 20922, 20923, 20924},
    COR = {704, 7658, 7659, 11717},
    CORRUPTION = {172, 6222, 6223, 7648, 11671, 11672},
    COT = {1714, 11719},
    COUNTERSPELL = {2139},
    COW = {702, 1108, 6205, 7646, 11707, 11708},
    CURE_DISEASE_P = {528},
    CURE_DISEASE_S = {2870},
    CURE_POISON_S = {526},
    DEATH_COIL = {6789, 17925, 17926},
    DEMON_ARMOR = {706, 1086, 11733, 11734, 11735},
    DEMON_SKIN = {696},
    DEMO_ROAR = {99, 1735, 9490, 9747, 9898},
    DEMO_SHOUT = {1160, 6190, 11554, 11555, 11556},
    DESPERATE_PRAYER = {19236, 19238, 19240, 19241, 19242, 19243},
    DEVOTION = {465, 10290, 643, 10291, 1032, 10292, 10293},
    DIRE_BEAR = {9634},
    DISENGAGE = {781, 14272, 14273},
    DISPEL_MAGIC = {527, 988},
    DIVINE_PROT = {498, 5573},
    DIVINE_SHIELD = {642, 1020},
    DRAIN_LIFE = {689, 699, 709, 7651, 11699, 11700},
    DRAIN_SOUL = {1120, 8288, 8289, 11675},
    EARTH_SHOCK = {8042, 8044, 8045, 8046, 10412, 10413, 10414},
    EVASION = {5277},
    EVISCERATE = {6760, 6761, 6762, 8623, 8624, 11299, 11300},
    EVOCATION = {12051},
    EXECUTE = {5308, 20658, 20660, 20661, 20662},
    EXORCISM = {879, 5614, 5615, 10312, 10313, 10314},
    FADE = {586, 9578, 9579, 9592, 10941, 10942},
    FAERIE_FIRE = {770, 778, 9749, 9907},
    FIREBALL = {143, 145, 3140, 8400, 8401, 8402, 10148, 10149, 10150, 10151},
    FIRE_BLAST = {2136, 2137, 2138, 8412, 8413, 10197, 10199},
    FLAMETONGUE = {8024, 8027, 8030, 16339, 16341, 16342},
    FLAME_SHOCK = {8050, 8052, 8053, 10447, 10448},
    FLASH_HEAL = {2061, 9472, 9473, 9474, 10915, 10916, 10917},
    FOL = {19750, 19939, 19940, 19941, 19942, 19943},
    FRENZIED = {22842},
    FROSTBOLT = {116, 205, 837, 7322, 8406, 8407, 8408, 10179, 10180, 10181},
    FROST_ARMOR = {7300, 7301},
    FROST_NOVA = {122, 865, 6131, 10230},
    FROST_SHOCK = {8056, 8058, 10472, 10473},
    GOUGE = {1776, 1777, 8629, 11285, 11286},
    GREATER_HEAL = {2060, 10963, 10964, 10965},
    GROUNDING = {8177},
    HAWK = {13165, 14318, 14319, 14320, 14321, 14322},
    HEAL = {2054, 2055, 6063, 6064},
    HEALING_TOUCH = {5186, 5187, 5188, 5189, 6778, 8903, 9758, 9888, 9889},
    HEALING_WAVE = {332, 547, 913, 939, 959, 8005, 10395, 10396},
    HELLFIRE = {1949, 11683, 11684},
    HEROIC_STRIKE = {284, 285, 1608, 11564, 11565, 11566, 11567},
    HOJ = {853, 5588, 5589, 10308},
    HOLY_FIRE = {14914, 15262, 15263, 15264, 15265, 15266, 15267, 15261},
    HOLY_LIGHT = {639, 647, 1026, 1042, 3472, 10328, 10329},
    HOLY_SHIELD = {20927, 20928},
    HOLY_SHOCK = {20473, 20929, 20930},
    HOLY_STRIKE = {679, 678, 1866, 680, 2495, 5569, 10332, 10333},
    HOLY_WRATH = {2812, 10318},
    HOW = {24275, 24274, 24239},
    HOWL = {5484, 17928},
    HURRICANE = {16914, 17401, 17402},
    ICE_ARMOR = {7302, 7320, 10219, 10220},
    ICE_BARRIER = {13031, 13032, 13033},
    IMMOLATE = {348, 707, 1094, 2941, 11665, 11667, 11668},
    INNER_FIRE = {588, 7128, 602, 1006, 10951, 10952},
    INSECT_SWARM = {24974, 24975, 24976, 24977},
    INTIM_SHOUT = {5246},
    JUDGEMENT = {20271},
    KICK = {1766, 1767, 1768, 1769},
    KIDNEY = {408, 8643},
    LESSER_HEAL = {2052, 2053},
    LHW = {8004, 8008, 8010, 10466, 10467, 10468},
    LIFE_TAP = {1454, 1455, 1456, 11687, 11688, 11689},
    LIGHTNING_BOLT = {529, 548, 915, 943, 6041, 10391, 10392, 15207, 15208},
    LIGHTNING_SHIELD = {324, 325, 905, 945, 8134, 10431, 10432},
    LOH = {633, 2800, 10310},
    MAGE_ARMOR = {6117, 22782, 22783},
    MAGMA = {8190, 10585, 10586, 10587},
    MANA_SHIELD = {1463, 8494, 8495, 10191, 10192, 10193},
    MARK = {1130, 14323, 14324, 14325},
    MAUL = {6808, 6809, 8972, 9745, 9880, 9881},
    MEND_PET = {136, 3111, 3661, 3662, 13542, 13543, 13544},
    MIND_BLAST = {8092, 8102, 8103, 8104, 8105, 8106, 10945, 10946, 10947},
    MIND_FLAY = {17311, 17312, 17313, 17314, 18807},
    MONGOOSE = {1495, 14269, 14270, 14271},
    MOONFIRE = {8921, 8924, 8925, 8926, 8927, 8928, 8929, 9833, 9834, 9835},
    MORTAL_STRIKE = {21551, 21552, 21553},
    MOTW = {1126, 5232, 6756, 5234, 8907, 9884, 9885},
    MULTI = {2643},
    OVERPOWER = {7384, 7887, 11584, 11585},
    PSYCHIC_SCREAM = {8122, 8124, 10888, 10890},
    PUMMEL = {6552, 6554},
    PURGE = {370, 8012},
    PURIFY = {1152},
    PW_FORT = {1243, 1244, 1245, 2791, 10937, 10938},
    PW_SHIELD = {17, 592, 600, 3747, 6065, 6066, 10898, 10899, 10900, 10901},
    PYROBLAST = {12505, 12522, 12523, 12524, 12525, 12526, 18809},
    RAIN_OF_FIRE = {5740, 6219, 11677, 11678},
    RAKE = {1822, 1823, 1824, 9904},
    RAPID_FIRE = {3045},
    RAPTOR = {14260, 14261, 14262, 14263, 14264, 14265, 14266},
    REGROWTH = {8936, 8938, 8939, 8940, 8941, 9750, 9856, 9857, 9858},
    REJUV = {774, 1058, 1430, 2090, 2091, 3627, 8910, 9839, 9840, 9841},
    REMOVE_CURSE = {2782},
    REMOVE_LESSER_CURSE = {475},
    REND = {772, 6546, 6547, 6548, 11572, 11573, 11574},
    RENEW = {139, 6074, 6075, 6076, 6077, 6078, 10927, 10928, 10929},
    RET_AURA = {7294, 10298, 10299, 10300, 10301},
    REVENGE = {6572, 6574, 7379, 11600, 11601},
    RIGHTEOUS_FURY = {25780},
    RIP = {9492, 9493, 9752, 9894, 9896},
    ROCKBITER = {8017, 8018, 8019, 10399, 16314, 16315, 16316},
    SCORCH = {2948, 8444, 8445, 8446, 10205, 10206, 10207},
    SEAL_FURY = {1311649, 1311656, 20163, 20419, 20421, 20422, 20423},
    SEARING = {6363, 6364, 6365, 10437, 10438},
    SERPENT = {1978, 13549, 13550, 13551, 13552, 13553, 13554, 13555},
    SHADOWBURN = {18867, 18868, 18869, 18870, 18871},
    SHADOW_BOLT = {695, 705, 1088, 1106, 7641, 11659, 11660, 11661},
    SHIELD_BASH = {72, 1671, 1672},
    SHIELD_BLOCK = {2565},
    SHIELD_SLAM = {23923, 23924, 23925},
    SHIELD_WALL = {871},
    SHRED = {5221, 6800, 8992, 9829, 9830},
    SINISTER = {1757, 1758, 1759, 1760, 8621, 11293, 11294},
    SMITE = {591, 598, 984, 1004, 6060, 10933, 10934},
    SND = {5171, 6774},
    SOC = {20915, 20918, 20919, 20920},
    SOL = {20165, 20347, 20348, 20349},
    SOR = {20287, 20288, 20289, 20290, 20291, 20292, 20293},
    SOTC = {21082, 20162, 20305, 20306, 20307, 20308},
    SOW = {20166, 20356, 20357},
    STARFIRE = {2912, 8949, 8950, 8951, 9875, 9876},
    SUNDER = {7405, 8380, 11596, 11597},
    SWIPE = {779, 780, 769, 9754, 9908},
    SWP = {589, 594, 970, 992, 2767, 10892, 10893, 10894},
    THORNS = {467, 782, 1075, 8914, 9756, 9910},
    THUNDER_CLAP = {6343, 8198, 8204, 8205, 11580, 11581},
    TURN_UNDEAD = {2878, 5627, 10326},
    VANISH = {1856, 1857},
    VOLLEY = {1510, 14294, 14295},
    WHIRLWIND = {1680},
    WINDFURY = {8232, 8235, 10486, 16362},
    WING_CLIP = {2974, 14267, 14268},
    WRATH = {5177, 5178, 5179, 5180, 6780, 8905, 9912},
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

-- Habilidades que estao nas SUAS barras (por nome localizado). So faz sentido
-- sugerir o que voce consegue apertar; com as barras vazias o filtro e ignorado.
local barNames, barCount = {}, 0
local function OnBar(name)
    return not DB or not DB.barOnly or barCount == 0 or barNames[name] == true
end

-- Resolve o nome localizado de cada habilidade pelo ID principal e, se o cliente
-- nao o conhecer, pelos IDs alternativos (ranks do treinador do Forever).
local function ResolveNames()
    for key, id in pairs(ID) do
        local name, icon = SpellInfo(id)
        if not name and ALT[key] then
            for _, alt in ipairs(ALT[key]) do
                name, icon = SpellInfo(alt)
                if name then break end
            end
        end
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
-- Habilidades reativas (so ficam disponiveis apos esquiva/aparo/alvo < 20%).
-- Sem confirmacao de "usavel" elas nunca sao sugeridas pela regra comum; o
-- brilho de proc da Blizzard continua sugerindo-as quando acendem.
local REACTIVE = { EXECUTE = true, OVERPOWER = true, REVENGE = true, RIPOSTE = true,
                   MONGOOSE = true, HOW = true, VICTORY_RUSH = true, COUNTERATTACK = true, CONFLAGRATE = true }

local function Ready(key, unit)
    local name = N[key]
    if not name or not known[name] then return false end
    if not OnBar(name) then return false end
    local usable = SpellUsable(name)
    if usable == false then return false end
    if usable == nil and REACTIVE[key] then return false end
    local start, duration, active, onGCD = SpellCooldown(name)
    if active == true and onGCD ~= true then return false end  -- em recarga (limpo)
    if start > 0 and duration > 1.6 and (start + duration - GetTime()) > 0.25 then return false end
    if unit and unit ~= "player" and UnitExists(unit) and SpellInRange(name, unit) == false then
        return false
    end
    return true
end

-- So a recarga (sem exigir "usavel"/alcance): usada pelos alertas de cast.
local function OffCooldown(key)
    local name = N[key]
    if not name or not known[name] then return false end
    if not OnBar(name) then return false end
    local start, duration, active, onGCD = SpellCooldown(name)
    if active == true and onGCD ~= true then return false end
    if start > 0 and duration > 1.6 and (start + duration - GetTime()) > 0.25 then return false end
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
    wipe(barNames)
    barCount = 0
    for slot = 1, 120 do
        if Is(HasAction(slot)) then
            local name = SlotSpellName(slot)
            if name then
                if not barNames[name] then barNames[name] = true; barCount = barCount + 1 end
                if not keyCache[name] then
                    local key = KeyForSlot(slot)
                    if key then keyCache[name] = key end
                end
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
local auraDur = {}                   -- [nome] = duracao total observada (ex.: duracao real do selo)

-- CONTEXTO DO PERSONAGEM (equipamento) e do ALVO, lidos fora de combate, quando os
-- valores ainda sao legiveis, e guardados. Em combate o jogo os esconde.
local gear = { shield = false, twoHand = false, speed = 2.0 }
local tcache = {}                    -- tipo/classificacao do alvo atual (limpo ao trocar de alvo)

local function RefreshGear()
    local function itemInfo(slot)
        local id = GetInventoryItemID("player", slot)
        if type(id) ~= "number" then return nil end
        local f = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
        if not f then return nil end
        local ok, _, _, _, loc, _, classID, subID = pcall(f, id)
        if not ok then return nil end
        return loc, classID, subID
    end
    local mainLoc, mainClass, mainSub = itemInfo(16)
    gear.twoHand = mainLoc == "INVTYPE_2HWEAPON"
    gear.dagger = mainClass == 2 and mainSub == 15     -- adaga: Furtividade/Esfaquear funcionam melhor
    gear.shield = (itemInfo(17)) == "INVTYPE_SHIELD"
    local sp = UnitAttackSpeed and Pub((UnitAttackSpeed("player")))
    if type(sp) == "number" and sp > 0 then gear.speed = sp end
end

local function CollectAuras(unit, filter, store, mineOnly, tag)
    wipe(store)
    if not UnitExists(unit) then return end
    local now = GetTime()
    local readable = ForEachAura(unit, filter, function(name, _, source, expiration, _, duration)
        if not mineOnly or source == "player" or source == "pet" then
            local remain = (expiration and expiration > 0) and (expiration - now) or 999
            if not store[name] or store[name] < remain then store[name] = remain end
            if duration and duration > 0 then auraDur[name] = duration end
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
    -- issecret antes de qualquer comparacao: comparar um valor secreto gera erro
    local name, _, _, _, endMS, _, _, notInt = UnitCastingInfo("target")
    if not issecret(name) and name == nil then
        name, _, _, _, endMS, _, notInt = UnitChannelInfo("target")
    end
    if not issecret(name) and name == nil then return nil end
    local cast = c.castData
    cast.name = Pub(name) or "feitico do inimigo"
    endMS = Pub(endMS)
    cast.remaining = endMS and (endMS / 1000 - GetTime()) or 1
    cast.unknownInt = issecret(notInt)   -- se secreto, o painel de cast decide so pela transparencia
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
local CREATURE_DEMON  = { ["Demon"] = true, ["Demônio"] = true, ["Demonio"] = true }
local CREATURE_HUMANOID = { ["Humanoid"] = true, ["Humanoide"] = true }

-- SELO ATIVO. Fora de combate vem das auras (exato). Em combate o jogo esconde as
-- auras, entao vale o estado rastreado: o selo que VOCE lancou + a duracao real
-- observada (sealDur). No Forever o Julgamento nao consome mais o selo.
local SEAL_KEYS = { "SEAL_FURY", "SOC", "SOR", "SOTC", "SOJ", "SOL", "SOW" }
local sealState = { key = nil, expires = 0 }
local lastCast = { key = nil, t = 0, at = {}, self = {}, cp = 0,
    -- pontos de combo: cada gerador soma, cada finalizador zera (GetComboPoints fica secreto em combate)
    cpb = { SINISTER = 1, BACKSTAB = 1, AMBUSH = 1, GARROTE = 1, CHEAP_SHOT = 1, GOUGE = 1, MUTILATE = 2,
            CLAW = 1, RAKE = 1, SHRED = 1, POUNCE = 1, RAVAGE = 1 },
    cpf = { EVISCERATE = 1, SND = 1, RUPTURE = 1, KIDNEY = 1, RIP = 1, BITE = 1 },
    -- duracao dos DoTs (s): as sequencias so mandam reaplicar se o DoT ja caiu
    dur = { CORRUPTION = 14, IMMOLATE = 12, SERPENT = 12, MOONFIRE = 10, INSECT_SWARM = 11, RAKE = 8, SWP = 16,
            FLAME_SHOCK = 10, REND = 12, RIP = 9, COA = 22, SIPHON_LIFE = 26 } }   -- ultima skill sua e o instante de cada uma (DoTs sem auras)
local sealDur = 30

local function UpdateSealFromAuras()
    if auraSecret.player then return end
    local now, found = GetTime(), nil
    for _, k in ipairs(SEAL_KEYS) do
        local n = N[k]
        if n and playerBuffs[n] then
            found = k
            sealState.expires = now + playerBuffs[n]
            if auraDur[n] then sealDur = auraDur[n] end
            break
        end
    end
    sealState.key = found
    if not found then sealState.expires = 0 end
end

local function BuildContext()
    c.now = GetTime()
    c.inCombat = UnitAffectingCombat("player")
    -- Valores desconhecidos (secretos) recebem um padrao "neutro" que nao
    -- dispara regras: vida 100%, recurso 0, mana 100%.
    c.hp = UnitPct("player") or 100
    c.hpKnown = UnitPct("player") ~= nil
    local maxPow, pow = Pub(UnitPowerMax("player")), Pub(UnitPower("player"))
    c.power = pow or 0
    c.powerKnown = pow ~= nil          -- false em combate no Forever: as regras assumem que ha recurso
    c.powerPct = (pow and maxPow and maxPow > 0) and (pow / maxPow * 100) or 0
    local maxMana, mana = Pub(UnitPowerMax("player", 0)), Pub(UnitPower("player", 0))
    c.manaPct = (mana and maxMana and maxMana > 0) and (mana / maxMana * 100) or 100
    c.cp = Pub(GetComboPoints("player", "target")) or lastCast.cp or 0
    c.grouped = Is(IsInGroup())
    c.stealth = Is(IsStealthed and IsStealthed())

    c.target = UnitExists("target")
    -- Se o jogo esconder se o alvo e atacavel, em combate assumimos que o alvo
    -- e o inimigo (o jogo recusa a habilidade se nao for).
    local atk = _G.UnitCanAttack("player", "target")
    c.hostileSecret = c.target and issecret(atk)
    if c.hostileSecret then c.hostile = c.inCombat and not UnitIsDead("target")
    else c.hostile = c.target and atk and not UnitIsDead("target") end
    c.thp = c.target and UnitPct("target") or 100
    -- tipo/classificacao do alvo: lidos quando legiveis (ao selecionar o alvo, fora de
    -- combate) e guardados em tcache; em combate o jogo os esconde.
    if c.target then
        local cls = Pub(UnitClassification("target"))
        if cls then tcache.elite = (cls == "elite" or cls == "worldboss" or cls == "rareelite") end
        if Pub(UnitLevel("target")) == -1 then tcache.elite = true end
        local ct = Pub(UnitCreatureType("target"))
        if ct then tcache.ctype = ct end
    end
    c.elite = c.target and tcache.elite or false
    c.melee = c.hostile and Near("target")
    local ctype = c.target and tcache.ctype or nil
    c.ctype = ctype
    c.undeadOrDemon = ctype and (CREATURE_UNDEAD[ctype] or CREATURE_DEMON[ctype]) or false
    c.humanoid = ctype and CREATURE_HUMANOID[ctype] or false
    c.threat = (c.hostile and UnitThreatSituation and Pub(UnitThreatSituation("player", "target"))) or 0
    c.targetOnAlly = c.hostile and UnitExists("targettarget") and not UnitIsUnit("targettarget", "player")
                     and UnitInMyGroup("targettarget")

    CollectAuras("player", "HELPFUL", playerBuffs, false, "player")
    CollectAuras("player", "HARMFUL", playerDebuffs)
    CollectAuras("target", "HARMFUL", targetMine, true, "target")
    CollectAuras("target", "HARMFUL", targetAny)
    UpdateSealFromAuras()

    c.castData = c.castData or {}
    -- isolados com pcall: se o jogo bloquear um deles, o resto (procs) segue funcionando
    local okCast, cast = pcall(ReadTargetCast)
    c.cast = okCast and cast or nil
    local okEn, en, near = pcall(CountEnemies)
    c.enemies, c.near = okEn and en or 0, okEn and near or 0
    c.aoe = c.enemies >= DB.aoe
    c.meleeAoe = c.near >= DB.aoe

    if c.inCombat and not c.prevCombat then c.combatStart = c.now end
    if c.inCombat ~= c.prevCombat then lastGroupScan = 0 end -- rescan na entrada/saida de combate
    c.prevCombat = c.inCombat
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
    if not N[key] then return true end   -- feitico inexistente neste cliente: nao pode estar ativo
    if auraSecret.player then return PlayerAuraByID(RANKID[key] or ID[key]) == false end
    return not playerBuffs[N[key]]
end
local function NotOnTarget(key) return not auraSecret.target and not OnTarget(key) end
local function NotOnTargetAny(key) return not auraSecret.target and not OnTargetAny(key) end
-- DoT/debuff meu no alvo ausente? Com auras legiveis: exato. Em combate (auras secretas): pelo
-- tempo desde que EU o lancei (dur = duracao em segundos). Zera ao trocar de alvo.
local function DotDown(key, dur)
    if not N[key] then return false end
    if not auraSecret.target then return not OnTarget(key) end
    local t = lastCast.at[key]
    return t == nil or (GetTime() - t) > dur
end
-- Buff meu em mim ausente? Auras legiveis: exato. Auras secretas: pela consulta por Spell ID
-- e, se ela tambem for bloqueada, pelo tempo desde que EU o lancei (dur em segundos).
local function BuffDown(key, dur)
    if not N[key] then return false end
    if not auraSecret.player then return not playerBuffs[N[key]] end
    local r = PlayerAuraByID(RANKID[key] or ID[key])
    if r ~= nil then return r == false end
    local t = lastCast.self[key]
    return t == nil or (GetTime() - t) > dur
end
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

-- pick pode ser: "CHAVE", { "CHAVE1", "CHAVE2" } ou uma funcao(c) que devolve a lista
-- (escolha dinamica, ex.: qual selo usar conforme o alvo e a arma).
local function R(cat, pick, when, msg, unit)
    local pickFn
    if type(pick) == "string" then pick = { pick }
    elseif type(pick) == "function" then pickFn, pick = pick, {} end
    return { cat = cat, pick = pick, pickFn = pickFn, when = when, msg = msg, unit = unit }
end

local function UnitLabel(unit)
    if not unit or unit == "player" then return "voce" end
    return Pub(UnitName(unit)) or "aliado"
end

-- Interrupcao: alvo hostil castando algo interrompivel
local function Interrupt(pick)
    return R("INTERRUPT", pick, function(c)
        return c.cast and c.cast.interruptible and not c.cast.unknownInt and c.cast.remaining > 0.15
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
-- 6b. PAPEIS (dano / tank / cura) E OPCOES POR CLASSE
---------------------------------------------------------------------------
-- Papel = o que voce faz no grupo. Fica "auto" (detectado pelos pontos de talento) ou escolhido
-- na janela de opcoes (/mvat). Em cada papel o addon mostra so o que faz sentido:
--   cura: HoTs/curas de recarga, limpar debuff do grupo, buffs  (sem habilidades de dano)
--   tank: ameaca, provocar, defesas, selo/postura/forma de tank
--   dano: rotacao e combos (sem curas de aliado)
-- Classes so de dano (Mago, Ladino, Cacador, Bruxo) nao filtram nada.
local extra = { purgeScans = 0, purgeHits = 0, purgeErr = nil, ecasts = 0, ecastErr = nil, purgeFound = nil, purgeAt = 0 }
local RL = {}
-- papel de cada arvore de talentos (1,2,3). "feral" = tank se estiver de urso, senao dano.
RL.TABS = {
    PRIEST = { "heal", "heal", "dps" }, PALADIN = { "heal", "tank", "dps" },
    SHAMAN = { "dps", "dps", "heal" }, DRUID = { "dps", "feral", "heal" }, WARRIOR = { "dps", "dps", "tank" },
}

function RL.detect()
    RL.detected = nil
    local map = RL.TABS[select(2, UnitClass("player"))]
    if not map or not _G.GetTalentTabInfo then return end
    local best, bestPts, total = nil, -1, 0
    for tab = 1, 3 do
        local ok, _, _, a, _, b = pcall(_G.GetTalentTabInfo, tab)   -- Classic: nome, icone, pontos
        local pts = ok and ((type(a) == "number" and a) or (type(b) == "number" and b)) or nil
        if pts then
            total = total + pts
            if pts > bestPts then best, bestPts = tab, pts end
        end
    end
    if total > 0 and best then RL.detected = map[best] end
end

-- papel efetivo: escolhido por voce > detectado > nil (nao filtra nada)
function RL.role()
    local cls = select(2, UnitClass("player"))
    if not RL.TABS[cls] then return nil end
    local r = DB and DB.roles and DB.roles[cls]
    if r and r ~= "auto" then return r end
    local d = RL.detected
    if d == "feral" then return InForm("BEAR", "DIRE_BEAR") and "tank" or "dps" end
    return d
end

function RL.allow(rule, role)
    if not role or rule.proc then return true end
    local tag = rule.role
    if tag then
        if type(tag) == "table" then return tag[role] == true end
        return tag == role
    end
    local cat = rule.cat
    local friend = RL.friend()          -- alvo aliado selecionado = voce quer curar
    if role == "heal" then
        -- curandeiro tambem ataca (grind, mobs): com INIMIGO no alvo mostra a rotacao de dano;
        -- com aliado no alvo (ou sem alvo) mostra so cura/limpeza/buffs
        if cat == "ROTATION" or cat == "AOE" or cat == "COMBO" then return (c.hostile and not friend) and true or false end
        return true
    end
    -- dano/tank: sem curas de aliado, a menos que voce tenha escolhido um aliado como alvo
    return cat ~= "HEAL" or friend
end

-- marca uma regra para um papel ("heal", "tank", "dps" ou { tank = true, dps = true })
local function Role(role, rule) rule.role = role; return rule end

-- opcao por classe (DB.opts[CLASSE][chave]); "auto"/vazio = padrao
function RL.opt(key, default)
    local o = DB and DB.opts and DB.opts[select(2, UnitClass("player"))]
    local v = o and o[key]
    if v == nil or v == "auto" then return default end
    return v
end

-- DISPELS no Forever (nivel em que cada classe aprende a remover cada tipo de debuff).
-- Fonte: dados do treinador do WhatsTraining (Camelot), nov/2026. { chave da habilidade, nivel }.
-- Ex.: o Paladino remove Veneno/Doenca com Purificar (nv 8) mas Magia so com Cleanse (nv 42).
RL.DISPEL = {
    PALADIN = { Poison = { "PURIFY", 8 }, Disease = { "PURIFY", 8 }, Magic = { "CLEANSE", 42 } },
    PRIEST  = { Magic = { "DISPEL_MAGIC", 18 }, Disease = { "CURE_DISEASE_P", 14 } },
    DRUID   = { Curse = { "REMOVE_CURSE", 24 }, Poison = { "ABOLISH_POISON", 26 } },
    SHAMAN  = { Poison = { "CURE_POISON_S", 16 }, Disease = { "CURE_DISEASE_S", 22 } },
    MAGE    = { Curse = { "REMOVE_LESSER_CURSE", 18 } },
}

-- alvo selecionado e amigo? (curas "no alvo")
function RL.friend()
    return UnitExists("target") and Is(_G.UnitIsFriend and _G.UnitIsFriend("player", "target"))
end

-- HoT/buff MEU no alvo amigo esta faltando? Auras legiveis: exato. Em combate (auras
-- secretas): pelo tempo desde o MEU ultimo cast nele (zera ao trocar de alvo).
function RL.hotMissing(key, dur)
    if not N[key] then return false end
    local has = UnitHasAura("target", key, "HELPFUL")
    if has ~= nil then return has == false end
    local t = lastCast.at[key]
    return t == nil or (GetTime() - t) > dur
end

-- Cura no ALVO amigo selecionado. Com a vida legivel so sugere abaixo de "below"%; com a vida
-- oculta (combate) sugere sempre, porque quem escolheu um aliado como alvo quer curar.
function RL.targetHeal(pick, below, extra)
    return R("HEAL", pick, function(c)
        if not RL.friend() or (extra and not extra(c)) then return false end
        local p = UnitPct("target")
        return p == nil or p < below
    end, function()
        local p = UnitPct("target")
        return "Cure " .. UnitLabel("target") .. (p and string.format(" (%d%%)", math.floor(p)) or "")
    end, "target")
end

-- limpar debuff de quem esta mais a mao (usa a varredura do painel LIMPAR: funciona em combate)
function RL.purgeRule()
    return R("DISPEL", function()
        local f = extra.purgeFound
        return f and extra.purgeSpells and extra.purgeSpells(f.typeName) or {}
    end, function() return extra.purgeFound ~= nil and GetTime() - extra.purgeAt < 1.0 end,
    function()
        local f = extra.purgeFound
        return "Limpar " .. ((f and f.name) or "aliado") .. ": tem um debuff que voce remove"
    end,
    function() local f = extra.purgeFound; return f and f.unit end)
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
        Role("tank", R("BUFF", "DEFENSIVE_STANCE", function(c) return not tank() end,
            "Papel tank: troque para a Postura Defensiva", "player")),
        SelfBuff("BATTLE_SHOUT", nil, true),
        Hit("COMBO", "CHARGE", function(c) return not c.inCombat end, "Abertura: Investida"),
        Hit("COMBO", "VICTORY_RUSH", nil, "Vitoria Rapida: cura 10% da vida (ate 20s apos matar)"),
        R("COMBO", "BLOODRAGE", function(c) return c.inCombat and c.hp > 60 and (c.now - (c.combatStart or c.now)) < 8 end,
            "Inicio da luta: Ira Sangrenta (gera Raiva)", "player"),
        Hit("COMBO", "EXECUTE", nil, "Alvo < 20%: Executar!"),
        Hit("COMBO", "OVERPOWER", nil, "Alvo esquivou: Sobrepujar!"),
        Hit("COMBO", "REVENGE", nil, "Bloqueio/Esquiva: Revanche!"),
        R("AOE", "SWEEPING", function(c) return c.inCombat and c.meleeAoe end, "Varios mobs: ative Golpes Amplos"),
        Hit("AOE", "WHIRLWIND", function(c) return c.near >= 2 end,
            function() return Buff("SWEEPING") and "COMBO Golpes Amplos -> Redemoinho" or "Varios mobs: Redemoinho" end),
        Hit("AOE", "THUNDER_CLAP", function(c) return c.meleeAoe and DotDown("THUNDER_CLAP", 18) end, "Area: Trovoada"),
        Hit("AOE", "DEMO_SHOUT", function(c) return c.meleeAoe and DotDown("DEMO_SHOUT", 25) end, "Area: Grito Desmoralizante"),
        Hit("AOE", "CLEAVE", function(c) return c.near >= 2 and (not c.powerKnown or c.power >= 40) end, "Raiva sobrando: Cutilada"),
        Hit("ROTATION", "SHIELD_SLAM", nil, "Golpe de Escudo"),
        Hit("ROTATION", { "BLOODTHIRST", "MORTAL_STRIKE" }, nil, "Golpe principal"),
        Hit("ROTATION", "SLAM", nil, "Golpe Poderoso (recarga 15s)"),
        R("ROTATION", "RECKLESSNESS", function(c) return c.hostile and c.inCombat and c.elite end, "Elite/chefe: Temeridade", "player"),
        Hit("ROTATION", "SUNDER", function(c) return tank() and DotDown("SUNDER", 25) end, "Gere ameaca: Fender Armadura"),
        Hit("ROTATION", "REND", function(c) return c.thp > 30 and DotDown("REND", 12) end, "Aplique Dilacerar"),
        Hit("ROTATION", "HEROIC_STRIKE", function(c) return not c.powerKnown or c.power >= 50 end, "Raiva alta: Golpe Heroico"),
    }
end

CLASS_RULES.ROGUE = function()
    return {
        Emergency("VANISH", 15, nil, "Quase morto: Sumir"),
        Emergency("EVASION", 50, function(c) return c.threat >= 2 or not c.grouped end, "Apanhando: Evasao"),
        Interrupt("KICK"),
        Interrupt("GOUGE"),
        Hit("INTERRUPT", "KIDNEY", function(c) return c.cast and not c.cast.unknownInt and c.cp >= 1 end, "Sem Chute: Golpe nos Rins"),
        R("AOE", "BLADE_FLURRY", function(c) return c.inCombat and c.near >= 2 end, "Varios mobs: Rajada de Laminas"),
        Hit("COMBO", function()
            local o = RL.opt("opener", nil)     -- abertura escolhida na janela
            if o == "ambush" then return { "AMBUSH", "CHEAP_SHOT", "GARROTE" }
            elseif o == "cheap" then return { "CHEAP_SHOT", "AMBUSH", "GARROTE" }
            elseif o == "garrote" then return { "GARROTE", "CHEAP_SHOT", "AMBUSH" } end
            return gear.dagger and { "AMBUSH", "CHEAP_SHOT", "GARROTE" } or { "CHEAP_SHOT", "GARROTE", "AMBUSH" }
        end,
            function(c) return c.stealth and not c.inCombat end, "Furtivo: abertura (Emboscada exige adaga)"),
        Hit("COMBO", "RIPOSTE", nil, "Aparou! Ripostar"),
        Hit("COMBO", "SND", function(c) return c.cp >= 2 and BuffDown("SND", 24) and c.thp > 25 end,
            "Pontos de combo: ative Picar"),
        Hit("COMBO", "RUPTURE", function(c) return c.cp >= 4 and c.elite and DotDown("RUPTURE", 12) end, "Elite: Ruptura (sangramento)"),
        Hit("COMBO", "EVISCERATE", function(c) return c.cp >= 5 or (c.cp >= 2 and c.thp < 15) end,
            function(c) return c.cp .. " pontos: Eviscerar!" end),
        R("ROTATION", "ADRENALINE", function(c) return c.inCombat and c.elite end, "Elite/chefe: Adrenalina"),
        Hit("ROTATION", function()
            local facingMe = UnitExists("targettarget") and UnitIsUnit("targettarget", "player")
            if gear.dagger and not facingMe then return { "BACKSTAB", "SINISTER" } end
            return { "SINISTER", "BACKSTAB" }
        end, nil, "Gere pontos: Esfaquear (por tras, adaga) / Golpe Sinistro"),
    }
end

CLASS_RULES.MAGE = function()
    local function filler()
        local o = RL.opt("spell", nil)      -- opcao: magia principal escolhida na janela
        if o == "arcane" then return { "ARCANE_BLAST", "FROSTBOLT", "FIREBALL" }
        elseif o == "fire" then return { "FIREBALL", "FROSTBOLT" }
        elseif o == "frost" then return { "FROSTBOLT", "FIREBALL" } end
        if Known("ARCANE_BLAST") then return { "ARCANE_BLAST", "FROSTBOLT", "FIREBALL" } end   -- especializacao Arcana
        if Known("PYROBLAST") or Known("COMBUSTION") or not Known("FROSTBOLT") then return { "FIREBALL", "FROSTBOLT" } end
        return { "FROSTBOLT", "FIREBALL" }
    end
    local fill = filler       -- funcao: reavalia a cada ciclo (respeita a opcao e o que voce aprendeu)
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
        R("AOE", "FROST_NOVA", function(c) return c.inCombat and c.meleeAoe and DotDown("FROST_NOVA", 8) end, "FARM: Nova Congelante -> Explosao Arcana"),
        R("AOE", "BLAST_WAVE", function(c) return c.meleeAoe and c.hostile end, "Mobs colados: Onda Explosiva (dano + lentidao)"),
        R("AOE", "CONE_OF_COLD", function(c) return c.meleeAoe and c.hostile end, "Area: Cone de Gelo"),
        R("AOE", "ARCANE_EXPLOSION", function(c) return c.meleeAoe end, "Mobs agrupados: Explosao Arcana"),
        R("AOE", "BLIZZARD", function(c) return c.enemies >= DB.aoe + 1 and not c.meleeAoe end, "Mobs a distancia: Nevasca"),
        Hit("ROTATION", "PYROBLAST", function(c) return not c.inCombat end, "Abertura: Piroblasto"),
        Hit("ROTATION", "FIRE_BLAST", function(c) return c.thp < 30 or c.melee end, "Instantaneo: Impacto de Fogo"),
        Hit("ROTATION", fill, nil, "Dano principal"),
        SelfBuff("ARCANE_INTELLECT"),
        SelfBuff(function()
            local o = RL.opt("armor", nil)
            if o == "ice" then return { "ICE_ARMOR", "FROST_ARMOR" }
            elseif o == "mage" then return { "MAGE_ARMOR" }
            elseif o == "molten" then return { "MOLTEN_ARMOR" } end
            return { "MAGE_ARMOR", "ICE_ARMOR", "FROST_ARMOR", "MOLTEN_ARMOR" }
        end, { "MAGE_ARMOR", "ICE_ARMOR", "FROST_ARMOR", "MOLTEN_ARMOR" }),
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
        Role("heal", R("COMBO", { "GREATER_HEAL", "HEAL" }, function(c, u) return Buff("INNER_FOCUS") and u and c.lowestPct < 70 end,
            "COMBO Foco Interior -> cura grande gratis", function(c) return c.lowest end)),
        HealLowest("PENANCE", 55),
        HealLowest({ "GREATER_HEAL", "HEAL", "LESSER_HEAL" }, 60),
        HealLowest("RENEW", 85, function(c, u) return UnitLacksAura(u, "RENEW", "HELPFUL") end),
        -- CURA com alvo amigo selecionado: mantenha Renovar (em combate pelo tempo desde o seu ultimo cast)
        Role("heal", R("HEAL", "RENEW", function(c)
            return RL.friend() and RL.hotMissing("RENEW", 15)
        end, function() return "Mantenha Renovar em " .. UnitLabel("target") .. " (cura ao longo do tempo)" end, "target")),
        Role("heal", R("HEAL", "PW_SHIELD", function(c)
            return RL.friend() and c.inCombat and canShield(c, "target")
        end, function() return "Escudo em " .. UnitLabel("target") .. " (absorve dano)" end, "target")),
        RL.targetHeal({ "FLASH_HEAL", "HEAL", "LESSER_HEAL" }, 50),
        RL.targetHeal({ "GREATER_HEAL", "HEAL", "LESSER_HEAL" }, 90),
        -- CURA em combate (vida do grupo oculta): cooldowns do guia do Forever
        Role("heal", R("HEAL", "PENANCE", function(c) return c.inCombat and c.grouped end,
            "Penance (recarga 12s): cure o aliado mais ferido")),
        Role("heal", R("COMBO", "INNER_FOCUS", function(c) return c.inCombat and c.grouped end,
            "Prepare: Foco Interior (a proxima cura grande sai de graca)", "player")),
        Role("heal", R("COMBO", "POWER_INFUSION", function(c) return c.inCombat and c.elite end,
            "Elite/chefe: Poder Infundido (curas mais rapidas)", "player")),
        R("HEAL", "PRAYER_OF_MENDING", function(c) return c.grouped and c.inCombat and (not c.target or (not c.hostileSecret and not c.hostile)) end,
            "Prayer of Mending (10s): jogue no tanque ou aliado"),
        Hit("COMBO", "MIND_BLAST", function() return Buff("INNER_FOCUS") end, "COMBO Foco Interior -> Explosao Mental"),
        Role("dps", SelfBuff("SHADOWFORM", nil, true)),
        R("AOE", "HOLY_NOVA", function(c) return c.meleeAoe and c.manaPct > 30 end, "Varios inimigos colados: Nova Sagrada"),
        Hit("ROTATION", "SWP", function(c) return DotDown("SWP", 16) and c.thp > 20 end, "Aplique Palavra Sombria: Dor"),
        Hit("ROTATION", "HOLY_FIRE", function(c) return not c.inCombat end, "Abertura: Fogo Sagrado"),
        Hit("ROTATION", "MIND_BLAST", nil, "Explosao Mental"),
        Hit("ROTATION", "PENANCE", nil, "Penance (12s): dano Sagrado no inimigo"),
        Hit("ROTATION", "SW_DEATH", function(c) return c.hpKnown and c.hp >= 60 end, "Shadow Word: Death (18s): tira 30% da sua vida se o alvo sobreviver"),
        Hit("ROTATION", { "MIND_FLAY", "SMITE" }, nil, "Dano continuo"),
        SelfBuff("PW_FORT"),
        SelfBuff("INNER_FIRE"),
    }
end

-- Nomes aceitos em /mvat selo <nome>
local SEAL_PREF = {
    auto = "auto",
    fury = "SEAL_FURY", furia = "SEAL_FURY",
    righteousness = "SOR", retidao = "SOR",
    crusader = "SOTC", cruzado = "SOTC",
    command = "SOC", comando = "SOC",
    light = "SOL", luz = "SOL",
    wisdom = "SOW", sabedoria = "SOW",
    justice = "SOJ", justica = "SOJ",
}
local paladin = {}   -- exposto para /mvat debug

-- PALADINO (regras do WoW Forever, segundo as notas de mudancas dos proprios addons):
--  * Selo da Furia e "o selo de tanque": cada golpe soma dano Sagrado e, com escudo, um absorvedor.
--  * O Julgamento NAO consome mais o selo (recarga 10s, alcance 10m); julgar a Furia provoca o alvo.
--  * Golpe Sagrado: golpe base do Ret, recarga 10s (arma + dano Sagrado).
CLASS_RULES.PALADIN = function()
    -- modo tank: papel escolhido manda; em "auto" vale escudo equipado ou Furia Justa ativa
    local function tankMode()
        local r = RL.role()
        if r == "tank" then return true elseif r == "dps" or r == "heal" then return false end
        return gear.shield or Buff("RIGHTEOUS_FURY")
    end

    -- segundos restantes do selo (auras fora de combate; rastreio por casts em combate)
    local function sealLeft()
        if not sealState.key then return nil end
        local left = sealState.expires - GetTime()
        return left > 0 and left or nil
    end

    local function ok(k) return Known(k) and OnBar(N[k]) end

    -- Escolhe o melhor selo ENTRE OS QUE VOCE TEM e estao na sua barra.
    local function chooseSeal(c)
        local pref = DB.seal and DB.seal ~= "auto" and SEAL_PREF[DB.seal]
        if pref and pref ~= "auto" and ok(pref) then
            return pref, "fixado por voce (/mvat selo auto desfaz)"
        end
        if ok("SEAL_FURY") and tankMode() then
            return "SEAL_FURY", gear.shield and "escudo equipado: o selo de tanque (dano + absorcao)"
                or "Furia Justa ativa: o selo de tanque"
        end
        -- Selo da Justica (impede a fuga) nao e escolhido sozinho: metade dos mobs sao
        -- humanoides e custaria dano. Use /mvat selo justica quando um alvo ficar fugindo.
        if ok("SOW") and c.manaPct < 35 then
            return "SOW", "mana baixa: Sabedoria devolve mana"
        end
        if ok("SOC") and (gear.twoHand or gear.speed >= 2.6) then
            return "SOC", "arma lenta/duas maos: o Comando bate mais forte"
        end
        if ok("SOR") then
            return "SOR", string.format("dano confiavel para a sua arma (%.1fs)", gear.speed)
        end
        if ok("SOC") then return "SOC", "melhor selo de dano disponivel" end
        for _, k in ipairs({ "SOTC", "SEAL_FURY", "SOL", "SOW", "SOJ" }) do
            if ok(k) then return k, "unico selo disponivel na sua barra" end
        end
    end
    paladin.choose, paladin.tankMode, paladin.sealLeft = chooseSeal, tankMode, sealLeft

    local function sealPicks(c) return c.sealPick and { c.sealPick } or {} end

    return {
        Emergency("DIVINE_SHIELD", 20, nil, "Quase morto: Escudo Divino"),
        Emergency("LOH", 12, nil, "Ultimo recurso: Imposicao das Maos"),
        Emergency("DIVINE_PROT", 25),
        R("EMERGENCY", "BOP", function(c, u) return c.inCombat and u and u ~= "player" and c.lowestPct < 20 end,
            function(c) return "Salve " .. UnitLabel(c.lowest) .. ": Bencao de Protecao" end, function(c) return c.lowest end),
        Interrupt("HOJ"),
        -- TANK (Protecao): provocar, cooldown grande e ameaca
        Role("tank", Taunt("RIGHTEOUS_DEFENSE", function() return true end)),
        Role("tank", R("DEFENSIVE", "TEMPLARS_BULWARK", function(c) return c.inCombat and (c.elite or c.near >= 3) end,
            "Elite/varios mobs: Templar's Bulwark (absorve 100% da vida por 8s)", "player")),
        Dispel({ "CLEANSE", "PURIFY" }, { "Poison", "Disease" }),
        Dispel("CLEANSE", { "Magic" }),
        HealLowest("HOLY_SHOCK", 50),
        HealLowest("HOLY_LIGHT", 45),
        HealLowest("FOL", 75),
        -- CURA (Sagrado): em combate a vida do grupo e secreta, entao guia pelas curas de recarga
        -- e pela ordem do guia do Forever: Holy Shock -> Flash of Light / Holy Light (Infusion of Light acende como proc)
        Role("heal", R("HEAL", "HOLY_SHOCK", function(c) return c.inCombat and c.grouped end,
            "Holy Shock (recarga curta): use em um aliado ferido - depois Flash of Light / Holy Light")),
        RL.targetHeal("HOLY_SHOCK", 90),
        RL.targetHeal({ "FOL", "HOLY_LIGHT" }, 90),
        -- 1) sem selo (ou acabando): aplica o melhor selo para o contexto
        R("COMBO", sealPicks, function(c)
            if not (c.hostile or c.inCombat) then return false end
            local k, why = chooseSeal(c)
            c.sealPick, c.sealWhy = k, why
            if not k then return false end
            local left = sealLeft()
            return left == nil or (left < 3 and c.inCombat)
        end, function(c)
            local nm = N[c.sealPick] or ""
            if sealLeft() then return "Renove o selo (" .. nm .. "): " .. c.sealWhy end
            return "Sem selo - " .. nm .. ": " .. c.sealWhy
        end, "player"),
        -- 2) antes da luta, com outro selo ativo: sugere trocar se o contexto pede outro
        R("COMBO", sealPicks, function(c)
            if c.inCombat or not c.hostile then return false end
            local k, why = chooseSeal(c)
            c.sealPick, c.sealWhy = k, why
            return k ~= nil and sealState.key ~= nil and sealState.key ~= k
        end, function(c) return "Troque para " .. (N[c.sealPick] or "") .. ": " .. c.sealWhy end, "player"),
        -- 3) Julgamento (nao gasta o selo no Forever) e Golpe Sagrado, ambos com recarga de 10s
        Hit("COMBO", "JUDGEMENT", function() return sealLeft() ~= nil end, function()
            return "Julgamento: nao gasta o selo (recarga 10s)" .. (sealState.key == "SEAL_FURY" and " - provoca o alvo" or "")
        end),
        Hit("ROTATION", "HOLY_STRIKE", nil, "Golpe Sagrado (recarga 10s): arma + dano Sagrado"),
        Hit("COMBO", "HOW", nil, "Alvo < 20%: Martelo da Colera"),
        R("AOE", "CONSECRATION", function(c)
            return (c.meleeAoe or (tankMode() and c.enemies >= 2)) and c.manaPct > 30
        end, "Varios mobs: Consagracao"),
        R("ROTATION", "HOLY_SHIELD", function(c) return c.inCombat and tankMode() and Lacks("HOLY_SHIELD") end, "Tanque: Escudo Sagrado"),
        Hit("ROTATION", "EXORCISM", function(c) return c.undeadOrDemon end, "Morto-vivo/Demonio: Exorcismo"),
        Hit("ROTATION", "HOLY_WRATH", function(c) return c.undeadOrDemon and c.enemies >= 2 end, "Varios mortos-vivos/demonios: Colera Sagrada"),
        R("BUFF", "RIGHTEOUS_FURY", function(c) return not c.inCombat and gear.shield and Lacks("RIGHTEOUS_FURY") end,
            "Escudo equipado: ative Furia Justa (ameaca de tanque)", "player"),
        R("BUFF", function()
            local AURA = { devotion = "DEVOTION", retribution = "RET_AURA", concentration = "CONC_AURA", sanctity = "SANCT_AURA", fireres = "FIRE_RES_AURA" }
            local o = AURA[RL.opt("aura", "")]
            if o then return { o } end
            return tankMode() and { "DEVOTION", "RET_AURA" } or { "RET_AURA", "DEVOTION" }
        end,
            function(c)
                return not c.inCombat and Lacks("DEVOTION") and Lacks("RET_AURA") and Lacks("CONC_AURA")
                    and Lacks("SANCT_AURA") and Lacks("FIRE_RES_AURA")
            end,
            function() return RL.opt("aura", nil) and "Aura ausente (a que voce escolheu)"
                or (tankMode() and "Aura ausente: Devocao (tanque)" or "Aura ausente: Retribuicao (dano)") end, "player"),
        R("BUFF", { "BOK", "BOM", "BOW" }, function(c)
            return not c.inCombat and Lacks("BOK") and Lacks("BOM") and Lacks("BOW")
        end, "Bencao ausente", "player"),
    }
end

CLASS_RULES.HUNTER = function()
    return {
        R("EMERGENCY", "FEIGN", function(c) return c.inCombat and c.grouped and c.threat >= 2 and c.hp < 60 end, "Aggro em voce: Fingir de Morto"),
        Emergency("DETERRENCE", 35, function(c) return c.melee end, "Apanhando corpo a corpo: Dissuasao"),
        R("HEAL", "MEND_PET", function(c) return c.inCombat and c.petHp < 40 end, "Pet morrendo: Curar Ajudante", "pet"),
        Hit("INTERRUPT", "SCATTER", function(c) return c.cast and c.cast.interruptible and not c.cast.unknownInt end, function(c) return "Interrompa: " .. c.cast.name end),
        R("BUFF", function()
            local M = { hawk = "HAWK", monkey = "MONKEY", cheetah = "ASPECT_CHEETAH", beast = "ASPECT_BEAST", pack = "ASPECT_PACK" }
            return { M[RL.opt("aspect", "")] or "HAWK" }
        end, function(c)
            local o = RL.opt("aspect", nil)
            if not o and not (c.hostile and not c.melee) then return false end    -- auto: so a distancia
            return Lacks("HAWK") and Lacks("MONKEY") and Lacks("ASPECT_CHEETAH") and Lacks("ASPECT_BEAST") and Lacks("ASPECT_PACK")
        end, function() return RL.opt("aspect", nil) and "Aspecto ausente (o que voce escolheu)" or "Combate a distancia: Aspecto do Falcao" end, "player"),
        Hit("COMBO", "MONGOOSE", function(c) return c.melee end, "Alvo esquivou: Mordida do Mangusto"),
        Hit("COMBO", "COUNTERATTACK", function(c) return c.melee end, "Aparou! Contra-ataque"),
        Hit("ROTATION", "WING_CLIP", function(c) return c.melee and DotDown("WING_CLIP", 7) and not c.grouped end, "Colado: Cortar Asas e afaste-se"),
        Hit("ROTATION", "RAPTOR", function(c) return c.melee end, "Corpo a corpo: Golpe do Raptor"),
        Hit("ROTATION", "MARK", function(c) return DotDown("MARK", 100) and (c.elite or c.thp > 60) end, "Marque o alvo"),
        Hit("AOE", { "VOLLEY", "MULTI" }, function(c) return c.aoe end, "Varios mobs: dano em area"),
        R("ROTATION", "RAPID_FIRE", function(c) return c.hostile and c.inCombat and c.elite end, "Elite/chefe: Disparo Rapido"),
        Hit("ROTATION", "SERPENT", function(c) return DotDown("SERPENT", 12) and c.thp > 30 end, "Aplique Picada da Serpente"),
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
        Hit("ROTATION", "SOUL_FIRE", function(c) return not c.inCombat and c.elite end, "Abertura em elite: Fogo da Alma (usa fragmento)"),
        Hit("ROTATION", "COA", function(c) return DotDown("COA", 22) and c.thp > 30 end, "Aplique o Bane da Agonia"),
        Hit("ROTATION", function()
            local o = RL.opt("curse", nil)      -- maldicao de utilidade escolhida na janela
            if o == "elements" then return { "COE" } elseif o == "weakness" then return { "COW" }
            elseif o == "recklessness" then return { "COR" } elseif o == "none" then return {} end
            return { "COE", "COW" }
        end, function(c)
            if RL.opt("curse", nil) == "none" then return false end
            return DotDown("COE", 100) and DotDown("COW", 100) and DotDown("COR", 100) and c.thp > 30
        end, "Aplique uma Maldicao (separada do Bane)"),
        Hit("ROTATION", "CORRUPTION", function(c) return DotDown("CORRUPTION", 14) and c.thp > 20 end, "Aplique Corrupcao"),
        Hit("ROTATION", "SIPHON_LIFE", function(c) return DotDown("SIPHON_LIFE", 26) and c.thp > 30 end, "Aplique Dreno de Vida (cura voce)"),
        Hit("ROTATION", "IMMOLATE", function(c) return DotDown("IMMOLATE", 12) and c.thp > 30 end, "Aplique Imolar"),
        Hit("COMBO", "CONFLAGRATE", nil, "Imolar no alvo: Conflagrar"),
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
    -- totem de fogo no chao: lido fora de combate; em combate vale o que VOCE colocou ha pouco
    local function fireTotemUp()
        if GetTotemInfo then
            local has = GetTotemInfo(1)
            if not issecret(has) and (has == true or (type(has) == "number" and has > 0)) then return true end
        end
        local t = lastCast.self.SEARING or lastCast.self.MAGMA
        return t ~= nil and (GetTime() - t) < 30
    end
    return {
        Role("heal", R("EMERGENCY", "NS_SHAMAN", function(c) return c.inCombat and c.lowestPct < 30 end, "Emergencia: Rapidez da Natureza -> Onda Curativa")),
        Role("heal", R("COMBO", "HEALING_WAVE", function(c, u) return Buff("NS_SHAMAN") and u and c.lowestPct < 60 end,
            "COMBO Rapidez da Natureza -> Onda Curativa instantanea", function(c) return c.lowest end)),
        Interrupt("EARTH_SHOCK"),
        R("DEFENSIVE", "GROUNDING", function(c) return c.cast and c.cast.onGroup end, "Feitico vindo: Totem de Aterramento"),
        Dispel("CURE_POISON_S", { "Poison" }),
        Dispel("CURE_DISEASE_S", { "Disease" }),
        HealLowest({ "LHW", "HEALING_WAVE" }, 40),
        HealLowest("CHAIN_HEAL", 75, function(c) return c.injured >= 3 end),
        HealLowest("HEALING_WAVE", 60),
        -- CURA (Restauracao): Riptide e HoT que potencializa a Cura em Cadeia em +25% (guia do Forever)
        Role("heal", R("HEAL", "RIPTIDE", function(c)
            return RL.friend() and RL.hotMissing("RIPTIDE", 12)
        end, function() return "Riptide em " .. UnitLabel("target") .. ": HoT que potencializa a Cura em Cadeia" end, "target")),
        Role("heal", R("HEAL", "RIPTIDE", function(c) return c.inCombat and c.grouped end,
            "Riptide (recarga): HoT em um aliado ferido - depois Cura em Cadeia")),
        Role("heal", R("HEAL", "CHAIN_HEAL", function(c) return c.inCombat and c.grouped and RL.friend() end,
            "Cura em Cadeia no alvo (pula para os feridos ao lado)", "target")),
        RL.targetHeal({ "LHW", "HEALING_WAVE" }, 90),
        Role({ dps = true }, Hit("DISPEL", "PURGE", function() return TargetHasMagicBuff() end, "Inimigo com buff magico: Expurgar")),
        Role({ dps = true }, R("BUFF", { "WINDFURY", "FLAMETONGUE", "ROCKBITER" }, function(c) return weaponMissing() end, "Encante a arma", "player")),
        R("BUFF", function()
            local o = RL.opt("shield", nil)
            if o == "water" or (not o and RL.role() == "heal") then return { "WATER_SHIELD", "LIGHTNING_SHIELD" } end
            return { "LIGHTNING_SHIELD", "WATER_SHIELD" }
        end, function() return Lacks("LIGHTNING_SHIELD") and Lacks("WATER_SHIELD") end, "Escudo elemental ausente", "player"),
        Hit("COMBO", "CHAIN_LIGHTNING", function(c) return (Buff("SHAMAN_CLEARCAST") or Buff("ELEM_MASTERY")) and c.enemies >= 2 end, "COMBO Clarividencia -> Cadeia de Raios"),
        Hit("COMBO", "LIGHTNING_BOLT", function() return Buff("SHAMAN_CLEARCAST") or Buff("ELEM_MASTERY") end, "COMBO Clarividencia -> Raio"),
        R("COMBO", "ELEM_MASTERY", function(c) return c.hostile and c.inCombat and c.elite end, "Elite/chefe: Dominio Elemental"),
        Hit("ROTATION", "STORMSTRIKE", nil, "Ataque de Tempestade"),
        R("AOE", "MAGMA", function(c) return c.meleeAoe and noFireTotem() end, "Varios mobs: totem de fogo em area"),
        Hit("AOE", "FIRE_NOVA", function(c) return c.enemies >= 2 and fireTotemUp() end, "Fire Nova (10s): explode em volta do totem de fogo"),
        Hit("AOE", "CHAIN_LIGHTNING", function(c) return c.enemies >= 2 end, "Varios mobs: Cadeia de Raios"),
        R("ROTATION", "SEARING", function(c) return c.hostile and c.inCombat and noFireTotem() end, "Totem Calcinante"),
        Hit("ROTATION", "FLAME_SHOCK", function(c) return DotDown("FLAME_SHOCK", 10) and c.thp > 30 end, "Aplique Choque Flamejante"),
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
        Role("heal", R("EMERGENCY", "NS_DRUID", function(c) return c.inCombat and c.lowestPct < 30 and caster() end, "Emergencia: Rapidez da Natureza -> Toque de Cura")),
        Role("heal", R("COMBO", "HEALING_TOUCH", function(c, u) return Buff("NS_DRUID") and u and c.lowestPct < 60 end,
            "COMBO Rapidez da Natureza -> Toque de Cura instantaneo", function(c) return c.lowest end)),
        -- TANK (Feral): precisa estar de Urso
        Role("tank", R("BUFF", { "DIRE_BEAR", "BEAR" }, function(c) return not bear() end,
            "Papel tank: entre na Forma de Urso", "player")),
        Interrupt({ "FERAL_CHARGE", "BASH" }),
        Dispel("REMOVE_CURSE", { "Curse" }),
        Dispel({ "ABOLISH_POISON", "CURE_POISON_D" }, { "Poison" }),
        HealLowest("SWIFTMEND", 40, function(c, u) return UnitHasAura(u, "REJUV", "HELPFUL") or UnitHasAura(u, "REGROWTH", "HELPFUL") end),
        HealLowest("REGROWTH", 45, function() return caster() end),
        HealLowest("HEALING_TOUCH", 55, function() return caster() end),
        HealLowest("REJUV", 85, function(c, u) return caster() and UnitLacksAura(u, "REJUV", "HELPFUL") end),
        -- CURA (Restauracao) com alvo amigo selecionado: HoT de base, depois cura direta (guia do Forever)
        Role("heal", R("HEAL", "LIFEBLOOM", function() return caster() and RL.friend() and RL.hotMissing("LIFEBLOOM", 7) end,
            function() return "Mantenha Lifebloom em " .. UnitLabel("target") .. " (HoT do tank)" end, "target")),
        Role("heal", R("HEAL", "REJUV", function() return caster() and RL.friend() and RL.hotMissing("REJUV", 12) end,
            function() return "Mantenha Rejuvenescimento em " .. UnitLabel("target") .. " (HoT de base)" end, "target")),
        Role("heal", R("HEAL", "WILD_GROWTH", function(c) return c.inCombat and c.grouped and caster() end,
            "Wild Growth (recarga): HoT em area no grupo ferido")),
        Role("heal", R("HEAL", "SWIFTMEND", function(c) return c.inCombat and c.grouped and caster() end,
            "Swiftmend (no Forever nao consome o HoT): cura rapida no ferido")),
        Role("heal", R("HEAL", "REGROWTH", function(c) return c.inCombat and caster() and RL.friend() and RL.hotMissing("REGROWTH", 18) end,
            function() return "Regrowth em " .. UnitLabel("target") .. " (cura direta + HoT)" end, "target")),
        RL.targetHeal("REGROWTH", 60, caster),
        RL.targetHeal({ "HEALING_TOUCH", "REGROWTH" }, 90, caster),
        Taunt("GROWL", bear),
        -- Urso (tank)
        Hit("COMBO", "MAUL", function() return bear() and Buff("DRUID_CLEARCAST") end, "COMBO Clarividencia -> Espancar gratis"),
        Hit("AOE", "DEMO_ROAR", function(c) return bear() and c.near >= 2 and NotOnTargetAny("DEMO_ROAR") end, "Area: Rugido Desmoralizante"),
        Hit("AOE", "SWIPE", function(c) return bear() and c.near >= 2 end, "Varios mobs: Golpe Giratorio"),
        Hit("ROTATION", "MANGLE", function(c) return bear() end, "Mangle (urso): golpe principal de ameaca"),
        Hit("ROTATION", "LACERATE", function(c) return bear() and DotDown("LACERATE", 12) end, "Lacerar (sangramento de urso, acumula)"),
        Hit("ROTATION", "MAUL", function(c) return bear() and (not c.powerKnown or c.power >= 15) end, "Espancar"),
        -- Gato (dano)
        Hit("COMBO", { "POUNCE", "RAVAGE" }, function(c) return cat() and c.stealth and not c.inCombat end,
            "Rondar: abertura (Ravage por tras, Pounce atordoa)"),
        Hit("COMBO", "SHRED", function() return cat() and Buff("DRUID_CLEARCAST") end, "COMBO Clarividencia -> Retalhar (por tras)"),
        Hit("COMBO", "RIP", function(c) return cat() and c.cp >= 5 and DotDown("RIP", 9) and c.thp > 40 end, "5 pontos: Rasgar"),
        Hit("COMBO", "BITE", function(c) return cat() and (c.cp >= 5 or (c.cp >= 3 and c.thp < 20)) end, function(c) return c.cp .. " pontos: Mordida Feroz" end),
        R("ROTATION", "TIGERS_FURY", function(c) return cat() and c.hostile and c.inCombat and BuffDown("TIGERS_FURY", 5) and (not c.powerKnown or c.power >= 80) end, "Furia do Tigre"),
        Hit("ROTATION", "RAKE", function(c) return cat() and DotDown("RAKE", 8) end, "Aplique Rasgadura"),
        Hit("ROTATION", "CLAW", function() return cat() end, "Gere pontos: Garra"),
        -- Conjurador / Equilibrio
        Hit("COMBO", "STARFIRE", function() return caster() and Buff("DRUID_CLEARCAST") end, "COMBO Clarividencia -> Fogo Estelar gratis"),
        R("AOE", "HURRICANE", function(c) return caster() and c.enemies >= DB.aoe + 1 end, "Varios mobs: Furacao"),
        Hit("ROTATION", "FAERIE_FIRE", function(c) return caster() and c.elite and DotDown("FAERIE_FIRE", 35) end, "Elite: Fogo Feerico"),
        Hit("ROTATION", "MOONFIRE", function(c) return caster() and DotDown("MOONFIRE", 10) end, "Aplique Fogo Lunar"),
        Hit("ROTATION", "INSECT_SWARM", function(c) return caster() and DotDown("INSECT_SWARM", 11) and c.thp > 30 end, "Aplique Enxame de Insetos"),
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

-- PROCS: o brilho que a propria Blizzard coloca numa habilidade (Sobrepujar,
-- Executar, Revanche, procs de talento...). Os eventos SPELL_ACTIVATION_OVERLAY
-- continuam liberados no Forever, entao esta e a fonte principal em combate.
local glowing = {}   -- [spellID] = true enquanto a Blizzard destaca o feitico
local procSeen = 0   -- procs recebidos no combate atual (para o diag)

local function ProcKey(sid)
    local key = "PROC_" .. sid
    if not N[key] then
        local name, icon = SpellInfo(sid)
        if not name then return nil end
        N[key], ICON[key] = name, icon
    end
    return key
end

local function GlowingProcKey()
    local ISO = C_SpellActivationOverlay and C_SpellActivationOverlay.IsSpellOverlayed
    for sid in pairs(glowing) do
        local key = ProcKey(sid)
        local still = true
        if ISO then
            local ok, on = pcall(ISO, sid)
            if ok and not issecret(on) and not on then still = false end
        end
        if not still then glowing[sid] = nil
        elseif key and Known(key) then return key end
    end
end

local PROC_RULE = { cat = "COMBO", pick = {}, proc = true,
    msg = "Proc ativo! A Blizzard destacou esta habilidade" }

-- COMBOS PELA SUA ULTIMA SKILL. Os seus proprios casts continuam legiveis em
-- combate (UNIT_SPELLCAST_SUCCEEDED do "player"), entao "usei A -> use B" funciona
-- mesmo com auras e buffs escondidos. { de, para, janela(s), mensagem, unidade }
local castSeen, castReadable = 0, 0
local nameToKey

local SEQUENCES = {
    MAGE = {
        { "PRESENCE_OF_MIND", "PYROBLAST", 15, "Presenca da Mente usada: Piroblasto!", "target" },
        { "FROST_NOVA", "ICE_LANCE", 5, "Nova Congelante usada: Ice Lance no alvo congelado", "target" },
        { "FROST_NOVA", "ARCANE_EXPLOSION", 6, "Nova Congelante usada: Explosao Arcana" },
        { "COMBUSTION", { "FIREBALL", "SCORCH" }, 30, "Combustao ativa: continue com fogo", "target" },
    },
    WARRIOR = {
        { "SWEEPING", "WHIRLWIND", 10, "Golpes Amplos usados: Redemoinho", "target" },
        { "THUNDER_CLAP", "DEMO_SHOUT", 5, "Trovoada usada: Grito Desmoralizante" },
    },
    ROGUE = {
        { "GOUGE", "SINISTER", 5, "Inimigo atordoado: ataque seguro", "target" },
        { "VANISH", "SINISTER", 8, "Furtivo: abra com Golpe Sinistro", "target" },
    },
    PRIEST = {
        { "INNER_FOCUS", { "GREATER_HEAL", "HEAL" }, 10, "Foco Interior usado: cura grande gratis", nil, "heal" },
        { "PW_SHIELD", "RENEW", 6, "Escudo usado: Renovar", nil, "heal" },
    },
    PALADIN = {
        { { "SEAL_FURY", "SOC", "SOR", "SOTC", "SOL", "SOW", "SOJ" }, "JUDGEMENT", 28, "Selo ativo: Julgamento (nao gasta o selo)", "target" },
        { "JUDGEMENT", "HOLY_STRIKE", 4, "Julgamento feito: Golpe Sagrado", "target" },
    },
    HUNTER = {
        { "MARK", "SERPENT", 8, "Marca usada: Picada da Serpente", "target" },
        { "SERPENT", "ARCANE_SHOT", 6, "Picada usada: Tiro Arcano", "target" },
    },
    WARLOCK = {
        { { "COA", "COE", "COW", "COR", "COS", "COT" }, "CORRUPTION", 10, "Maldicao usada: Corrupcao", "target" },
        { "CORRUPTION", "IMMOLATE", 10, "Corrupcao usada: Imolar", "target" },
        { "IMMOLATE", "SHADOW_BOLT", 10, "Imolar usado: Seta Sombria", "target" },
    },
    SHAMAN = {
        { "ELEM_MASTERY", { "CHAIN_LIGHTNING", "LIGHTNING_BOLT" }, 15, "Dominio Elemental: raio forte", "target" },
        { "NS_SHAMAN", "HEALING_WAVE", 10, "Rapidez da Natureza: Onda Curativa instantanea", nil, "heal" },
    },
    DRUID = {
        { "NS_DRUID", "HEALING_TOUCH", 10, "Rapidez da Natureza: Toque de Cura instantaneo", nil, "heal" },
        { "FAERIE_FIRE", "MOONFIRE", 8, "Fogo Feerico usado: Fogo Lunar", "target" },
        { "MOONFIRE", "INSECT_SWARM", 8, "Fogo Lunar usado: Enxame de Insetos", "target" },
        { "INSECT_SWARM", "STARFIRE", 10, "Enxame usado: Fogo Estelar", "target" },
    },
}

local function AfterRule(def)
    local from, to, window, msg, unit = def[1], def[2], def[3], def[4], def[5]
    local set = {}
    for _, k in ipairs(type(from) == "table" and from or { from }) do set[k] = true end
    local rule = R("COMBO", to, function()
        if not (lastCast.key and set[lastCast.key] and (GetTime() - lastCast.t) <= window) then return false end
        local d = type(to) == "string" and lastCast.dur[to]
        return not d or DotDown(to, d)
    end, msg, unit)
    rule.role = def[6]     -- sequencias de cura so valem para o papel de cura
    return rule
end

local function OnPlayerCast(sid)
    castSeen = castSeen + 1
    sid = Pub(sid)
    if type(sid) ~= "number" then return end
    castReadable = castReadable + 1
    local name = SpellInfo(sid)
    if not name then return end
    if not nameToKey then
        nameToKey = {}
        for key, n in pairs(N) do
            if not key:find("^PROC_") then nameToKey[n] = key end
        end
    end
    local key = nameToKey[name]
    if key then
        lastCast.key, lastCast.t = key, GetTime()
        lastCast.at[key] = lastCast.t     -- debuffs no alvo (zera ao trocar de alvo)
        lastCast.self[key] = lastCast.t   -- buffs em voce
        if lastCast.cpb[key] then lastCast.cp = math.min(5, lastCast.cp + lastCast.cpb[key])
        elseif lastCast.cpf[key] then lastCast.cp = 0 end
        -- selo lancado por voce: rastreia qual e ate quando (o jogo esconde as auras em combate)
        for _, sk in ipairs(SEAL_KEYS) do
            if key == sk then sealState.key, sealState.expires = key, GetTime() + sealDur end
        end
    end
end

local function LoadClassRules()
    local _, class = UnitClass("player")
    playerClass = class
    local builder = CLASS_RULES[class]
    rules = builder and builder() or {}
    nameToKey = nil
    -- procs e combos por sequencia entram antes de combos/rotacao
    -- (depois de emergencia/interrupt/cura)
    local at = #rules + 1
    for i, rule in ipairs(rules) do
        if rule.cat == "COMBO" or rule.cat == "AOE" or rule.cat == "ROTATION" or rule.cat == "BUFF" then at = i; break end
    end
    table.insert(rules, at, PROC_RULE)
    -- limpar debuff do grupo (filtro nativo, vale em combate) logo depois do proc
    if select(2, UnitClass("player")) ~= "WARRIOR" then table.insert(rules, at + 1, RL.purgeRule()); at = at + 1 end
    for i, def in ipairs(SEQUENCES[class] or {}) do
        table.insert(rules, at + i, AfterRule(def))
    end
end

local function ResolveUnit(rule)
    local u = rule.unit
    if type(u) == "function" then return u(c) end
    return u
end

-- Retorna regra, chave escolhida e unidade da primeira sugestao valida.
-- skip = { [chave] = true } exclui habilidades (usado para montar a fila "depois")
local function Evaluate(skip)
    local role = RL.role()
    for _, rule in ipairs(rules) do
        if RL.allow(rule, role) then
            if rule.proc then
                local key = next(glowing) and GlowingProcKey()
                if key and not (skip and skip[key]) and Ready(key) then return rule, key end
            else
                local unit = ResolveUnit(rule)
                if (unit == nil and not rule.unit) or (unit and UnitExists(unit)) then
                    if not rule.when or rule.when(c, unit) then
                        local picks = rule.pickFn and rule.pickFn(c, unit) or rule.pick
                        for _, key in ipairs(picks) do
                            if not (skip and skip[key]) and Known(key) and Ready(key, unit) then return rule, key, unit end
                        end
                    end
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
do
local grow = hud.pulse:CreateAnimation("Scale")
grow:SetScale(1.18, 1.18); grow:SetDuration(0.10); grow:SetOrder(1)
local shrink = hud.pulse:CreateAnimation("Scale")
shrink:SetScale(1 / 1.18, 1 / 1.18); shrink:SetDuration(0.12); shrink:SetOrder(2)
end

-- Fundo visivel apenas quando destravado (modo de posicionamento)
hud.mover = hud:CreateTexture(nil, "BACKGROUND", nil, -1)
hud.mover:SetPoint("TOPLEFT", -40, 30)
hud.mover:SetPoint("BOTTOMRIGHT", 40, -40)
hud.mover:SetColorTexture(0, 0.6, 1, 0.25)
hud.mover:Hide()

-- Fila "DEPOIS": as proximas habilidades que tambem estao disponiveis agora (ensina a combinacao)
hud.q = {}
hud.qLabel = hud:CreateFontString(nil, "OVERLAY")
hud.qLabel:SetFont(STANDARD_TEXT_FONT, 9, "OUTLINE")
hud.qLabel:SetPoint("BOTTOMLEFT", hud, "RIGHT", 12, 14); hud.qLabel:SetText("DEPOIS"); hud.qLabel:SetTextColor(0.7, 0.7, 0.7)
hud.qLabel:Hide()
for i = 1, 2 do
    local f = CreateFrame("Frame", nil, hud)
    f:SetSize(28, 28)
    f:SetPoint("LEFT", hud, "RIGHT", 12 + (i - 1) * 34, -6)
    f.border = f:CreateTexture(nil, "BACKGROUND")
    f.border:SetPoint("TOPLEFT", -2, 2); f.border:SetPoint("BOTTOMRIGHT", 2, -2); f.border:SetColorTexture(0.55, 0.55, 0.55, 0.9)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints(); f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.key = f:CreateFontString(nil, "OVERLAY")
    f.key:SetFont(STANDARD_TEXT_FONT, 10, "THICKOUTLINE"); f.key:SetPoint("BOTTOMRIGHT", -1, 1)
    f:Hide()
    hud.q[i] = f
end
function hud.setQueue(list)
    local any = false
    for i, f in ipairs(hud.q) do
        local k = list and list[i]
        if k and DB.queue then
            f.icon:SetTexture(ICON[k] or 134400); f.key:SetText(GetKeybind(k)); f:Show(); any = true
        else f:Hide() end
    end
    hud.qLabel:SetShown(any)
end

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
    for _, f in ipairs(hud.panels or {}) do f:SetScale(DB.scale) end
    hud:EnableMouse(not DB.locked)          -- travado = clique atravessa o HUD
    hud.mover:SetShown(not DB.locked)
    -- destravado: o icone vai para a frente (nao fica atras da janela de opcoes) e os
    -- paineis de aviso ganham seus retangulos azuis para arrastar
    hud:SetFrameStrata(DB.locked and "HIGH" or "FULLSCREEN_DIALOG")
    if not DB.locked then hud:SetFrameLevel(40) end
    for _, m in ipairs(hud.movers or {}) do hud.place(m) end
    if hud.lockBar then hud.lockBar:SetShown(not DB.locked) end
    _G.MVAT_ApplyLayout = ApplyLayout   -- usado pelo botao "Travar posicoes"
    local ts = tonumber(DB.textSize) or 12
    hud.reason:SetFont(STANDARD_TEXT_FONT, ts, "OUTLINE")
    hud.reason:SetWidth(math.max(260, 22 * ts))   -- texto maior precisa de linha mais larga
    hud.reason:SetShown(DB.showText)
end

---------------------------------------------------------------------------
-- 9b. PAINEL DE CAST (funciona mesmo com tudo "secreto" em combate)
---------------------------------------------------------------------------
-- O Forever deixa addons MOSTRAR valores secretos (SetTexture, SetText) e
-- controlar a transparencia por um booleano secreto (SetAlphaFromBoolean), mas
-- nao deixa COMPARAR nem decidir com eles. E exatamente assim que o cast bar e o
-- aviso de interrupcao do EllesmereUI funcionam. O painel faz o mesmo:
--   * icone + nome do cast do inimigo  -> SetTexture/SetText (valores secretos)
--   * icone de INTERROMPER             -> transparencia = "cast e interrompivel?"
--   * icone de DEFESA                  -> transparencia = "cast e em mim E nao interrompivel?"
-- O que o codigo decide com dados LIMPOS: o cast existe (type(...) ~= "nil"), a
-- sua habilidade existe e esta fora de recarga (isActive).
-- Filhos de UIParent (nao do HUD): continuam visiveis mesmo se o icone principal estiver oculto.
hud.panels = {}

-- MOVEDORES: cada painel de aviso tem um retangulo azul proprio, arrastavel quando o addon
-- esta destravado, com posicao salva (DB.pos[id]). O painel sempre se ancora no movedor.
-- Sem posicao salva, o movedor fica no lugar padrao, relativo ao icone principal.
hud.movers = {}
function hud.place(m)
    m:ClearAllPoints()
    local p = DB.pos and DB.pos[m.id]
    if p then
        m:SetPoint("CENTER", UIParent, "CENTER", p[1], p[2])
    else
        local s = DB.scale or 1
        m:SetPoint(m.point, m.relTo, m.relPoint, m.dx * s, m.dy * s)
    end
    m.panel:ClearAllPoints()
    m.panel:SetPoint(m.point, m, m.point, 0, 0)
    m:SetShown(not DB.locked)
    m:EnableMouse(not DB.locked)
end
function hud.addMover(id, label, w, h, panel, point, relTo, relPoint, dx, dy)
    local m = CreateFrame("Frame", "MVAT_Mover_" .. id, UIParent)
    m:SetSize(w, h)
    m:SetFrameStrata("FULLSCREEN_DIALOG"); m:SetFrameLevel(40)   -- acima da janela de opcoes
    m:SetClampedToScreen(true); m:SetMovable(true); m:RegisterForDrag("LeftButton")
    m:Hide()
    m.tex = m:CreateTexture(nil, "BACKGROUND")
    m.tex:SetAllPoints(); m.tex:SetColorTexture(0, 0.6, 1, 0.4)
    m.fs = m:CreateFontString(nil, "OVERLAY")
    m.fs:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE"); m.fs:SetPoint("CENTER"); m.fs:SetText(label)
    m.id, m.panel, m.point, m.relTo, m.relPoint, m.dx, m.dy = id, panel, point, relTo, relPoint, dx, dy
    m:SetScript("OnDragStart", function(self) if not DB.locked then self:StartMoving() end end)
    m:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local cx, cy = self:GetCenter()
        local ux, uy = UIParent:GetCenter()
        DB.pos = DB.pos or {}
        DB.pos[self.id] = { cx - ux, cy - uy }
        hud.place(self)
    end)
    hud.movers[#hud.movers + 1] = m
    return m
end

-- Barra do "modo mover": aparece no topo da tela enquanto estiver destravado, com o botao de travar.
hud.lockBar = CreateFrame("Frame", "MVAT_LockBar", UIParent)
do
    local b = hud.lockBar
    b:SetSize(420, 34); b:SetPoint("TOP", UIParent, "TOP", 0, -60)
    b:SetFrameStrata("FULLSCREEN_DIALOG"); b:SetFrameLevel(60)
    b:Hide()
    b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints(); b.bg:SetColorTexture(0, 0, 0, 0.8)
    b.edge = b:CreateTexture(nil, "BORDER")
    b.edge:SetPoint("TOPLEFT", -1, 1); b.edge:SetPoint("BOTTOMRIGHT", 1, -1); b.edge:SetColorTexture(0, 0.6, 1, 0.9)
    b.bg:SetDrawLayer("ARTWORK")
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    b.text:SetPoint("LEFT", 10, 0); b.text:SetText("MVAT: arraste o ícone e os retângulos azuis")
    b.btn = CreateFrame("Button", nil, b)
    b.btn:SetSize(130, 24); b.btn:SetPoint("RIGHT", -6, 0)
    b.btn.bg = b.btn:CreateTexture(nil, "BACKGROUND"); b.btn.bg:SetAllPoints(); b.btn.bg:SetColorTexture(0.1, 0.35, 0.15, 1)
    b.btn.hl = b.btn:CreateTexture(nil, "HIGHLIGHT"); b.btn.hl:SetAllPoints(); b.btn.hl:SetColorTexture(1, 1, 1, 0.2)
    b.btn.label = b.btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.btn.label:SetPoint("CENTER"); b.btn.label:SetText("Travar posições")
    b.btn:SetScript("OnClick", function()
        DB.locked = true
        _G.MVAT_ApplyLayout()
        hud:Hide()
        print("|cff33ccffMVAT|r Posições travadas e salvas.")
    end)
end

local cast = CreateFrame("Frame", "MVAT_CastPanel", UIParent)
cast:SetSize(1, 1)
cast:SetFrameStrata("HIGH")
cast:SetPoint("BOTTOM", hud, "TOP", 0, 26)
cast:Hide()
hud.panels[#hud.panels + 1] = cast
hud.addMover("cast", "AVISO DE CAST (interromper / defesa)", 220, 40, cast, "CENTER", hud, "TOP", 0, 26)

local function MakeSlot(size)
    local f = CreateFrame("Frame", nil, cast)
    f:SetSize(size, size)
    f.border = f:CreateTexture(nil, "BACKGROUND")
    f.border:SetPoint("TOPLEFT", -2, 2); f.border:SetPoint("BOTTOMRIGHT", 2, -2)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetAllPoints(); f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.key = f:CreateFontString(nil, "OVERLAY")
    f.key:SetFont(STANDARD_TEXT_FONT, 13, "THICKOUTLINE")
    f.key:SetPoint("BOTTOMRIGHT", -1, 2)
    f.title = f:CreateFontString(nil, "OVERLAY")
    f.title:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    f.title:SetPoint("BOTTOM", f, "TOP", 0, 3)
    return f
end

cast.enemy = MakeSlot(34)    -- o que o inimigo esta castando
cast.enemy:SetPoint("LEFT", cast, "CENTER", 4, 0)
cast.enemy.border:SetColorTexture(1, 0.3, 0.1, 0.9)
cast.enemy.title:SetText("INIMIGO"); cast.enemy.title:SetTextColor(1, 0.4, 0.2)
cast.name = cast:CreateFontString(nil, "OVERLAY")
cast.name:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
cast.name:SetPoint("LEFT", cast.enemy, "RIGHT", 6, 0)
cast.name:SetWidth(150); cast.name:SetJustifyH("LEFT")

cast.kick = MakeSlot(34)     -- interromper
cast.kick:SetPoint("RIGHT", cast, "CENTER", -4, 0)
cast.kick.border:SetColorTexture(1, 0.55, 0, 0.95)
cast.kick.title:SetText("INTERROMPER"); cast.kick.title:SetTextColor(1, 0.6, 0)

cast.def = MakeSlot(34)      -- defesa
cast.def:SetPoint("RIGHT", cast.kick, "LEFT", -10, 0)
cast.def.border:SetColorTexture(0.9, 0.3, 0.9, 0.95)
cast.def.title:SetText("DEFESA"); cast.def.title:SetTextColor(0.95, 0.5, 0.95)

cast.grp = MakeSlot(34)      -- ajuda ao grupo (curandeiro): aparece quando o cast NAO e em voce
cast.grp:SetPoint("RIGHT", cast.def, "LEFT", -10, 0)
cast.grp.border:SetColorTexture(0.2, 0.9, 0.35, 0.95)
cast.grp.title:SetText("GRUPO"); cast.grp.title:SetTextColor(0.3, 1, 0.45)

-- dica em texto: o que fazer enquanto o inimigo castando (muda com o seu papel)
cast.hint = cast:CreateFontString(nil, "OVERLAY")
cast.hint:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
cast.hint:SetPoint("TOPLEFT", cast.name, "BOTTOMLEFT", 0, -2)
cast.hint:SetWidth(230); cast.hint:SetJustifyH("LEFT"); cast.hint:SetTextColor(1, 0.95, 0.6)

-- Habilidades de interrupcao e de defesa por classe (primeira conhecida e fora de recarga)
local KICKS = {
    WARRIOR = { "PUMMEL", "SHIELD_BASH" }, ROGUE = { "KICK" }, MAGE = { "COUNTERSPELL" },
    PRIEST = { "SILENCE" }, PALADIN = { "HOJ" }, HUNTER = { "SCATTER" },
    WARLOCK = { "DEATH_COIL" }, SHAMAN = { "EARTH_SHOCK" }, DRUID = { "BASH" },
}
local DEFENSES = {
    WARRIOR = { "SHIELD_BLOCK", "SHIELD_WALL" }, ROGUE = { "EVASION" }, MAGE = { "ICE_BLOCK", "ICE_BARRIER", "MANA_SHIELD" },
    PRIEST = { "PW_SHIELD", "FADE" }, PALADIN = { "DIVINE_PROT", "DIVINE_SHIELD" }, HUNTER = { "DETERRENCE" },
    WARLOCK = { "DEATH_COIL" }, SHAMAN = { "GROUNDING" }, DRUID = { "BARKSKIN" },
}

-- Papel de tank: cooldowns de tank no lugar da defesa pessoal
RL.TD = {
    WARRIOR = { "SHIELD_WALL", "LAST_STAND", "SHIELD_BLOCK" },
    PALADIN = { "TEMPLARS_BULWARK", "DIVINE_PROT", "HOLY_SHIELD" },
    DRUID = { "BARKSKIN", "FRENZIED" },
}
-- Papel de cura: o que ajuda o GRUPO quando o cast nao e em voce
RL.GH = {
    PRIEST = { "PRAYER_OF_HEALING", "PRAYER_OF_MENDING", "PENANCE" },
    PALADIN = { "HOLY_SHOCK", "HOLY_LIGHT" },
    SHAMAN = { "CHAIN_HEAL", "RIPTIDE" },
    DRUID = { "WILD_GROWTH", "SWIFTMEND", "REJUV" },
}
-- salvar um aliado quando o cast NAO e em voce (papeis sem cura em grupo)
RL.AS = { PALADIN = { "BOP" }, PRIEST = { "PW_SHIELD" }, SHAMAN = { "GROUNDING" } }
RL.HINT = {
    dps = "Interrompa se puder. Em voce? use a defesa.",
    tank = "Em voce? use a defesa de tank. Interrompa se puder.",
    heal = "Prepare a cura do grupo. Em voce? use a defesa.",
}

local function FirstReady(list)
    for _, k in ipairs(list or {}) do
        if Known(k) and OffCooldown(k) then return k end
    end
end

local function SetAlphaFromBool(frame, bool, whenTrue, whenFalse)
    -- bool pode ser SECRETO: so a API nativa o le (nunca comparamos)
    local ev = C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean
    if ev then
        local ok = pcall(function() frame:SetAlpha(ev(bool, whenTrue, whenFalse)) end)
        if ok then return end
    end
    if frame.SetAlphaFromBoolean and pcall(frame.SetAlphaFromBoolean, frame, bool, whenTrue, whenFalse) then
        return
    end
    frame:SetAlpha(1)   -- sem API: mostra sempre (melhor avisar a mais do que nada)
end

local castState = { active = false, started = 0, count = 0, readable = nil, nameReadable = nil, last = {} }
local encState = { warning = 0, timeline = 0, valid = false, validTimeline = false }

-- Le o cast do unit. type(x) funciona mesmo com valor secreto.
local function ReadCast(unit)
    local name, _, tex, _, _, _, castID, notInt, sid = UnitCastingInfo(unit)
    if type(name) == "nil" then
        name, _, tex, _, _, _, notInt, sid = UnitChannelInfo(unit)
        castID = nil
    end
    if type(name) == "nil" then return nil end
    return name, tex, notInt, sid
end

local function HideCastPanel()
    if castState.active then castState.active = false end
    cast:Hide()
end

-- Chamado a cada ciclo de atualizacao (barato): maquina de estados sobre
-- "existe um cast no alvo?", que e um dado limpo.
local function CastTick()
    local unit = "target"
    if not UnitExists(unit) or UnitIsDeadOrGhost("player") then HideCastPanel(); return end
    local friendly = _G.UnitCanAttack("player", unit)
    if not issecret(friendly) and not friendly then HideCastPanel(); return end  -- aliado castando: ignora
    local name, tex, notInt, sid = ReadCast(unit)
    if name == nil then HideCastPanel(); return end

    -- primeiro quadro desse cast: pinta e mede o que esta legivel
    local fresh = not castState.active
    castState.active = true
    if fresh then
        castState.count = castState.count + 1
        castState.started = GetTime()
        castState.nameReadable = not issecret(name)
        castState.intReadable = not issecret(notInt)
        castState.meReadable = PlayerIsSpellTarget ~= nil and not issecret(PlayerIsSpellTarget(unit))
    end

    pcall(cast.enemy.icon.SetTexture, cast.enemy.icon, tex)        -- aceita valor secreto
    pcall(cast.name.SetText, cast.name, name)                       -- aceita valor secreto

    -- elite/chefe (classificacao e dado limpo): mostra SEMPRE o que voce tem pronto, so atenuado
    -- quando nao e o caso exato; mob comum: so aparece quando faz sentido (como antes)
    local cls = _G.UnitClassification(unit)
    local strong = issecret(cls) or cls == "elite" or cls == "rareelite" or cls == "worldboss" or cls == "boss"

    -- INTERROMPER: so se eu tenho a habilidade e ela esta fora de recarga (limpo);
    -- a transparencia segue "e interrompivel?" (secreto).
    local kickKey = FirstReady(KICKS[playerClass])
    if kickKey then
        cast.kick.icon:SetTexture(ICON[kickKey] or 134400)
        cast.kick.key:SetText(GetKeybind(kickKey))
        cast.kick:Show()
        SetAlphaFromBool(cast.kick, notInt, strong and 0.35 or 0, 1)   -- nao interrompivel: some (chefe: fica fraco)
    else
        cast.kick:Hide()
    end

    -- DEFESA: mob comum: so se o cast e EM MIM e NAO e interrompivel. Chefe: sempre visivel,
    -- forte quando e em voce (ambos os dados sao secretos: so a transparencia decide)
    local role = RL.role()
    local defKey = FirstReady((role == "tank" and RL.TD[playerClass]) or DEFENSES[playerClass])
        or FirstReady(DEFENSES[playerClass])
    local atMe = PlayerIsSpellTarget and PlayerIsSpellTarget(unit)
    local ev = C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean
    if defKey and type(atMe) ~= "nil" then
        cast.def.icon:SetTexture(ICON[defKey] or 134400)
        cast.def.key:SetText(GetKeybind(defKey))
        cast.def:Show()
        local ok
        if strong then
            ok = ev and pcall(function() cast.def:SetAlpha(ev(atMe, 1, 0.5)) end)
            if not ok then SetAlphaFromBool(cast.def, atMe, 1, 0.5) end
        else
            ok = ev and pcall(function() cast.def:SetAlpha(ev(atMe, ev(notInt, 1, 0), 0)) end)
            if not ok then SetAlphaFromBool(cast.def, atMe, 1, 0) end
        end
    else
        cast.def:Hide()
    end

    -- AJUDA AO GRUPO: curandeiro -> cura em grupo; os demais -> salvar aliado (Protecao, Escudo...).
    -- Visivel quando o cast NAO e em voce.
    local grpKey = (role == "heal" and FirstReady(RL.GH[playerClass])) or FirstReady(RL.AS[playerClass])
    if grpKey and type(atMe) ~= "nil" then
        cast.grp.icon:SetTexture(ICON[grpKey] or 134400)
        cast.grp.key:SetText(GetKeybind(grpKey))
        cast.grp:Show()
        SetAlphaFromBool(cast.grp, atMe, (strong and role == "heal") and 0.25 or 0, 1)
    else
        cast.grp:Hide()
    end

    -- dica em texto: so para elite/chefe
    cast.hint:SetText(strong and (RL.HINT[role or "dps"] or "") or "")

    cast:Show()
end

---------------------------------------------------------------------------
-- 9b2. CASTS DE OUTROS INIMIGOS + LIMPEZA DO GRUPO (mesmas tecnicas do DBM/ElvUI no Forever)
---------------------------------------------------------------------------
-- (a) O DBM do Forever escuta o cast de QUALQUER inimigo (nameplates / boss), nao so do
--     alvo, e mostra nome e icone passando o spellID (secreto) direto para
--     C_Spell.GetSpellName / GetSpellTexture. Aqui fazemos o mesmo, sem nunca comparar.
-- (b) O ElvUI/EllesmereUI descobrem "esse debuff eu consigo limpar" com o filtro nativo
--     HARMFUL|RAID_PLAYER_DISPELLABLE (a lista de auras que passa no filtro e um dado
--     LIMPO, mesmo em combate). Aqui varremos voce e o grupo com esse filtro.

do  -- (a) casts de outros inimigos
    local MAXR = 3
    local panel = CreateFrame("Frame", "MVAT_EnemyCasts", UIParent)
    panel:SetSize(1, 1); panel:SetFrameStrata("HIGH")
    panel:SetPoint("BOTTOM", cast, "TOP", 0, 34)
    panel:Hide()
    hud.panels[#hud.panels + 1] = panel
    hud.addMover("ecast", "CASTS DE INIMIGOS (chefes/elites)", 300, 26, panel, "BOTTOM", hud, "TOP", 0, 70)
    local rows = {}
    for i = 1, MAXR do
        local r = CreateFrame("Frame", nil, panel)
        r:SetSize(300, 26)
        r:SetPoint("BOTTOM", panel, "BOTTOM", 0, (i - 1) * 30)   -- empilha para CIMA (nao cobre o painel de cast)
        r.border = r:CreateTexture(nil, "BACKGROUND")
        r.border:SetPoint("TOPLEFT", r, "TOPLEFT", -2, 2); r.border:SetSize(28, 28)
        r.border:SetColorTexture(1, 0.3, 0.1, 0.9)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(24, 24); r.icon:SetPoint("LEFT", r, "LEFT", 0, 0); r.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.nm = r:CreateFontString(nil, "OVERLAY")
        r.nm:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
        r.nm:SetPoint("LEFT", r.icon, "RIGHT", 6, 5); r.nm:SetWidth(190); r.nm:SetJustifyH("LEFT")
        r.who = r:CreateFontString(nil, "OVERLAY")
        r.who:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
        r.who:SetPoint("LEFT", r.icon, "RIGHT", 6, -7); r.who:SetWidth(190); r.who:SetJustifyH("LEFT")
        r.def = CreateFrame("Frame", nil, r)
        r.def:SetSize(24, 24); r.def:SetPoint("RIGHT", r, "RIGHT", 0, 0)
        r.def.icon = r.def:CreateTexture(nil, "ARTWORK")
        r.def.icon:SetAllPoints(); r.def.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.def.key = r.def:CreateFontString(nil, "OVERLAY")
        r.def.key:SetFont(STANDARD_TEXT_FONT, 11, "THICKOUTLINE"); r.def.key:SetPoint("BOTTOMRIGHT", -1, 1)
        r.def:Hide()
        -- ajuda ao grupo (curandeiro), ao lado da defesa
        r.grp = CreateFrame("Frame", nil, r)
        r.grp:SetSize(24, 24); r.grp:SetPoint("RIGHT", r.def, "LEFT", -4, 0)
        r.grp.icon = r.grp:CreateTexture(nil, "ARTWORK")
        r.grp.icon:SetAllPoints(); r.grp.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        r.grp.key = r.grp:CreateFontString(nil, "OVERLAY")
        r.grp.key:SetFont(STANDARD_TEXT_FONT, 11, "THICKOUTLINE"); r.grp.key:SetPoint("BOTTOMRIGHT", -1, 1)
        r.grp:Hide()
        r:Hide()
        r.unit, r.expires = false, 0
        rows[i] = r
    end
    panel.hint = panel:CreateFontString(nil, "OVERLAY")
    panel.hint:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
    panel.hint:SetPoint("TOP", panel, "BOTTOM", 0, -2); panel.hint:SetWidth(300); panel.hint:SetTextColor(1, 0.95, 0.6)

    local function Free(r) r.unit = false; r.expires = 0; r:Hide() end

    local function Start(unit, spellID, retried)
        if not DB.ecasts then return end
        local friendly = _G.UnitCanAttack("player", unit)
        if not issecret(friendly) and not friendly then return end   -- so inimigos
        if UnitIsUnit(unit, "target") then return end                 -- o alvo ja tem o painel principal
        -- como o DBM do Forever: so inimigos EM COMBATE (a marca atrasa um instante: 1 nova tentativa)
        local inCombat = _G.UnitAffectingCombat(unit)
        if not issecret(inCombat) and not inCombat then
            if not retried and C_Timer and C_Timer.After then
                C_Timer.After(0.05, function() pcall(Start, unit, spellID, true) end)
            end
            return
        end
        local cls = _G.UnitClassification(unit)
        local strong = unit:find("^boss") ~= nil
            or issecret(cls) or cls == "elite" or cls == "rareelite" or cls == "worldboss"
        -- mob comum: no maximo 1 aviso por segundo (evita enxurrada em pulls grandes)
        if not strong then
            local t = GetTime()
            if t - (extra.lastWeak or -9) < 1 then return end
            extra.lastWeak = t
        end
        local row
        for _, r in ipairs(rows) do if r.unit == unit then row = r; break end end
        if not row then for _, r in ipairs(rows) do if not r.unit then row = r; break end end end
        if not row then
            row = rows[1]
            for _, r in ipairs(rows) do if r.expires < row.expires then row = r end end
        end
        row.unit, row.expires = unit, GetTime() + 8   -- os eventos STOP/INTERRUPTED liberam antes
        extra.ecasts = extra.ecasts + 1
        local gsn, gst = C_Spell and C_Spell.GetSpellName, C_Spell and C_Spell.GetSpellTexture
        local cname, ctex = ReadCast(unit)
        pcall(row.nm.SetText, row.nm, (gsn and spellID ~= nil and gsn(spellID)) or cname or "?")
        pcall(row.icon.SetTexture, row.icon, (gst and spellID ~= nil and gst(spellID)) or ctex or 134400)
        row.nm:SetTextColor(strong and 1 or 0.9, strong and 0.55 or 0.9, strong and 0.2 or 0.9)
        -- alvo do cast (nome e classe sao secretos: so exibicao)
        row.who:SetText("")
        if _G.UnitSpellTargetName then
            pcall(function()
                local tn = _G.UnitSpellTargetName(unit)
                if type(tn) == "nil" then return end
                local cc = _G.UnitSpellTargetClass and C_ClassColor and C_ClassColor.GetClassColor(_G.UnitSpellTargetClass(unit))
                row.who:SetText("-> " .. (cc and cc:WrapTextInColorCode(tn) or tn))
            end)
        end
        -- defesa: aparece so se o cast e EM VOCE e nao e interrompivel (secretos)
        local role = RL.role()
        local defKey = FirstReady((role == "tank" and RL.TD[playerClass]) or DEFENSES[playerClass])
            or FirstReady(DEFENSES[playerClass])
        local atMe = PlayerIsSpellTarget and PlayerIsSpellTarget(unit)
        local _, _, notInt = ReadCast(unit)
        row.def:Hide(); row.grp:Hide()
        local grpKey = (role == "heal" and FirstReady(RL.GH[playerClass])) or FirstReady(RL.AS[playerClass])
        if grpKey and type(atMe) ~= "nil" then
            row.grp.icon:SetTexture(ICON[grpKey] or 134400)
            row.grp.key:SetText(GetKeybind(grpKey))
            SetAlphaFromBool(row.grp, atMe, (strong and role == "heal") and 0.25 or 0, 1)   -- em voce -> some; em outro -> aparece
            row.grp:Show()
        end
        if strong then panel.hint:SetText(RL.HINT[role or "dps"] or "") end
        if defKey and type(atMe) ~= "nil" then
            row.def.icon:SetTexture(ICON[defKey] or 134400)
            row.def.key:SetText(GetKeybind(defKey))
            local ev = C_CurveUtil and C_CurveUtil.EvaluateColorValueFromBoolean
            local ok
            if strong then   -- chefe/elite: sempre visivel, forte quando e em voce
                ok = ev and pcall(function() row.def:SetAlpha(ev(atMe, 1, 0.5)) end)
                if not ok then SetAlphaFromBool(row.def, atMe, 1, 0.5) end
            else
                ok = ev and pcall(function() row.def:SetAlpha(ev(atMe, ev(notInt, 1, 0), 0)) end)
                if not ok then SetAlphaFromBool(row.def, atMe, 1, 0) end
            end
            row.def:Show()
        end
        -- mob comum so aparece quando mira em voce; elite/chefe aparece sempre
        row:SetAlpha(1)
        if not strong and type(atMe) ~= "nil" then SetAlphaFromBool(row, atMe, 1, 0) end
        row:Show()
    end

    local ev = CreateFrame("Frame")
    ev:SetScript("OnEvent", function(_, event, unit, _, spellID)
        if type(unit) ~= "string" or not DB or not DB.enabled then return end
        if not (unit:find("^nameplate%d") or unit:find("^boss%d") or unit == "focus") then return end
        if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
            local ok, err = pcall(Start, unit, spellID)
            if not ok then extra.ecastErr = err end
        else
            for _, r in ipairs(rows) do if r.unit == unit then Free(r) end end
        end
    end)
    function extra.registerCasts(valid)
        for _, e in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_STOP",
                             "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED" }) do
            if valid(e) then pcall(ev.RegisterEvent, ev, e) end
        end
    end
    function extra.castsTick()
        local any, now = false, GetTime()
        for _, r in ipairs(rows) do
            if r.unit and now > r.expires then Free(r) end
            if r.unit then any = true end
        end
        if not any then panel.hint:SetText("") end
        panel:SetShown(any)
    end
    function extra.castsHide() panel:Hide(); panel.hint:SetText(""); for _, r in ipairs(rows) do Free(r) end end
end

do  -- (b) debuffs do grupo que a sua classe remove
    -- por tipo de debuff -> habilidades (a primeira conhecida e na barra vale)
    local PURGE = {
        PALADIN = { Poison = { "CLEANSE", "PURIFY" }, Disease = { "CLEANSE", "PURIFY" }, Magic = { "CLEANSE" } },
        PRIEST  = { Magic = { "DISPEL_MAGIC" }, Disease = { "ABOLISH_DISEASE", "CURE_DISEASE_P" } },
        MAGE    = { Curse = { "REMOVE_LESSER_CURSE" } },
        SHAMAN  = { Poison = { "CURE_POISON_S" }, Disease = { "CURE_DISEASE_S" } },
        DRUID   = { Curse = { "REMOVE_CURSE" }, Poison = { "ABOLISH_POISON", "CURE_POISON_D" } },
    }
    local MAXR = 4
    local panel = CreateFrame("Frame", "MVAT_Purge", UIParent)
    panel:SetSize(1, 1); panel:SetFrameStrata("HIGH")
    panel:SetPoint("TOPRIGHT", hud, "TOPLEFT", -16, 0)
    panel:Hide()
    hud.panels[#hud.panels + 1] = panel
    hud.addMover("purge", "LIMPAR (grupo)", 330, 18, panel, "TOPRIGHT", hud, "TOPLEFT", -16, 0)
    panel.title = panel:CreateFontString(nil, "OVERLAY")
    panel.title:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE"); panel.title:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    panel.title:SetText("LIMPAR"); panel.title:SetTextColor(0.3, 1, 0.5)
    local rows = {}
    local function MakeIcon(parent, size)
        local f = CreateFrame("Frame", nil, parent)
        f:SetSize(size, size)
        f.icon = f:CreateTexture(nil, "ARTWORK"); f.icon:SetAllPoints(); f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        f.key = f:CreateFontString(nil, "OVERLAY")
        f.key:SetFont(STANDARD_TEXT_FONT, 11, "THICKOUTLINE"); f.key:SetPoint("BOTTOMRIGHT", -1, 1)
        return f
    end
    for i = 1, MAXR do
        local r = CreateFrame("Frame", nil, panel)
        r:SetSize(330, 28)
        r:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -14 - (i - 1) * 31)
        r.dbf = MakeIcon(r, 22); r.dbf:SetPoint("RIGHT", r, "RIGHT", 0, 0)
        r.what = r:CreateFontString(nil, "OVERLAY")
        r.what:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
        r.what:SetPoint("RIGHT", r.dbf, "LEFT", -5, 0); r.what:SetWidth(110); r.what:SetJustifyH("RIGHT")
        r.who = r:CreateFontString(nil, "OVERLAY")
        r.who:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
        r.who:SetPoint("RIGHT", r.what, "LEFT", -6, 0); r.who:SetWidth(90); r.who:SetJustifyH("RIGHT")
        r.sp2 = MakeIcon(r, 26); r.sp2:SetPoint("RIGHT", r.who, "LEFT", -6, 0)
        r.sp1 = MakeIcon(r, 26); r.sp1:SetPoint("RIGHT", r.sp2, "LEFT", -4, 0)
        r.bd = r:CreateTexture(nil, "BACKGROUND")
        r.bd:SetPoint("TOPLEFT", r.sp1, "TOPLEFT", -2, 2); r.bd:SetPoint("BOTTOMRIGHT", r.dbf, "BOTTOMRIGHT", 2, -2)
        r.bd:SetColorTexture(0, 0, 0, 0.45)
        r:Hide()
        rows[i] = r
    end

    local function UsableKey(k) return Known(k) and OnBar(N[k]) end

    -- habilidades que servem para este debuff. Tipo desconhecido (secreto em combate):
    -- mostra uma habilidade por tipo que a sua classe remove (no maximo 2).
    local function Spells(typeName)
        local t = PURGE[playerClass]
        local out, seen = {}, {}
        if not t then return out end
        local function add(list)
            for _, k in ipairs(list or {}) do
                if UsableKey(k) then
                    if not seen[k] then seen[k] = true; out[#out + 1] = k end
                    return
                end
            end
        end
        if typeName then add(t[typeName])
        else for _, tn in ipairs({ "Magic", "Curse", "Poison", "Disease" }) do add(t[tn]) end end
        return out
    end

    -- true = tem debuff que eu removo (+ dados da aura), false = limpo, nil = API indisponivel
    local function Scan(unit)
        local slots = C_UnitAuras and C_UnitAuras.GetAuraSlots
        if not slots then return nil end
        extra.purgeScans = extra.purgeScans + 1
        local ok, _, s1 = pcall(slots, unit, "HARMFUL|RAID_PLAYER_DISPELLABLE", 1)
        if not ok then extra.purgeErr = _; return nil end
        if type(s1) == "nil" then return false end
        local ok2, a = pcall(C_UnitAuras.GetAuraDataBySlot, unit, s1)
        return true, (ok2 and type(a) == "table") and a or nil
    end

    extra.purgeSpells = Spells
    local units, last = {}, 0
    local function Group()
        wipe(units); units[1] = "player"
        if _G.IsInRaid and _G.IsInRaid() then
            for i = 1, math.min(40, (_G.GetNumGroupMembers and _G.GetNumGroupMembers()) or 0) do units[#units + 1] = "raid" .. i end
        elseif _G.GetNumSubgroupMembers and _G.GetNumSubgroupMembers() > 0 then
            for i = 1, 4 do units[#units + 1] = "party" .. i end
        end
        return units
    end

    ---------------------------------------------------------------- (c) seu debuff SEM remocao
    -- Quando voce esta com um debuff de Magia/Maldicao/Doenca/Veneno que a sua classe NAO consegue
    -- remover, o addon nao tem o que sugerir; aqui ele AVISA e explica (ex.: "Magia: so com Cleanse,
    -- nivel 42"). Em combate o tipo do debuff e secreto: o jogo avalia uma curva de cor por dentro
    -- (GetAuraDispelTypeColor, como o EllesmereUI) e o addon so MOSTRA o resultado (alfa/cor).
    -- Tipos do motor: 1 Magia, 2 Maldicao, 3 Doenca, 4 Veneno (0 = nenhum; 9/11 = enrage/sangramento).
    local TYPES = {
        { 1, "Magic", "Magia", 0.35, 0.50, 1.00 }, { 2, "Curse", "Maldição", 0.70, 0.10, 0.70 },
        { 3, "Disease", "Doença", 0.75, 0.45, 0.10 }, { 4, "Poison", "Veneno", 0.10, 0.85, 0.30 },
    }
    local NP = { MAXB = 2 }
    local nop = CreateFrame("Frame", "MVAT_NoPurge", UIParent)
    nop:SetSize(1, 1); nop:SetFrameStrata("HIGH"); nop:Hide()
    hud.panels[#hud.panels + 1] = nop
    hud.addMover("nopurge", "SEU DEBUFF SEM REMOÇÃO", 330, 18, nop, "TOPRIGHT", hud, "TOPLEFT", -16, 120)
    NP.rows = {}
    for i = 1, NP.MAXB do
        local r = CreateFrame("Frame", nil, nop)
        r:SetSize(330, 36); r:SetPoint("TOPRIGHT", nop, "TOPRIGHT", 0, -(i - 1) * 40)
        r.bd = r:CreateTexture(nil, "BACKGROUND"); r.bd:SetAllPoints(); r.bd:SetColorTexture(0, 0, 0, 0.55)
        r.ico = MakeIcon(r, 26); r.ico:SetPoint("RIGHT", r, "RIGHT", -4, 0)
        r.name = r:CreateFontString(nil, "OVERLAY")
        r.name:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE"); r.name:SetTextColor(1, 0.55, 0.55)
        r.name:SetPoint("TOPRIGHT", r.ico, "TOPLEFT", -6, 1); r.name:SetWidth(290); r.name:SetJustifyH("RIGHT")
        r.lab = {}
        for k = 1, 4 do   -- um texto por tipo: so o do tipo real fica visivel (alfa vem da curva)
            local fs = r:CreateFontString(nil, "OVERLAY")
            fs:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
            fs:SetPoint("BOTTOMRIGHT", r.ico, "BOTTOMLEFT", -6, -1); fs:SetWidth(290); fs:SetJustifyH("RIGHT")
            r.lab[k] = fs
        end
        r:Hide(); NP.rows[i] = r
    end

    -- curvas (uma "qualquer tipo" + uma por tipo): alfa 1 so nos indices certos
    function NP.curves()
        if NP.cv ~= nil then return NP.cv end
        NP.cv = false
        local CU = _G.C_CurveUtil
        if not (CU and CU.CreateColorCurve and _G.Enum and Enum.LuaCurveType and _G.CreateColor
            and C_UnitAuras and C_UnitAuras.GetAuraDispelTypeColor) then return false end
        local function build(only)
            local c = CU.CreateColorCurve()
            c:SetType(Enum.LuaCurveType.Step)
            for idx = 0, 11 do
                local on = (only and idx == only) or (not only and idx >= 1 and idx <= 4)
                local t = TYPES[idx]
                c:AddPoint(idx, CreateColor(t and t[4] or 1, t and t[5] or 1, t and t[6] or 1, on and 1 or 0))
            end
            return c
        end
        local ok, cv = pcall(function()
            local x = { any = build(nil) }
            for k = 1, 4 do x[k] = build(k) end
            return x
        end)
        NP.cv = ok and cv or false
        return NP.cv
    end

    -- texto por tipo, na medida da SUA classe e do SEU nivel (dados do treinador do Forever)
    function NP.text(k)
        local t = TYPES[k]
        local d = RL.DISPEL[playerClass] and RL.DISPEL[playerClass][t[2]]
        if not d then return t[3] .. ": a sua classe não remove" end
        local nm = N[d[1]] or d[1]
        local lvl = Pub(UnitLevel("player")) or 0
        if Known(d[1]) then return t[3] .. ": use " .. nm .. " (fora de alcance?)" end
        if lvl >= d[2] then return t[3] .. ": " .. nm .. " (nível " .. d[2] .. ") - treine no instrutor" end
        return t[3] .. ": só com " .. nm .. " (nível " .. d[2] .. ", você é " .. lvl .. ")"
    end

    local function Pack(...) return { n = select("#", ...), ... } end

    function NP.tick(enabled)
        if not enabled then nop:Hide(); return end
        local cv = NP.curves()
        local slotsFn = C_UnitAuras and C_UnitAuras.GetAuraSlots
        if not (cv and slotsFn and C_UnitAuras.GetAuraDataBySlot) then nop:Hide(); return end
        local okH, harm = pcall(function() return Pack(slotsFn("player", "HARMFUL")) end)
        local okD, disp = pcall(function() return Pack(slotsFn("player", "HARMFUL|RAID_PLAYER_DISPELLABLE")) end)
        if not (okH and okD) then nop:Hide(); return end
        local dset = {}
        for i = 2, disp.n do if disp[i] ~= nil then dset[disp[i]] = true end end   -- [1] = token de continuacao
        local n = 0
        for i = 2, harm.n do
            local slot = harm[i]
            if slot ~= nil and not dset[slot] and n < NP.MAXB then
                local okA, a = pcall(C_UnitAuras.GetAuraDataBySlot, "player", slot)
                if okA and type(a) == "table" then
                    n = n + 1
                    local r = NP.rows[n]
                    pcall(r.name.SetText, r.name, a.name)
                    pcall(r.ico.icon.SetTexture, r.ico.icon, a.icon)
                    -- a linha so aparece se o debuff TEM tipo (Magia/Maldicao/Doenca/Veneno)
                    local okc, any = pcall(C_UnitAuras.GetAuraDispelTypeColor, "player", a.auraInstanceID, cv.any)
                    if not (okc and any and pcall(function() r:SetAlpha(any.a) end)) then r:SetAlpha(1) end
                    for k = 1, 4 do
                        r.lab[k]:SetText(NP.text(k))
                        local okk, col = pcall(C_UnitAuras.GetAuraDispelTypeColor, "player", a.auraInstanceID, cv[k])
                        if not (okk and col and pcall(function() r.lab[k]:SetTextColor(col.r, col.g, col.b, col.a) end)) then
                            r.lab[k]:SetTextColor(TYPES[k][4], TYPES[k][5], TYPES[k][6], 0)
                        end
                    end
                    r:Show()
                end
            end
        end
        for i = n + 1, NP.MAXB do NP.rows[i]:Hide() end
        nop:SetShown(n > 0)
    end
    extra.noPurge = NP

    function extra.purgeTick()
        if not DB.purge or UnitIsDeadOrGhost("player") then
            panel:Hide(); extra.purgeFound = nil; NP.tick(false); return
        end
        local now = GetTime()
        if now - last < 0.3 then return end
        last = now
        NP.tick(true)
        if not PURGE[playerClass] then panel:Hide(); extra.purgeFound = nil; return end   -- classe sem dispel
        local n = 0
        extra.purgeFound = nil
        for idx, unit in ipairs(Group()) do
            if n >= MAXR then break end
            if UnitExists(unit) and not UnitIsDeadOrGhost(unit) and not (idx > 1 and UnitIsUnit(unit, "player")) then
                local inRange = true
                if unit ~= "player" and _G.UnitInRange then
                    local okr, v = pcall(_G.UnitInRange, unit)
                    if okr and not issecret(v) and v == false then inRange = false end
                end
                if inRange then
                    local found, aura = Scan(unit)
                    if found then
                        n = n + 1
                        extra.purgeHits = extra.purgeHits + 1
                        local r = rows[n]
                        local nm = Pub(UnitName(unit))
                        local _, token = UnitClass(unit)
                        local col = RAID_CLASS_COLORS and Pub(token) and RAID_CLASS_COLORS[token]
                        r.who:SetText(nm or unit)
                        if col then r.who:SetTextColor(col.r, col.g, col.b) else r.who:SetTextColor(1, 1, 1) end
                        if aura then
                            pcall(r.what.SetText, r.what, aura.name)
                            pcall(r.dbf.icon.SetTexture, r.dbf.icon, aura.icon)
                            r.dbf:Show()
                        else
                            r.what:SetText("debuff"); r.dbf:Hide()
                        end
                        r.what:SetTextColor(1, 0.45, 0.45)
                        local typeName = aura and Pub(aura.dispelName)
                        if n == 1 then   -- o primeiro encontrado vira a sugestao do icone principal
                            extra.purgeFound = { unit = unit, typeName = type(typeName) == "string" and typeName or nil, name = nm }
                            extra.purgeAt = now
                        end
                        local list = Spells(type(typeName) == "string" and typeName or nil)
                        for s = 1, 2 do
                            local f, k = r["sp" .. s], list[s]
                            if k then
                                f.icon:SetTexture(ICON[k] or 134400); f.key:SetText(GetKeybind(k)); f:Show()
                            else f:Hide() end
                        end
                        r:Show()
                    end
                end
            end
        end
        for i = n + 1, MAXR do rows[i]:Hide() end
        panel:SetShown(n > 0)
    end
    function extra.purgeHide() panel:Hide(); nop:Hide() end
end

function extra.tick()
    local ok, err = pcall(extra.castsTick)
    if not ok then extra.ecastErr = err end
    ok, err = pcall(extra.purgeTick)
    if not ok then extra.purgeErr = err end
end
function extra.hide() extra.castsHide(); extra.purgeHide() end

---------------------------------------------------------------------------
-- 9c. AVISO DE ENCONTRO (ENCOUNTER_WARNING) - so se o cliente enviar
---------------------------------------------------------------------------
-- E o sistema que o DBM/BigWigs usam em Midnight: texto, icone e severidade do
-- aviso do chefe. Texto/icone sao secretos (so exibimos); severidade e duracao
-- sao limpas. No Forever o DBM nao liga esses eventos; aqui ligamos se existirem.
local banner = CreateFrame("Frame", "MVAT_Banner", UIParent)
banner:SetSize(1, 1)
banner:SetFrameStrata("HIGH")
banner:SetPoint("TOP", hud, "BOTTOM", 0, -44)
banner:Hide()
hud.panels[#hud.panels + 1] = banner
hud.addMover("banner", "AVISO DO CHEFE", 280, 36, banner, "TOP", hud, "BOTTOM", 0, -44)
banner.icon = banner:CreateTexture(nil, "ARTWORK")
banner.icon:SetSize(30, 30); banner.icon:SetPoint("RIGHT", banner, "CENTER", -4, 0)
banner.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
banner.text = banner:CreateFontString(nil, "OVERLAY")
banner.text:SetFont(STANDARD_TEXT_FONT, 14, "THICKOUTLINE")
banner.text:SetPoint("LEFT", banner, "CENTER", 2, 0)
banner.text:SetWidth(240); banner.text:SetJustifyH("LEFT")
local bannerUntil = 0

local SEV_COLOR = { [0] = { 1, 1, 0.4 }, [1] = { 1, 0.6, 0.1 }, [2] = { 1, 0.15, 0.15 } }

local function ShowEncounterWarning(info)
    if type(info) ~= "table" then return end
    encState.warning = encState.warning + 1
    local sev = info.severity
    if issecret(sev) or type(sev) ~= "number" then sev = 1 end
    local col = SEV_COLOR[sev] or SEV_COLOR[1]
    local text = info.text
    -- o texto do aviso pode ter %s para o conjurador/alvo; formatar tambem aceita secretos
    local ok, formatted = pcall(string.format, text, info.casterName or "", info.targetName or "")
    pcall(banner.text.SetText, banner.text, ok and formatted or text)
    banner.text:SetTextColor(col[1], col[2], col[3])
    pcall(banner.icon.SetTexture, banner.icon, info.iconFileID)
    local dur = info.duration
    if issecret(dur) or type(dur) ~= "number" or dur <= 0 or dur > 15 then dur = 4 end
    bannerUntil = GetTime() + dur
    banner:Show()
end

local function BannerTick()
    if banner:IsShown() and GetTime() > bannerUntil then banner:Hide() end
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
    hud.setQueue(nil)
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
            combatSnap.target, combatSnap.casts, combatSnap.castSecret = nil, 0, nil
            combatSnap.usable = nil
            procSeen = 0
        end
        combatSnap.hp = c.hpKnown
        combatSnap.power = Pub(UnitPower("player")) ~= nil
        combatSnap.auraP, combatSnap.auraT = auraSecret.player, auraSecret.target
        if c.target then combatSnap.target = not c.hostileSecret end
        if c.cast then
            combatSnap.casts = combatSnap.casts + 1
            combatSnap.castSecret = (c.cast.name == "feitico do inimigo")
        end
        if combatSnap.usable == nil then
            for _, rule in ipairs(rules) do
                local k = rule.pick[1]
                if k and Known(k) then
                    combatSnap.usable = SpellUsable(N[k]) ~= nil
                    local _, _, act = SpellCooldown(N[k])
                    combatSnap.cd = act ~= nil
                    break
                end
            end
        end
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
    -- DEPOIS: o que mais esta disponivel agora (a combinacao que vem a seguir)
    local skip, q = { [key] = true }, {}
    for _ = 1, 2 do
        local r2, k2 = Evaluate(skip)
        if not k2 then break end
        q[#q + 1] = k2; skip[k2] = true
    end
    hud.setQueue(q)
end

-- Rede de seguranca: se alguma API nova devolver algo inesperado, o addon so
-- esconde o icone neste ciclo em vez de gerar erro de Lua a cada 0,1s.
local lastError
local function Update()
    if not DB or not DB.enabled then hud:Hide(); cast:Hide(); banner:Hide(); extra.hide(); return end
    if GetTime() < testUntil then return end
    local ok, err = pcall(DoUpdate)
    if not ok then
        lastError = err
        hud:Hide()
    end
    -- painel de cast e aviso de encontro sao independentes: um erro num nao derruba o outro
    local ok2, err2 = pcall(CastTick)
    if not ok2 then lastError = err2; cast:Hide() end
    extra.tick()      -- casts de outros inimigos + painel LIMPAR (cada um com o seu pcall)
    BannerTick()
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

-- VERSAO: o addon troca o numero da versao com amigos no grupo/guilda (mensagem de addon, sem
-- internet). Se alguem tem uma mais nova, avisa uma vez para rodar o "Atualizar MVAT.bat".
function extra.version()
    local f = (C_AddOns and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
    local ok, v = pcall(f, ADDON_NAME, "Version")
    return (ok and type(v) == "string" and v ~= "") and v or "0"
end
function extra.vnum(v)
    local a, b, c = tostring(v):match("^(%d+)%.?(%d*)%.?(%d*)")
    return (tonumber(a) or 0) * 1000000 + (tonumber(b) or 0) * 1000 + (tonumber(c) or 0)
end
function extra.announceVersion()
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
    if GetTime() - (extra.lastAnnounce or -99) < 30 then return end
    extra.lastAnnounce = GetTime()
    local ch = (_G.IsInRaid and _G.IsInRaid() and "RAID") or (_G.IsInGroup and _G.IsInGroup() and "PARTY")
        or (_G.IsInGuild and _G.IsInGuild() and "GUILD") or nil
    if ch then pcall(C_ChatInfo.SendAddonMessage, "MVAT", "V:" .. extra.version(), ch) end
end
function extra.onAddonMsg(prefix, msg)
    if prefix ~= "MVAT" or type(msg) ~= "string" or issecret(msg) then return end
    local v = msg:match("^V:([%d%.]+)$")
    if v and extra.vnum(v) > extra.vnum(extra.version()) and not extra.warned then
        extra.warned = true
        print("|cff33ccffMVAT|r Seu MVAT esta desatualizado (" .. extra.version() .. "): um amigo tem a versao " .. v
            .. ". Rode |cffffff00Atualizar MVAT.bat|r (na pasta do addon) e depois |cffffff00/reload|r.")
    end
end

local function RefreshSpells()
    ResolveNames()
    ScanSpellbook()
    ResolveRankIDs()
    RebuildKeyCache()
    RL.detect()          -- papel (dano/tank/cura) pelos pontos de talento
end

core:RegisterEvent("ADDON_LOADED")
core:RegisterEvent("PLAYER_LOGIN")
local function EventValid(e)
    if not (C_EventUtils and C_EventUtils.IsEventValid) then return true end
    local ok, v = pcall(C_EventUtils.IsEventValid, e)
    return (not ok) or v == true
end

core:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON_NAME then return end
        MVAT_DB = MVAT_DB or {}
        for k, v in pairs(DEFAULTS) do if MVAT_DB[k] == nil then MVAT_DB[k] = v end end
        DB = MVAT_DB
        core:UnregisterEvent("ADDON_LOADED")
    elseif event == "PLAYER_LOGIN" then
        ApplyLayout()
        RefreshSpells()
        pcall(RefreshGear)
        LoadClassRules()
        for _, e in ipairs({ "SPELLS_CHANGED", "LEARNED_SPELL_IN_TAB", "PLAYER_LEVEL_UP", "CHARACTER_POINTS_CHANGED",
                             "ACTIONBAR_SLOT_CHANGED", "UPDATE_BINDINGS", "UPDATE_SHAPESHIFT_FORM",
                             "UPDATE_BONUS_ACTIONBAR", "PLAYER_TARGET_CHANGED", "PLAYER_EQUIPMENT_CHANGED" }) do
            if not C_EventUtils or not C_EventUtils.IsEventValid or C_EventUtils.IsEventValid(e) then
                core:RegisterEvent(e)
            end
        end
        -- casts apenas do alvo atual (reacao instantanea a interrupts)
        for _, e in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_CHANNEL_START", "UNIT_SPELLCAST_STOP",
                             "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_INTERRUPTED" }) do
            if EventValid(e) then core:RegisterUnitEvent(e, "target") end
        end
        -- casts de qualquer inimigo (nameplates / chefe), como o DBM faz
        extra.registerCasts(EventValid)
        -- os SEUS casts (alimentam os combos "usei A -> use B")
        if EventValid("UNIT_SPELLCAST_SUCCEEDED") then core:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player") end
        -- sistema de encontro da Blizzard (aviso do chefe): so se o cliente o enviar
        encState.valid = EventValid("ENCOUNTER_WARNING")
        encState.validTimeline = EventValid("ENCOUNTER_TIMELINE_EVENT_ADDED")
        if encState.valid then pcall(core.RegisterEvent, core, "ENCOUNTER_WARNING") end
        if encState.validTimeline then pcall(core.RegisterEvent, core, "ENCOUNTER_TIMELINE_EVENT_ADDED") end
        -- brilho de proc da Blizzard
        for _, e in ipairs({ "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" }) do
            if not C_EventUtils or not C_EventUtils.IsEventValid or C_EventUtils.IsEventValid(e) then
                core:RegisterEvent(e)
            end
        end
        extra.registerSettings()
        extra.minimapUpdate()
        -- aviso de versao nova entre amigos
        if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then pcall(C_ChatInfo.RegisterAddonMessagePrefix, "MVAT") end
        for _, e in ipairs({ "CHAT_MSG_ADDON", "GROUP_ROSTER_UPDATE", "PLAYER_ENTERING_WORLD" }) do
            if EventValid(e) then pcall(core.RegisterEvent, core, e) end
        end
        print("|cff33ccffMVAT|r carregado para " .. (UnitClass("player")) .. ". Digite |cffffff00/mvat|r para abrir as opcoes.")
    elseif event == "SPELLS_CHANGED" or event == "LEARNED_SPELL_IN_TAB" or event == "PLAYER_LEVEL_UP"
        or event == "CHARACTER_POINTS_CHANGED" then
        RefreshSpells()
        LoadClassRules()
    elseif event == "ACTIONBAR_SLOT_CHANGED" or event == "UPDATE_BINDINGS"
        or event == "UPDATE_SHAPESHIFT_FORM" or event == "UPDATE_BONUS_ACTIONBAR" then
        RebuildKeyCache()
    elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" or event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
        local sid = Pub(arg1)
        if type(sid) == "number" then
            if event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
                glowing[sid] = true
                if UnitAffectingCombat("player") then procSeen = procSeen + 1 end
            else
                glowing[sid] = nil
            end
        end
        elapsed = UPDATE_INTERVAL
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if arg1 == "player" then
            OnPlayerCast(arg3)
            elapsed = UPDATE_INTERVAL
        end
    elseif event == "CHAT_MSG_ADDON" then
        pcall(extra.onAddonMsg, arg1, arg2)
    elseif event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ENTERING_WORLD" then
        if not UnitAffectingCombat("player") then pcall(extra.announceVersion) end
    elseif event == "ENCOUNTER_WARNING" then
        local ok, err = pcall(ShowEncounterWarning, arg1)
        if not ok then lastError = err end
    elseif event == "ENCOUNTER_TIMELINE_EVENT_ADDED" then
        encState.timeline = encState.timeline + 1
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        pcall(RefreshGear)
        elapsed = UPDATE_INTERVAL
    elseif event == "PLAYER_TARGET_CHANGED" or event:find("^UNIT_SPELLCAST_") then
        if event == "PLAYER_TARGET_CHANGED" then wipe(tcache); wipe(lastCast.at); lastCast.cp = 0 end -- tipo/classe do alvo anterior nao vale mais
        elapsed = UPDATE_INTERVAL -- reavalia imediatamente
    end
end)

local function Msg(text) print("|cff33ccffMVAT|r " .. text) end

---------------------------------------------------------------------------
-- 11. JANELA DE OPCOES (/mvat abre; tambem em Esc > Opcoes > AddOns)
---------------------------------------------------------------------------
-- Visual inspirado no Leatrix: painel escuro com pergaminho, duas colunas com titulos
-- dourados, caixas de selecao nativas, dica ao passar o mouse, sliders com o valor ao lado,
-- rodape com botoes, posicao lembrada e Esc fecha. So usa fontes e texturas nativas do jogo
-- (nenhum template), entao funciona igual com ElvUI/EllesmereUI.
extra.buildOptions = function()
    local W, H = 470, 445
    local f = CreateFrame("Frame", "MVAT_Options", UIParent)
    f:SetSize(W, H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("FULLSCREEN_DIALOG"); f:SetFrameLevel(20)
    f:SetClampedToScreen(true); f:EnableMouse(true); f:SetMovable(true); f:RegisterForDrag("LeftButton")
    f:Hide()
    if _G.UISpecialFrames then table.insert(_G.UISpecialFrames, "MVAT_Options") end   -- Esc fecha

    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, r, x, y = self:GetPoint()
        if DB and p then DB.optPos = { p, r, x, y } end   -- lembra onde voce deixou
    end)

    -- fundo + pergaminho (mesmas texturas do Leatrix; ja existem no cliente)
    local PARCH = "Interface\\ACHIEVEMENTFRAME\\UI-GuildAchievement-Parchment-Horizontal-Desaturated.png"
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(); bg:SetColorTexture(0.05, 0.05, 0.05, 0.9)
    local body = f:CreateTexture(nil, "BORDER")
    body:SetTexture(PARCH); body:SetSize(W, H - 17); body:SetPoint("TOPRIGHT")
    body:SetVertexColor(0.7, 0.7, 0.7, 0.7); body:SetTexCoord(0.09, 1, 0, 1)
    local foot = f:CreateTexture(nil, "BORDER")
    foot:SetTexture(PARCH); foot:SetSize(W, 48); foot:SetPoint("BOTTOM"); foot:SetVertexColor(0.5, 0.5, 0.5, 1)

    -- titulo e subtitulo
    local mt = f:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    mt:SetPoint("TOPLEFT", 16, -16); mt:SetText("MVAT - Tutor de Combate")
    local sub = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", mt, "BOTTOMLEFT", 0, -6)
    sub:SetText("Só mostra o que usar. Nunca joga por você.   |cff888888v" .. extra.version() .. "|r")

    ---------------------------------------------------------------- helpers
    local controls = {}
    local function Refresh() for _, c in ipairs(controls) do c.refresh() end end

    local function Tip(self)
        if self.tip and _G.GameTooltip then
            _G.GameTooltip:SetOwner(self, "ANCHOR_NONE")
            _G.GameTooltip:SetPoint("TOPLEFT", f, "TOPRIGHT", 10, 0)
            _G.GameTooltip:SetText(self.tip, 1, 1, 1, 1, true)
            _G.GameTooltip:Show()
        end
    end
    local function TipOff() if _G.GameTooltip then _G.GameTooltip:Hide() end end

    local function Heading(text, x, y)
        local t = f:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        t:SetPoint("TOPLEFT", x, y); t:SetText(text)
        return t
    end

    local function Button(text, w, h)
        local b = CreateFrame("Button", nil, f)
        b:SetSize(w, h)
        b.edge = b:CreateTexture(nil, "BACKGROUND")
        b.edge:SetPoint("TOPLEFT", -1, 1); b.edge:SetPoint("BOTTOMRIGHT", 1, -1); b.edge:SetColorTexture(0.45, 0.45, 0.45, 1)
        b.bg = b:CreateTexture(nil, "BORDER")
        b.bg:SetAllPoints(); b.bg:SetColorTexture(0.1, 0.1, 0.1, 0.95)
        b.hl = b:CreateTexture(nil, "HIGHLIGHT")
        b.hl:SetAllPoints(); b.hl:SetColorTexture(1, 1, 1, 0.18)
        b.label = b:CreateFontString(nil, "ARTWORK", "GameFontNormal")
        b.label:SetPoint("CENTER"); b.label:SetText(text)
        b:SetScript("OnEnter", Tip); b:SetScript("OnLeave", TipOff)
        return b
    end

    local function Check(x, y, label, tip, optKey, get, set)
        local b = CreateFrame("CheckButton", nil, f)
        b:SetSize(26, 26); b:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
        b:SetNormalTexture("Interface\\Buttons\\UI-CheckBox-Up")
        b:SetPushedTexture("Interface\\Buttons\\UI-CheckBox-Down")
        b:SetHighlightTexture("Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
        b:SetCheckedTexture("Interface\\Buttons\\UI-CheckBox-Check")
        b.fs = b:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        b.fs:SetPoint("LEFT", 24, 0); b.fs:SetWidth(172); b.fs:SetJustifyH("LEFT"); b.fs:SetWordWrap(false)
        b.fs:SetText(label)
        b:SetHitRectInsets(0, -170, 0, 0)
        b.tip, b.optKey = tip, optKey
        b:SetScript("OnEnter", Tip); b:SetScript("OnLeave", TipOff)
        b:SetScript("OnClick", function() set(not get()); Refresh() end)
        b.refresh = function() b:SetChecked(get() and true or false) end
        controls[#controls + 1] = b
        return b
    end

    -- slider simples (trilho + marcador); rotulo em cima, valor a direita (como no Leatrix)
    local function Slide(x, y, label, tip, optKey, lo, hi, step, get, set, fmt)
        local s = CreateFrame("Slider", nil, f)
        s:SetOrientation("HORIZONTAL"); s:SetSize(110, 16); s:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
        s:SetHitRectInsets(0, 0, -6, -6)
        local track = s:CreateTexture(nil, "BACKGROUND")
        track:SetPoint("LEFT", s, "LEFT", 0, 0); track:SetPoint("RIGHT", s, "RIGHT", 0, 0)
        track:SetHeight(5); track:SetColorTexture(0.35, 0.35, 0.35, 1)
        local thumb = s:CreateTexture(nil, "OVERLAY")
        thumb:SetSize(10, 20); thumb:SetColorTexture(1, 0.82, 0, 1)
        s:SetThumbTexture(thumb)
        s:SetMinMaxValues(lo, hi); s:SetValueStep(step)
        if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
        if s.EnableMouseWheel then s:EnableMouseWheel(true) end
        s.lab = s:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        s.lab:SetPoint("TOP", s, "TOP", 0, 14); s.lab:SetText(label)
        s.val = s:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        s.val:SetPoint("LEFT", s, "RIGHT", 12, 0)
        s.tip, s.optKey, s.syncing = tip, optKey, false
        s:SetScript("OnEnter", Tip); s:SetScript("OnLeave", TipOff)
        s:SetScript("OnValueChanged", function(self, v)
            if self.syncing then return end
            v = math.floor((v - lo) / step + 0.5) * step + lo
            set(tonumber(string.format("%.2f", v)))
            self.val:SetText(fmt(get()))
        end)
        s:SetScript("OnMouseWheel", function(self, d)
            local v = get() + step * d
            if v < lo then v = lo elseif v > hi then v = hi end
            self:SetValue(v)
        end)
        s.refresh = function()
            s.syncing = true; s:SetValue(get()); s.syncing = false
            s.val:SetText(fmt(get()))
        end
        controls[#controls + 1] = s
        return s
    end

    local function Pct(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end
    local function Int(v) return tostring(math.floor(v + 0.5)) end

    ---------------------------------------------------------------- coluna esquerda
    Heading("Geral", 16, -72)
    Check(16, -92, "Addon ativo", "Liga/desliga todo o MVAT.", "enabled",
        function() return DB.enabled end,
        function(v) DB.enabled = v; if not v then hud:Hide() end end)
    Check(16, -114, "Mostrar só em combate", "Esconde o ícone fora de combate (some o lembrete de buffs).", "combatOnly",
        function() return DB.combatOnly end, function(v) DB.combatOnly = v end)
    Check(16, -136, "Mostrar o motivo", "Mostra o texto explicativo abaixo do ícone.", "showText",
        function() return DB.showText end, function(v) DB.showText = v; ApplyLayout() end)
    Check(16, -158, "Só habilidades da barra", "Só sugere o que está em alguma das suas barras de ação.|n|nDesligado, sugere tudo que você já aprendeu.", "barOnly",
        function() return DB.barOnly end, function(v) DB.barOnly = v end)
    Check(16, -180, "Travar posição do ícone", "Desmarque para MOVER: o ícone e cada painel de aviso (cast, chefe, LIMPAR) ganham um retângulo azul para arrastar com o botão esquerdo. Depois marque de novo para travar.|n|nTravado, o clique atravessa tudo.", "locked",
        function() return DB.locked end,
        function(v) DB.locked = v; ApplyLayout(); if v then hud:Hide() else HideSuggestion() end end)

    ---------------------------------------------------------------- coluna direita
    Heading("Painéis", 225, -72)
    Check(225, -92, "LIMPAR: debuffs do grupo", "Mostra quem do grupo/raide tem veneno, doença, maldição ou magia que a sua classe remove, com a habilidade e a tecla.|n|nFunciona em combate.", "purge",
        function() return DB.purge end, function(v) DB.purge = v end)
    Check(225, -114, "Casts de chefes e elites", "Mostra o que os outros inimigos (não só o alvo) estão castando e em quem.", "ecasts",
        function() return DB.ecasts end, function(v) DB.ecasts = v end)
    Check(225, -136, "Botão no minimapa", "Mostra o ícone do MVAT na borda do minimapa.|n|nClique abre estas opções; arraste para mover em volta do minimapa.", "minimap",
        function() return DB.minimap end, function(v) DB.minimap = v; extra.minimapUpdate() end)

    ---------------------------------------------------------------- sua classe (papel + preferencias)
    Check(225, -158, "Mostrar próximos passos", "Ao lado do ícone aparece DEPOIS: as próximas habilidades disponíveis. Ajuda a aprender a sequência (combo).", "queue",
        function() return DB.queue end, function(v) DB.queue = v end)

    local CLS, CLSNAME = select(2, UnitClass("player")), select(1, UnitClass("player"))
    local ROLE_NAME = { auto = "Automático", dps = "Dano", tank = "Tank", heal = "Cura" }
    local CH = {
        paladin_aura = { { "auto", "Automática" }, { "devotion", "Devoção" }, { "retribution", "Retribuição" },
                         { "concentration", "Concentração" }, { "sanctity", "Santidade" }, { "fireres", "Res. Fogo" } },
        shaman_shield = { { "auto", "Automático" }, { "lightning", "Raio" }, { "water", "Água" } },
        mage_armor = { { "auto", "Automática" }, { "ice", "Gelo" }, { "mage", "Mágica" }, { "molten", "Derretida" } },
        mage_spell = { { "auto", "Automática" }, { "arcane", "Arcano" }, { "fire", "Fogo" }, { "frost", "Gelo" } },
        lock_curse = { { "auto", "Automática" }, { "elements", "Elementos" }, { "weakness", "Fraqueza" },
                       { "recklessness", "Imprudência" }, { "none", "Nenhuma" } },
        hunter_aspect = { { "auto", "Automático" }, { "hawk", "Falcão" }, { "monkey", "Macaco" }, { "cheetah", "Chita" },
                          { "beast", "Fera" }, { "pack", "Alcateia" } },
        rogue_opener = { { "auto", "Automática" }, { "ambush", "Emboscada" }, { "cheap", "Golpe Baixo" }, { "garrote", "Garrote" } },
    }
    -- por classe: papeis possiveis e preferencias { chave, rotulo, lista de escolhas, dica }
    local UI = {
        PALADIN = { roles = { "auto", "dps", "tank", "heal" }, seal = true,
                    opts = { { "aura", "Aura", CH.paladin_aura, "Qual aura o addon lembra de manter." } } },
        PRIEST = { roles = { "auto", "dps", "heal" } },
        SHAMAN = { roles = { "auto", "dps", "heal" }, opts = { { "shield", "Escudo", CH.shaman_shield, "Escudo elemental a manter (Automático: Água para curar, Raio para o resto)." } } },
        DRUID = { roles = { "auto", "dps", "tank", "heal" } },
        WARRIOR = { roles = { "auto", "dps", "tank" } },
        MAGE = { opts = { { "armor", "Armadura", CH.mage_armor, "Armadura a manter." },
                          { "spell", "Magia principal", CH.mage_spell, "Qual magia usar como principal (Automático: pela especialização que você aprendeu)." } } },
        WARLOCK = { opts = { { "curse", "Maldição", CH.lock_curse, "Maldição de utilidade a aplicar (o Bane de Agonia é separado)." } } },
        HUNTER = { opts = { { "aspect", "Aspecto", CH.hunter_aspect, "Aspecto a manter (Automático: Falcão quando atacar de longe)." } } },
        ROGUE = { opts = { { "opener", "Abertura", CH.rogue_opener, "Golpe para abrir o combate furtivo (Automático: Emboscada com adaga)." } } },
    }
    local spec = UI[CLS]
    if spec then
        Heading("Sua classe: " .. (CLSNAME or CLS), 225, -190)
        local by = -212
        local function CycleButton(labelFn, cycleFn, tip, optKey)
            local b = Button("", 200, 24)
            b:SetPoint("TOPLEFT", f, "TOPLEFT", 225, by); by = by - 28
            b.tip, b.optKey = tip, optKey
            b:SetScript("OnClick", function() cycleFn(); Refresh() end)
            b.refresh = function() b.label:SetText(labelFn()) end
            controls[#controls + 1] = b
        end
        local function Next(list, cur)
            for i, v in ipairs(list) do if v == cur then return list[i % #list + 1] end end
            return list[1]
        end
        if spec.roles then
            CycleButton(function()
                local r = (DB.roles and DB.roles[CLS]) or "auto"
                if r == "auto" then
                    local eff = RL.role()
                    return "Papel: Automático" .. (eff and (" (" .. ROLE_NAME[eff] .. ")") or "")
                end
                return "Papel: " .. ROLE_NAME[r]
            end, function()
                DB.roles = DB.roles or {}
                DB.roles[CLS] = Next(spec.roles, DB.roles[CLS] or "auto")
            end, "Clique para trocar.|n|nAutomático: o addon lê seus pontos de talento (e a forma de Urso do Druida).|nDano: rotação e combos.|nTank: ameaça, provocar e defesas.|nCura: curas, HoTs, limpar debuffs e ajuda ao grupo quando o chefe castar.", "role")
        end
        if spec.seal then
            local SEALS = { "auto", "furia", "retidao", "cruzado", "comando", "luz", "sabedoria", "justica" }
            CycleButton(function()
                local cur = DB.seal or "auto"
                local key = SEAL_PREF[cur]
                return cur == "auto" and "Selo: Automático" or ("Selo: " .. ((key and N[key]) or cur))
            end, function()
                local idx = 1
                for i, n in ipairs(SEALS) do if n == (DB.seal or "auto") then idx = i end end
                for step = 1, #SEALS do
                    local n = SEALS[(idx + step - 1) % #SEALS + 1]
                    local key = SEAL_PREF[n]
                    if n == "auto" or (key and Known(key)) then DB.seal = n; break end
                end
            end, "Clique para trocar o selo.|n|nAutomático: o addon escolhe pela sua arma, escudo e mana.|n|nSó aparecem os selos que você já aprendeu.", "seal")
        end
        for _, o in ipairs(spec.opts or {}) do
            local key, label, choices, tip = o[1], o[2], o[3], o[4]
            CycleButton(function()
                local cur = (DB.opts and DB.opts[CLS] and DB.opts[CLS][key]) or "auto"
                for _, ch in ipairs(choices) do if ch[1] == cur then return label .. ": " .. ch[2] end end
                return label .. ": " .. choices[1][2]
            end, function()
                DB.opts = DB.opts or {}
                DB.opts[CLS] = DB.opts[CLS] or {}
                local vals = {}
                for _, ch in ipairs(choices) do vals[#vals + 1] = ch[1] end
                DB.opts[CLS][key] = Next(vals, DB.opts[CLS][key] or "auto")
            end, tip .. "|n|nClique para trocar.", "opt_" .. key)
        end
    end

    ---------------------------------------------------------------- tamanhos
    local bMove = Button("Mover ícone e painéis", 190, 22)
    bMove:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -212); bMove.optKey = "move"
    bMove.tip = "Destrava e fecha esta janela. Arraste o ícone e cada painel de aviso (retângulos azuis) para onde quiser.|n|nUse o botão \"Travar posições\" no topo da tela quando terminar."
    bMove:SetScript("OnClick", function()
        DB.locked = false; ApplyLayout(); HideSuggestion(); f:Hide()
    end)

    Heading("Tamanho", 16, -280)
    Slide(36, -324,"Ícone e painéis", "Arraste para mudar o tamanho do ícone e de todos os painéis.", "scale", 0.5, 3, 0.1,
        function() return DB.scale end, function(v) DB.scale = v; ApplyLayout() end, Pct)
    Slide(250, -324,"Inimigos p/ modo área", "A partir de quantos inimigos o addon passa a sugerir habilidades de área (farm).", "aoe", 2, 10, 1,
        function() return DB.aoe end, function(v) DB.aoe = math.floor(v + 0.5) end, Int)
    Slide(36, -370, "Texto do motivo", "Tamanho da letra do texto abaixo do ícone. Não muda o tamanho do ícone.", "textSize", 8, 32, 1,
        function() return DB.textSize end, function(v) DB.textSize = math.floor(v + 0.5); ApplyLayout() end, Int)

    ---------------------------------------------------------------- rodape
    local close = Button("X", 30, 30)
    close:SetPoint("TOPRIGHT", 0, 0); close.optKey = "x"
    close:SetScript("OnClick", function() f:Hide() end)
    local bReset = Button("Restaurar padrão", 130, 25)
    bReset:SetPoint("BOTTOMLEFT", 16, 10); bReset.optKey = "reset"
    bReset.tip = "Volta todas as opções ao padrão (a posição do ícone também)."
    bReset:SetScript("OnClick", function()
        for k, v in pairs(DEFAULTS) do DB[k] = v end
        ApplyLayout(); Refresh()
        Msg("Posição e opções restauradas.")
    end)
    local bTest = Button("Testar ícone", 100, 25)
    bTest:SetPoint("LEFT", bReset, "RIGHT", 10, 0); bTest.optKey = "test"
    bTest.tip = "Mostra um ícone de teste por 5 segundos."
    bTest:SetScript("OnClick", function() _G.SlashCmdList.MVAT("test") end)
    local bClose = Button("Fechar", 80, 25)
    bClose:SetPoint("BOTTOMRIGHT", -16, 10); bClose.optKey = "close"
    bClose:SetScript("OnClick", function() f:Hide() end)

    f:SetScript("OnShow", function()
        f:ClearAllPoints()
        local p = DB and DB.optPos
        if p then f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
        else f:SetPoint("CENTER", UIParent, "CENTER", 0, 0) end
        Refresh()
    end)

    function extra.toggleOptions()
        if f:IsShown() then f:Hide() else f:Show() end
    end

    -- entrada em Esc > Opcoes > AddOns (nao quebra se a API nao existir)
    function extra.registerSettings()
        pcall(function()
            local panel = CreateFrame("Frame")
            panel.name = "MVAT"
            local b = Button("Abrir opções do MVAT", 180, 26)
            b:SetParent(panel); b:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
            b:SetScript("OnClick", function()
                if _G.HideUIPanel and _G.SettingsPanel then pcall(_G.HideUIPanel, _G.SettingsPanel) end
                extra.toggleOptions()
            end)
            if _G.Settings and _G.Settings.RegisterCanvasLayoutCategory then
                local cat = _G.Settings.RegisterCanvasLayoutCategory(panel, "MVAT")
                _G.Settings.RegisterAddOnCategory(cat)
            elseif _G.InterfaceOptions_AddCategory then
                _G.InterfaceOptions_AddCategory(panel)
            end
        end)
    end
end
extra.buildOptions()

---------------------------------------------------------------------------
-- 12. BOTAO NO MINIMAPA (clique abre as opcoes; arraste para contornar o minimapa)
---------------------------------------------------------------------------
do
    local mm = _G.Minimap
    local btn
    local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end

    local function Place()
        if not (btn and DB) then return end
        local a = math.rad(DB.minimapAngle or 215)
        local w = (mm:GetWidth() or 140) / 2 + 5
        local x, y = math.cos(a) * w, math.sin(a) * w
        -- minimapa quadrado (ElvUI etc.): encosta o botao na borda do quadrado
        local shape = _G.GetMinimapShape and _G.GetMinimapShape() or "ROUND"
        if shape == "SQUARE" then
            local m = math.max(math.abs(x), math.abs(y))
            if m > 0 then x, y = x / m * w, y / m * w end
        end
        btn:ClearAllPoints()
        btn:SetPoint("CENTER", mm, "CENTER", x, y)
    end

    local function Drag()
        local mx, my = mm:GetCenter()
        local cx, cy = _G.GetCursorPosition()
        local s = mm:GetEffectiveScale()
        DB.minimapAngle = math.deg(atan2(cy / s - my, cx / s - mx)) % 360
        Place()
    end

    if mm then
        btn = CreateFrame("Button", "MVAT_MinimapButton", mm)
        btn:SetSize(31, 31)
        btn:SetFrameStrata("MEDIUM"); btn:SetFrameLevel((mm:GetFrameLevel() or 1) + 8)
        btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        btn:RegisterForDrag("LeftButton")
        local hl = btn:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(); hl:SetTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
        local back = btn:CreateTexture(nil, "BACKGROUND")
        back:SetSize(24, 24); back:SetPoint("TOPLEFT", 4, -4); back:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
        btn.icon = btn:CreateTexture(nil, "ARTWORK")
        btn.icon:SetSize(19, 19); btn.icon:SetPoint("CENTER", 0, 0)
        btn.icon:SetTexture("Interface\\Icons\\INV_Misc_Eye_02"); btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        local ring = btn:CreateTexture(nil, "OVERLAY")
        ring:SetSize(53, 53); ring:SetPoint("TOPLEFT", 0, 0); ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        btn:SetScript("OnClick", function(_, mouse)
            if mouse == "RightButton" then
                DB.enabled = not DB.enabled
                if not DB.enabled then hud:Hide() end
                Msg(DB.enabled and "MVAT ativado." or "MVAT desativado.")
            else
                extra.toggleOptions()
            end
        end)
        btn:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", Drag) end)
        btn:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
        btn:SetScript("OnEnter", function(self)
            if _G.GameTooltip then
                _G.GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                _G.GameTooltip:SetText("MVAT - Tutor de Combate", 1, 0.82, 0)
                _G.GameTooltip:AddLine("Clique: abrir as opções", 1, 1, 1)
                _G.GameTooltip:AddLine("Botão direito: ligar/desligar o addon", 1, 1, 1)
                _G.GameTooltip:AddLine("Arraste: mover em volta do minimapa", 0.7, 0.7, 0.7)
                _G.GameTooltip:Show()
            end
        end)
        btn:SetScript("OnLeave", function() if _G.GameTooltip then _G.GameTooltip:Hide() end end)
        btn:Hide()
    end

    function extra.minimapUpdate()
        if not btn or not DB then return end
        if DB.minimap then Place(); btn:Show() else btn:Hide() end
    end
end

local function Slash(input)
    local cmd, arg = (input or ""):lower():match("^(%S*)%s*(.-)$")
    if cmd == "unlock" or cmd == "destravar" then
        DB.locked = false; ApplyLayout(); HideSuggestion(); Msg("Destravado: arraste o icone. Use /mvat lock para travar.")
    elseif cmd == "lock" or cmd == "travar" then
        DB.locked = true; ApplyLayout(); hud:Hide(); Msg("Travado e posicao salva.")
    elseif cmd == "" or cmd == "opcoes" or cmd == "options" or cmd == "config" or cmd == "menu" then
        extra.toggleOptions()
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
            -- exemplo do painel de cast de chefe com as SUAS habilidades (so aprendidas)
            local function firstKnown(list) for _, k in ipairs(list or {}) do if Known(k) then return k end end end
            local role = RL.role()
            local kk = firstKnown(KICKS[playerClass])
            local dk = firstKnown((role == "tank" and RL.TD[playerClass]) or DEFENSES[playerClass]) or firstKnown(DEFENSES[playerClass])
            local gk = (role == "heal" and firstKnown(RL.GH[playerClass])) or firstKnown(RL.AS[playerClass])
            cast.enemy.icon:SetTexture(ICON[key] or 134400)
            cast.name:SetText("Exemplo: feitico do chefe")
            for _, p in ipairs({ { cast.kick, kk }, { cast.def, dk }, { cast.grp, gk } }) do
                if p[2] then
                    p[1].icon:SetTexture(ICON[p[2]] or 134400); p[1].key:SetText(GetKeybind(p[2])); p[1]:SetAlpha(1); p[1]:Show()
                else p[1]:Hide() end
            end
            cast.hint:SetText(RL.HINT[role or "dps"] or "")
            cast:Show()
        else Msg("Nenhuma habilidade conhecida encontrada.") end
    elseif cmd == "selo" or cmd == "seal" then
        if playerClass ~= "PALADIN" then Msg("O comando de selo e so do Paladino."); return end
        local want = SEAL_PREF[arg]
        if arg == "" then
            Msg("Selo: " .. tostring(DB.seal) .. ". Use /mvat selo auto | retidao | furia | cruzado | comando | luz | sabedoria | justica")
        elseif not want then
            Msg("Nao conheco o selo '" .. arg .. "'. Use: auto, retidao, furia, cruzado, comando, luz, sabedoria, justica")
        else
            DB.seal = (want == "auto") and "auto" or arg
            Msg(want == "auto" and "Selo AUTOMATICO: o addon escolhe pelo alvo, arma e escudo."
                or ("Selo fixado em " .. (N[want] or arg) .. "."))
        end
    elseif cmd == "limpar" or cmd == "purge" then
        DB.purge = not DB.purge
        Msg(DB.purge and "Painel LIMPAR ligado: mostra quem no grupo tem debuff que voce remove."
            or "Painel LIMPAR desligado.")
    elseif cmd == "casts" then
        DB.ecasts = not DB.ecasts
        Msg(DB.ecasts and "Painel de casts de outros inimigos ligado." or "Painel de casts de outros inimigos desligado.")
    elseif cmd == "papel" or cmd == "role" then
        local cls = select(2, UnitClass("player"))
        local MAP = { auto = "auto", dano = "dps", dps = "dps", tank = "tank", cura = "heal", heal = "heal", healer = "heal" }
        if not RL.TABS[cls] then Msg("Sua classe so tem o papel de dano; nao ha o que trocar.")
        elseif not MAP[arg] then Msg("Use: /mvat papel auto | dano | tank | cura  (agora: " .. tostring(RL.role() or "auto") .. ")")
        else
            DB.roles = DB.roles or {}
            DB.roles[cls] = MAP[arg]
            Msg("Papel: " .. arg .. (MAP[arg] == "auto" and (" (detectado: " .. tostring(RL.role() or "dano") .. ")") or "") .. ".")
        end
    elseif cmd == "spells" or cmd == "magias" then
        -- habilidades do seu grimorio que o addon ainda nao conhece (para eu acrescentar as regras)
        local seen, out = {}, {}
        for _, nm in pairs(N) do seen[nm] = true end
        local function add(name, id)
            name = Pub(name)
            if name and not seen[name] then seen[name] = true; out[#out + 1] = name .. (id and (" (" .. id .. ")") or "") end
        end
        if C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines and Enum and Enum.SpellBookSpellBank then
            local bank = Enum.SpellBookSpellBank.Player
            for t = 1, C_SpellBook.GetNumSpellBookSkillLines() do
                local line = C_SpellBook.GetSpellBookSkillLineInfo(t)
                if line then
                    for i = line.itemIndexOffset + 1, line.itemIndexOffset + line.numSpellBookItems do
                        local info = C_SpellBook.GetSpellBookItemInfo and C_SpellBook.GetSpellBookItemInfo(i, bank)
                        add(C_SpellBook.GetSpellBookItemName(i, bank), info and Pub(info.spellID))
                    end
                end
            end
        end
        Msg(#out .. " habilidades no grimorio sem regra no MVAT (me mande esta lista):")
        local line = ""
        for _, e in ipairs(out) do
            if #line + #e > 170 then Msg(line); line = "" end
            line = line .. (line == "" and "" or ", ") .. e
        end
        if line ~= "" then Msg(line) end
    elseif cmd == "barra" or cmd == "bar" then
        DB.barOnly = not DB.barOnly
        Msg(DB.barOnly and ("So sugere habilidades que estao nas suas barras (" .. barCount .. " encontradas).")
            or "Sugere qualquer habilidade que voce ja aprendeu, mesmo fora das barras.")
    elseif cmd == "debug" then
        local count = 0
        for _, rule in ipairs(rules) do for _, k in ipairs(rule.pick) do if Known(k) then count = count + 1 end end end
        Msg(string.format("MVAT v%s | Classe %s | %d regras | %d habilidades aprendidas usadas | inimigos %s",
            extra.version(), tostring(playerClass), #rules, count, tostring(c.enemies)))
        Msg(string.format("Barras: %d habilidades (filtro %s) | arma: %s, %.1fs | escudo: %s",
            barCount, DB.barOnly and "LIGADO" or "desligado", gear.twoHand and "duas maos" or "uma mao", gear.speed,
            gear.shield and "sim" or "nao"))
        Msg("Papel: " .. tostring(RL.role() or "automatico") .. (RL.detected and (" (detectado pelos talentos: " .. RL.detected .. ")")
            or " - talentos ilegiveis neste cliente: o addon decide pelo ALVO (inimigo = dano, aliado = cura)"))
        if playerClass == "PALADIN" and paladin.choose then
            local have = {}
            for _, k in ipairs(SEAL_KEYS) do if Known(k) then have[#have + 1] = (N[k] or k) .. (OnBar(N[k]) and "" or " (fora da barra)") end end
            Msg("Selos que voce tem: " .. (#have > 0 and table.concat(have, ", ") or "nenhum"))
            local k, why = paladin.choose(c)
            Msg("Selo escolhido: " .. (k and ((N[k] or k) .. " - " .. why) or "nenhum disponivel") .. " | modo tanque: " .. tostring(paladin.tankMode() and true or false))
            local left = paladin.sealLeft()
            Msg("Selo ativo: " .. (sealState.key and (N[sealState.key] or sealState.key) or "nenhum") .. (left and string.format(" (%ds)", math.floor(left)) or ""))
        end
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
            local function known3(v) if v == nil then return "nao medido" end return yn(not v) end
            Msg("Alvo inimigo " .. known3(combatSnap.target) .. " | habilidade usavel " .. known3(combatSnap.usable)
                .. " | cast do alvo detectado: " .. (combatSnap.casts > 0 and "sim" or "nao")
                .. (combatSnap.casts > 0 and (" (nome " .. yn(combatSnap.castSecret) .. ")") or ""))
            Msg("Recarga (isActive) " .. known3(combatSnap.cd)
                .. " | procs (brilho da Blizzard): " .. procSeen
                .. " | sugestoes mostradas: " .. combatSnap.shown)
        else
            Msg("Entre em combate uma vez e rode /mvat diag de novo.")
        end
        if castState.count > 0 then
            Msg("Painel de cast: " .. castState.count .. " casts vistos | nome " .. yn(not castState.nameReadable)
                .. " | interrompivel " .. yn(not castState.intReadable)
                .. " | cast em voce " .. yn(not castState.meReadable))
        else
            Msg("Painel de cast: nenhum cast de inimigo visto (teste com um mob que lance feitico)")
        end
        Msg("Casts de outros inimigos: " .. extra.ecasts .. " vistos | erro: " .. tostring(extra.ecastErr or "nenhum"))
        Msg("LIMPAR grupo: " .. extra.purgeScans .. " leituras | " .. extra.purgeHits .. " debuffs removiveis vistos"
            .. " | filtro nativo " .. ((C_UnitAuras and C_UnitAuras.GetAuraSlots) and "existe" or "|cffff5555nao existe|r")
            .. " | erro: " .. tostring(extra.purgeErr or "nenhum"))
        Msg("Seus casts: " .. castSeen .. " eventos, " .. castReadable .. " legiveis | combos por sequencia "
            .. (castReadable > 0 and "|cff55ff55ATIVOS|r" or "|cffff5555sem dados|r"))
        Msg("Encontro: ENCOUNTER_WARNING " .. (encState.valid and "existe" or "nao existe")
            .. " (" .. encState.warning .. " recebidos) | timeline " .. (encState.validTimeline and "existe" or "nao existe")
            .. " (" .. encState.timeline .. " eventos)")
        Msg("Ultimo erro capturado: " .. (lastError and tostring(lastError) or "nenhum"))
        lastError = nil -- o proximo diag mostra so erros novos
    else
        Msg("Digite /mvat sem nada para abrir a janela de opcoes. Atalhos: lock | unlock | scale | aoe | combat | text | barra | selo | papel | spells | limpar | casts | test | reset | on | off | debug | diag")
    end
end

SLASH_MVAT1, SLASH_MVAT2 = "/mvat", "/tutor"
SlashCmdList.MVAT = Slash
