"""
Разбор и офлайн-вычисление CTDA.

Зачем это нужно. У почти каждой еды в Fallout4.esm ДВА эффекта лечения с
взаимоисключающими условиями: «нет перка Wasteland Survival Guide» -> 1.0 ОЗ/с
и «перк есть» -> 1.5 ОЗ/с. Если их просто сложить, таблица получит ОЗ в 2.5 раза
больше правды (морковь: 25 вместо 10). Точно так же у стимпака висит
`RestoreRadsCompanion` (1000 рад!), действующий только на компаньона.
Поэтому эффекты нужно отбирать по условиям, а не суммировать подряд.

CTDA — 32 байта, `<B3sfHHIIHHIi`:
  op+flags(1) unused(3) comparison(float) functionIndex(u16) pad(u16)
  param1(u32) param2(u32) runOnType(u16) pad2(u16) reference(u32) param3(i32)

Оператор — старшие 3 бита первого байта, младшие биты — флаги; бит 0x01
означает «ИЛИ со следующим условием».

Подтверждение раскладки оператора: у эффектов адреналина в NukaWorld идут пары
условий на `HC_Adrenaline` с comparison 5/10/…/50 и байтами 96 и 128.
96>>5 = 3 (>=), 128>>5 = 4 (<) — получается «адреналин в диапазоне [X, Y)»,
что единственно осмысленно.

Индексы функций опознаны по типам записей, на которые указывает param1:
  14  GetActorValue   — param1 = AVIF (HC_HungerEffect, HC_ThirstEffect, ...)
  71  GetInFaction    — param1 = FACT (CurrentCompanionFaction)
  72  GetIsID         — param1 = NPC_ (Player = 0x000007)
  74  GetGlobalValue  — param1 = GLOB (HC_Rule_SustenanceEffects, ...)
  77  GetRandomPercent— бросок 0..100; опознан по `ModDisarm25Effect` и
                        `ParalyzeEffect25` («<= 25»), по `dt*EffectChanceLow`
                        и по `LongneckLukowskisRadiation` на консервах
  354 IsPlayerTeammate— без параметров, встречается в паре с GetInFaction(companion)
  448 HasPerk         — param1 = PERK (PerkMagWastelandSurvival01/03, ImmuneTo*)
Остальные индексы офлайн не трактуются: такое условие считается выполненным,
а эффект помечается `uncertain`, чтобы его было видно в отчёте.
"""

import struct

_CTDA = struct.Struct('<B3sfHHIIHHIi')

FLAG_OR = 0x01

OP_EQ, OP_NE, OP_GT, OP_GE, OP_LT, OP_LE = range(6)

FN_GET_ACTOR_VALUE = 14
FN_GET_IN_FACTION = 71
FN_GET_IS_ID = 72
FN_GET_GLOBAL_VALUE = 74
FN_GET_RANDOM_PERCENT = 77
FN_IS_PLAYER_TEAMMATE = 354
FN_HAS_PERK = 448

FUNCTION_NAMES = {
    FN_GET_ACTOR_VALUE: 'GetActorValue',
    FN_GET_IN_FACTION: 'GetInFaction',
    FN_GET_IS_ID: 'GetIsID',
    FN_GET_GLOBAL_VALUE: 'GetGlobalValue',
    FN_GET_RANDOM_PERCENT: 'GetRandomPercent',
    FN_IS_PLAYER_TEAMMATE: 'IsPlayerTeammate',
    FN_HAS_PERK: 'HasPerk',
}

PLAYER_LOCAL_ID = 0x000007


class Condition:
    __slots__ = ('op', 'comparison', 'function', 'param1', 'param2')

    def __init__(self, op, comparison, function, param1, param2):
        self.op = op
        self.comparison = comparison
        self.function = function
        self.param1 = param1
        self.param2 = param2

    @property
    def operator(self):
        return self.op >> 5

    @property
    def or_with_next(self):
        return bool(self.op & FLAG_OR)

    def as_dict(self):
        return {
            'function': FUNCTION_NAMES.get(self.function, str(self.function)),
            'operator': ['==', '!=', '>', '>=', '<', '<='][self.operator]
            if self.operator < 6 else '?',
            'comparison': self.comparison,
            'param1': self.param1,
        }


