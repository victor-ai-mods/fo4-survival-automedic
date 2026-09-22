"""
Классификация MGEF: что именно делает магический эффект.

Разбор структуры MGEF.DATA (152 байта) сделан эмпирически — сравнением
одинаковых смещений у эффектов с говорящими EditorID (см. reports/wiki_diff.md,
раздел «Как выведена раскладка MGEF»):

  DATA+0x00  u32  флаги
  DATA+0x40  u32  Archetype (enum)
  DATA+0x44  u32  Actor Value — FormID записи AVIF (а НЕ индекс, как в Skyrim)
  DATA+0x58  u32  второй Actor Value (для Archetype = DualValueModifier)

Проверки, на которых это держится:
  RestoreHealthFood  -> AV = 0x2D4 = AVIF "Health"
  RestoreRadsChem    -> AV = 0x2E1 = AVIF "Rads"
  FortifyStrengthBuff-> AV = AVIF "Strength", Archetype 34 = PeakValueModifier
  RestoreHealthStimpak -> Archetype 31 = ValueAndParts (ОЗ + конечности)
  FortifyResistRadsRadX -> Archetype 5 = DualValueModifier, заполнены оба AV

Флаг «вредный» (0x00000004) подтверждён примерно на десятке пар, где направление
эффекта прямо написано в EditorID:
  RestoreRadsChem   0x00180800 (нет 0x4)  <-> DamageRadiationChem 0x04000804 (есть)
  FortifyStrengthAlcohol 0x902 (нет)      <-> ReduceIntelligenceAlcohol 0x906 (есть)
  RestoreHealthFood                       <-> DamageHealthPoison 0x005 (есть)
  RestoreAddictionJet 0x00080000 (нет)    <-> AddictionOddsJet 0x8004 (есть)
"""

import struct

FLAG_HOSTILE = 0x00000001
FLAG_RECOVER = 0x00000002
FLAG_DETRIMENTAL = 0x00000004

ARCH_VALUE_MODIFIER = 0
ARCH_SCRIPT = 1
ARCH_DISPEL = 2
ARCH_CURE_DISEASE = 3
ARCH_ABSORB = 4
ARCH_DUAL_VALUE_MODIFIER = 5
ARCH_CURE_ADDICTION = 28
ARCH_VALUE_AND_PARTS = 31
ARCH_PEAK_VALUE_MODIFIER = 34

ARCHETYPE_NAMES = {
    0: 'ValueModifier', 1: 'Script', 2: 'Dispel', 3: 'CureDisease', 4: 'Absorb',
    5: 'DualValueModifier', 6: 'Calm', 7: 'Demoralize', 8: 'Frenzy', 9: 'Disarm',
    10: 'CommandSummoned', 11: 'Invisibility', 12: 'Light', 13: 'Darkness',
    14: 'NightEye', 15: 'Lock', 16: 'Open', 17: 'BoundWeapon', 18: 'SummonCreature',
    19: 'DetectLife', 20: 'Telekinesis', 21: 'Paralysis', 22: 'Reanimate',
    23: 'SoulTrap', 24: 'TurnUndead', 25: 'Guide', 26: 'WerewolfFeed',
    27: 'CureParalysis', 28: 'CureAddiction', 29: 'CurePoison', 30: 'Concussion',
    31: 'ValueAndParts', 32: 'AccumulateMagnitude', 33: 'Stagger',
    34: 'PeakValueModifier', 35: 'Cloak', 36: 'Werewolf', 37: 'SlowTime',
    38: 'Rally', 39: 'EnhanceWeapon', 40: 'SpawnHazard', 41: 'Etherealize',
    42: 'Banish', 43: 'SpawnScriptedRef', 44: 'Disguise', 45: 'GrabActor',
    46: 'VampireLord', 49: 'Chameleon',
}

# AVIF, по которым планировщик принимает решения (§2, §4 плана).
AV_HEALTH = 'Health'
AV_RADS = 'Rads'
AV_ACTION_POINTS = 'ActionPoints'

# Роли, которые понимает планировщик. Всё, что не попало ни в одну из «полезных»,
# сваливается в buff/debuff/other — этого достаточно для §3.
ROLE_HEAL_HP = 'heal_hp'              # абсолютные ОЗ
ROLE_HEAL_HP_PCT = 'heal_hp_pct'      # доля максимума ОЗ (стимпак, масштабируется Medic)
ROLE_DAMAGE_HP = 'damage_hp'
ROLE_MAXHP_BUFF = 'maxhp_buff'        # НЕ лечение: поднимает потолок ОЗ на время
ROLE_RADS_REMOVE = 'rads_remove'
ROLE_RADS_ADD = 'rads_add'
ROLE_AP_RESTORE = 'ap_restore'
ROLE_CURE_DISEASE = 'cure_disease'
ROLE_CURE_ADDICTION = 'cure_addiction'
ROLE_ADDICTION_ODDS = 'addiction_odds'
ROLE_BUFF = 'buff'
ROLE_DEBUFF = 'debuff'
ROLE_SCRIPT = 'script'
ROLE_OTHER = 'other'