def parse(payload, resolve):
    """CTDA -> Condition; resolve(formId) превращает локальный id в глобальный ключ."""
    op, _unused, comparison, fn, _pad, p1, p2, _run, _pad2, _ref, _p3 = \
        _CTDA.unpack(payload)
    return Condition(op, comparison, fn,
                     resolve(p1) if p1 else None,
                     resolve(p2) if p2 else None)


def _compare(left, operator, right):
    if operator == OP_EQ:
        return left == right
    if operator == OP_NE:
        return left != right
    if operator == OP_GT:
        return left > right
    if operator == OP_GE:
        return left >= right
    if operator == OP_LT:
        return left < right
    if operator == OP_LE:
        return left <= right
    return True


class Profile:
    """
    Состояние, против которого считается «сработает ли эффект».

    Базовый профиль — игрок, без перков, без голода и жажды: именно такие числа
    печатает вики, поэтому по нему и идёт сверка.
    """

    def __init__(self, survival, globals_=None, actor_values=None, perks=()):
        self.survival = survival
        self.globals = globals_ or {}
        self.actor_values = actor_values or {}
        self.perks = set(perks)


def _chance_of(operator, comparison):
    """Вероятность (в процентах), с которой пройдёт бросок GetRandomPercent."""
    if operator in (OP_LT, OP_LE):
        return max(0.0, min(100.0, comparison))
    if operator in (OP_GT, OP_GE):
        return max(0.0, min(100.0, 100.0 - comparison))
    return None


def evaluate(conditions, profile, global_names, perk_names, assume_chance=False):
    """
    -> (active, uncertain, required_perks, chance)

    required_perks — перки, при наличии которых эффект включается; планировщику
    они нужны, чтобы применить масштабирование по перкам в рантайме (M7).
    chance — вероятность в процентах, если эффект висит на GetRandomPercent.

    По умолчанию бросок считается НЕ прошедшим: базовые числа таблицы должны
    описывать гарантированную часть эффекта. Вероятностная часть возвращается
    отдельно (`assume_chance=True`), чтобы планировщик мог учесть её как риск.
    """
    uncertain = False
    required_perks = []
    chance = None

    # Условия объединяются в группы по флагу «ИЛИ со следующим»; группы — И.
    groups, current = [], []
    for cond in conditions:
        current.append(cond)
        if not cond.or_with_next:
            groups.append(current)
            current = []
    if current:
        groups.append(current)

    active = True
    for group in groups:
        group_result = False
        for cond in group:
            fn = cond.function
            if fn == FN_HAS_PERK:
                value = 1.0 if cond.param1 in profile.perks else 0.0
                # Условие «перк есть» = вариант эффекта, включающийся перком.
                # Он не идёт в базовые числа, но планировщику нужен для M7.
                if cond.operator == OP_EQ and cond.comparison == 1.0:
                    required_perks.append(perk_names.get(cond.param1, cond.param1))
            elif fn == FN_GET_ACTOR_VALUE:
                value = profile.actor_values.get(cond.param1, 0.0)
            elif fn == FN_GET_GLOBAL_VALUE:
                name = global_names.get(cond.param1, '')
                if cond.param1 in profile.globals:
                    value = profile.globals[cond.param1]
                elif name.startswith('HC_Rule_'):
                    value = 1.0 if profile.survival else 0.0
                else:
                    value = 0.0
                    uncertain = True
            elif fn == FN_GET_IS_ID:
                value = 1.0 if (cond.param1 or '').endswith('0x%06X' % PLAYER_LOCAL_ID) \
                    else 0.0
            elif fn in (FN_GET_IN_FACTION, FN_IS_PLAYER_TEAMMATE):
                value = 0.0            # игрок не компаньон и ни в чьей свите
            elif fn == FN_GET_RANDOM_PERCENT:
                chance = _chance_of(cond.operator, cond.comparison)
                if assume_chance:
                    group_result = True
                    break
                continue               # бросок считаем непрошедшим
            else:
                uncertain = True
                group_result = True
                break

            if _compare(value, cond.operator, cond.comparison):
                group_result = True
                break
        if not group_result:
            active = False
    return active, uncertain, required_perks, chance