# Эти роли планировщик считает «полезной работой» предмета.
USEFUL_ROLES = {
    ROLE_HEAL_HP, ROLE_HEAL_HP_PCT, ROLE_RADS_REMOVE, ROLE_AP_RESTORE,
    ROLE_CURE_DISEASE, ROLE_CURE_ADDICTION,
}


class MgefInfo:
    __slots__ = ('key', 'editor_id', 'name', 'archetype', 'flags', 'av', 'av2',
                 'role', 'conditions')

    def __init__(self, key, editor_id, name, archetype, flags, av, av2, role):
        self.conditions = []
        self.key = key
        self.editor_id = editor_id
        self.name = name
        self.archetype = archetype
        self.flags = flags
        self.av = av
        self.av2 = av2
        self.role = role

    @property
    def detrimental(self):
        return bool(self.flags & FLAG_DETRIMENTAL)

    def as_dict(self):
        return {
            'key': self.key,
            'editorId': self.editor_id,
            'name': self.name,
            'archetype': self.archetype,
            'archetypeName': ARCHETYPE_NAMES.get(self.archetype, str(self.archetype)),
            'flags': '0x%08X' % self.flags,
            'detrimental': self.detrimental,
            'actorValue': self.av,
            'actorValue2': self.av2,
            'role': self.role,
            'conditions': [c.as_dict() for c in self.conditions],
        }


# Эффекты с Archetype = Script: что они делают, знает только их папирус-скрипт,
# офлайн это не выводится. Смысл перечисленных ниже установлен по EditorID и уже
# подтверждён на практике в прошлых модах, поэтому роль назначается вручную.
# Список намеренно короткий: всё, чего в нём нет, остаётся `script`.
SCRIPT_ROLE_OVERRIDES = {
    'HC_Antiboitics_Effect': ROLE_CURE_DISEASE,   # опечатка в EditorID — от Bethesda
}


def parse_data(blob):
    """(flags, archetype, avFormId, av2FormId) из MGEF.DATA."""
    flags = struct.unpack_from('<I', blob, 0x00)[0]
    archetype = struct.unpack_from('<I', blob, 0x40)[0]
    av = struct.unpack_from('<I', blob, 0x44)[0]
    av2 = struct.unpack_from('<I', blob, 0x58)[0]
    return flags, archetype, av, av2


def classify(archetype, flags, av_name):
    harmful = bool(flags & FLAG_DETRIMENTAL)
    av = av_name or ''

    if archetype == ARCH_VALUE_AND_PARTS:
        # Стимпак и его родня: лечит ОЗ долей максимума и чинит конечности.
        return ROLE_DAMAGE_HP if harmful else ROLE_HEAL_HP_PCT
    if archetype == ARCH_CURE_DISEASE:
        return ROLE_CURE_DISEASE
    if archetype == ARCH_CURE_ADDICTION:
        return ROLE_CURE_ADDICTION

    if av == AV_HEALTH:
        if archetype == ARCH_VALUE_MODIFIER:
            return ROLE_DAMAGE_HP if harmful else ROLE_HEAL_HP
        if archetype == ARCH_PEAK_VALUE_MODIFIER:
            # FortifyHealthFood и подобные поднимают ПОТОЛОК ОЗ, а не лечат.
            # Спутать их с лечением — прямая ошибка планирования.
            return ROLE_DEBUFF if harmful else ROLE_MAXHP_BUFF
    if av == AV_RADS:
        return ROLE_RADS_ADD if harmful else ROLE_RADS_REMOVE
    if av == AV_ACTION_POINTS and archetype == ARCH_VALUE_MODIFIER and not harmful:
        return ROLE_AP_RESTORE
    if av.startswith('Addiction'):
        return ROLE_ADDICTION_ODDS if harmful else ROLE_CURE_ADDICTION

    if archetype == ARCH_SCRIPT:
        return ROLE_SCRIPT
    if archetype in (ARCH_VALUE_MODIFIER, ARCH_PEAK_VALUE_MODIFIER,
                     ARCH_DUAL_VALUE_MODIFIER):
        return ROLE_DEBUFF if harmful else ROLE_BUFF
    return ROLE_OTHER
