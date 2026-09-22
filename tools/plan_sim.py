"""
Офлайн-зеркало планировщика шага 5 (AutoMedicQuestScript: EvalCandidates,
Plan, BestFor, Trim) — чтобы проверять алгоритм без игры.

Источник истины — Papyrus. Этот файл повторяет его функция в функцию и
существует ради одного: прогнать подготовленные ситуации (шаг 5, критерий
готовности) и сравнить план с посчитанным вручную ожидаемым набором ДО
игрового прогона. Правишь логику в .psc — правь и здесь.

    python tools/plan_sim.py            — все ситуации, отчёт и итог
    python tools/plan_sim.py -v         — плюс строки PICK
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_psc import item_flags, medic_fields, FLAG_VALUE  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
F = FLAG_VALUE

# --- константы AutoMedicQuestScript ---
HEAL_TRIGGER_PCT, HEAL_TARGET_PCT = 90.0, 100.0
RAD_TRIGGER_PCT, RAD_TARGET_PCT = 15.0, 0.0
RADS_MAX = 1000.0
MAX_ITEM_VALUE, MAX_DISEASE_RISK_PCT = 150.0, 7
RESERVE_STIMPAKS, RESERVE_RADAWAY = 2, 1
MAX_INGESTED_RADS, RAD_CAP_WITHOUT_CURE = 50.0, True
USE_CHEMS = USE_ALCOHOL = False
HP_TOLERANCE_PCT, RAD_TOLERANCE, MAX_PLAN_ITEMS = 2.0, 10.0, 12
COST_PER_ITEM, COST_PER_RISK_PCT = 5.0, 5.0
COST_IMMUNO, COST_IMMUNO_ACTIVE, COST_SCARCITY = 60.0, 15.0, 10.0
MIN_SCORE_RADS = 0.5  # MIN_SCORE_HP снят 2026-09-22: ОЗ — минимум перелечения
HUNGER_TARGET = 0
# Шаг 7: запас еды (MCM FoodReserve / FoodReserveCountRad). Дефолт игры — 10,
# но в Player он по умолчанию 0: ситуации 1-11 проверяют другие правила и
# написаны до запаса. Ситуации запаса задают food_reserve явно.
FOOD_RESERVE_DEFAULT = 10
# 2026-09-22: ОД-напитки (> AP_BIG_PCT % максимума ОД без дебафов) — только при
# ОД ниже AP_TRIGGER_PCT (MCM ApItemsBelowPct); запас колы — MCM ColaReserve.
AP_TRIGGER_PCT, AP_BIG_PCT = 30.0, 10.0
AP_ITEMS_MODE = 1  # 0 никогда, 1 только в бою, 2 всегда (MCM ApItemsMode)

NEED_RADS, NEED_LIMBS, NEED_HP, NEED_DISEASE, NEED_ADDICTION = 1, 2, 3, 4, 5
NEED_NAMES = {1: 'rads', 2: 'limbs', 3: 'hp', 4: 'disease', 5: 'addict'}


def has(flags, name):
    return bool(flags & F[name])


def load_exclusions():
    """(файл, локальный id) из data/exclusions-default.json — тот же построчный
    разбор, что ReadExclusionFile: первая строка в кавычках, если в ней есть «|»."""
    out = set()
    with open(os.path.join(ROOT, 'data', 'exclusions-default.json'), encoding='utf-8') as f:
        for line in f:
            parts = line.split('"')
            if len(parts) < 3 or '|' not in parts[1]:
                continue
            plugin, _, hexid = parts[1].partition('|')
            out.add((plugin.lower(), int(hexid, 16)))
    return out


EXCLUDED = load_exclusions()


class Table:
    def __init__(self):
        with open(os.path.join(ROOT, 'data', 'consumables.json'), encoding='utf-8') as f:
            items = json.load(f)['items']
        self.by_name = {}
        for item in items:
            row = dict(item, Flags=item_flags(item), **medic_fields(item))
            # nameRu — чтобы подставлять инвентарь прямо из строк CANDS игрового лога.
            for key in ('nameEn', 'nameRu', 'editorId'):
                if item.get(key):
                    self.by_name.setdefault(item[key], row)

    def get(self, name):
        return self.by_name[name]


class Player:
    """Снимок фазы 0 (S_*) — то, что в игре читается из AV, перков и эффектов."""

    def __init__(self, **kw):
        self.max_hp = kw.get('max_hp', 480.0)
        self.hp = kw.get('hp', self.max_hp)
        self.rads = kw.get('rads', 0.0)
        self.hunger = kw.get('hunger', 0.0)
        self.thirst = kw.get('thirst', 0.0)
        self.limbs = kw.get('limbs', 0)
        self.diseases = kw.get('diseases', 0)
        self.addictions = kw.get('addictions', 0)
        self.medic = kw.get('medic', 0)
        self.lead_belly = kw.get('lead_belly', 0)
        self.bobble = kw.get('bobble', False)
        self.immuno = kw.get('immuno', False)
        self.in_heal = kw.get('in_heal', 0.0)
        self.in_heal_pct = kw.get('in_heal_pct', 0.0)
        self.in_rad_out = kw.get('in_rad_out', 0.0)
        self.in_damage = 0.0
        self.perks = set(kw.get('perks', ()))
        self.food_reserve = kw.get('food_reserve', 0)
        self.food_reserve_rads = kw.get('food_reserve_rads', True)
        self.use_exclusions = kw.get('use_exclusions', True)
        self.ap_pct = kw.get('ap_pct', 1.0)       # GetValuePercentage(AP)
        self.ap_base = kw.get('ap_base', 90.0)    # GetBaseValue(AP)
        self.ap_max = kw.get('ap_max', self.ap_base)  # текущий максимум
        self.cola_reserve = kw.get('cola_reserve', 0)
        self.in_combat = kw.get('in_combat', False)


class Planner:
    def __init__(self, table, player, inventory, verbose=False):
        self.t = table
        self.p = player
        self.verbose = verbose
        self.notes, self.trace, self.trim = [], [], []
        self.build_needs()
        self.collect(inventory)
        self.evaluate()
        self.plan()

    # --- BuildNeeds ---
    def build_needs(self):
        p = self.p
        self.n_hunger = p.hunger - HUNGER_TARGET if p.hunger >= 1 else 0.0
        self.rad_trigger = RADS_MAX * RAD_TRIGGER_PCT / 100.0
        self.rad_target = RADS_MAX * RAD_TARGET_PCT / 100.0
        self.n_rads = self.need_rads(0.0)
        self.eff_max_now = p.max_hp * (1.0 - p.rads / RADS_MAX)
        eff_after = self.eff_max(self.n_rads, 0.0)
        pct = p.hp * 100.0 / eff_after if eff_after > 0 else 0.0
        self.hp_triggered = pct <= HEAL_TRIGGER_PCT
        self.n_hp = self.need_hp_given(self.n_rads, 0.0)
        self.n_limbs = p.limbs

    def need_rads(self, rad_in):
        p = self.p
        if p.rads + rad_in < self.rad_trigger:
            return 0.0
        return max(0.0, p.rads - p.in_rad_out + rad_in - self.rad_target)

    def eff_max(self, rad_out, rad_in):
        p = self.p
        after = max(0.0, p.rads - p.in_rad_out - rad_out + rad_in)
        return p.max_hp * (1.0 - after / RADS_MAX)

    def need_hp_given(self, rad_out, rad_in):
        if not self.hp_triggered:
            return 0.0
        p = self.p
        need = self.eff_max(rad_out, rad_in) * HEAL_TARGET_PCT / 100.0 - p.hp - (p.in_heal - p.in_damage)
        return max(0.0, need)

    def hp_tol(self):
        return self.eff_max_now * HP_TOLERANCE_PCT / 100.0

    # --- CollectCandidates (без фильтра «не нужны сейчас») ---
    def collect(self, inventory):
        self.k = []
        self.excluded = []
        for name, count in inventory.items():
            d = self.t.get(name)
            flags = d['Flags']
            why = ''
            if has(flags, 'FLAG_BLACKLISTED'):
                why = 'blacklist'
            elif self.p.use_exclusions and (d['file'].lower(), int(d['localId'], 16)) in EXCLUDED:
                why = 'exclusions file'
            elif has(flags, 'FLAG_CAT_SYRINGER'):
                why = 'syringer'
            elif not USE_CHEMS and has(flags, 'FLAG_ADDICTIVE'):
                why = 'chem'
            elif not USE_ALCOHOL and has(flags, 'FLAG_CAT_ALCOHOL'):
                why = 'alcohol'
            elif d['diseaseRiskPct'] > MAX_DISEASE_RISK_PCT:
                why = 'risk'
            elif MAX_ITEM_VALUE > 0 and d['value'] > MAX_ITEM_VALUE:
                why = 'value'
            if why:
                self.excluded.append((name, why))
                continue
            self.k.append({'name': d['nameEn'], 'd': d, 'count': count, 'flags': flags,
                           'value': d['value'], 'risk': d['diseaseRiskPct']})

    # --- EvalCandidates ---
    def medic_total(self, mag, dur, rads):
        p = self.p
        add = [0.0, 2.0, 6.0, 10.0, 27.34][min(p.medic, 4)]
        if rads:
            add *= 10.0
        bob = 1.1 if p.bobble else 1.0
        if dur > 0:
            if p.medic >= 4:
                dur -= 2.0
            return (mag + add) * dur * bob
        return (mag + add) * bob

    @staticmethod
    def plain(mag, dur):
        return mag * dur if dur > 0 else mag

    def evaluate(self):
        p = self.p
        ap_big = max(p.ap_base, p.ap_max) * AP_BIG_PCT / 100.0
        ap_low = AP_TRIGGER_PCT >= 100 or p.ap_pct * 100.0 < AP_TRIGGER_PCT
        if AP_ITEMS_MODE == 0 or (AP_ITEMS_MODE == 1 and not p.in_combat):
            ap_low = False
        for c in self.k:
            c['ap_locked'] = not ap_low and c['d'].get('apRestore', 0.0) > ap_big
            c['in_cola'] = has(c['flags'], 'FLAG_CAT_COLA')
        hunger_cands = [c for c in self.k if has(c['flags'], 'FLAG_SATES_HUNGER') and not c['ap_locked']]
        self.hunger_will_close = p.hunger < 0.5 or (self.n_hunger > 0 and HUNGER_TARGET == 0 and hunger_cands)
        lead = [1.0, 0.45, 0.35, 0.0][min(p.lead_belly, 3)]
        self.rads_count = 0
        for c in self.k:
            d, flags = c['d'], c['flags']
            c['after_food'] = has(flags, 'FLAG_CAT_FOOD') and not has(flags, 'FLAG_IGNORE_AS_FOOD')
            c['dead'] = c['after_food'] and not self.hunger_will_close
            pct = d.get('healPctOfMax', 0.0)
            if d.get('MedicHealMag', 0.0) > 0:
                pct = pct - self.plain(d['MedicHealMag'], d['MedicHealDur']) + \
                    self.medic_total(d['MedicHealMag'], d['MedicHealDur'], False)
            heal = 0.0
            if d.get('healHP', 0.0) > 0:
                heal = d['healHP']
                for v in d.get('perkScaling', ()):
                    if v['role'] == 'heal_hp' and v['amount'] > heal and set(v['perks']) & p.perks:
                        heal = v['amount']
            heal += pct * p.max_hp / 100.0
            rad_out = d.get('radsRemove', 0.0)
            if d.get('MedicRadMag', 0.0) > 0:
                rad_out = rad_out - self.plain(d['MedicRadMag'], d['MedicRadDur']) + \
                    self.medic_total(d['MedicRadMag'], d['MedicRadDur'], True)
            if c['dead']:
                heal = rad_out = 0.0
            c['heal'], c['rad_out'], c['rad_in'] = heal, rad_out, d.get('radsAdd', 0.0) * lead
            c['limbs'] = has(flags, 'FLAG_CAT_STIMPAK') and d.get('healPctOfMax', 0.0) > 0
            reserve = 0
            if c['limbs']:
                reserve = RESERVE_STIMPAKS
            elif d.get('MedicRadMag', 0.0) > 0 and d.get('MedicRadDur', 0.0) > 0:
                reserve = RESERVE_RADAWAY
            c['avail'] = max(0, c['count'] - reserve)
            if c['ap_locked']:
                c['heal'] = c['rad_out'] = 0.0
                c['avail'] = 0
            c['in_pool'] = has(flags, 'FLAG_SATES_HUNGER') and \
                (p.food_reserve_rads or d.get('radsAdd', 0.0) <= 0)
            if rad_out > 0:
                self.rads_count += 1

    # --- Plan ---
    def plan(self):
        self.P = []  # [k, need, cost]
        self.limit_hit = False
        self.reserve_hit = False
        self.plan_rads()
        self.plan_limbs()
        self.plan_cures()
        self.plan_health()
        if self.rad_short() > RAD_TOLERANCE and self.rads_count > 0 and                 'rads: rest unprofitable' not in self.notes:
            self.plan_rads()
            self.plan_health()
        self.do_trim()

    def totals(self, ex=-1):
        heal = out = rin = 0.0
        immuno = False
        for i, (c, _, _) in enumerate(self.P):
            if i == ex:
                continue
            heal += c['heal']
            out += c['rad_out']
            rin += c['rad_in']
            immuno = immuno or has(c['flags'], 'FLAG_IMMUNO_DEF')
        return heal, out, rin, immuno

    def rad_short(self, ex=-1):
        _, out, rin, _ = self.totals(ex)
        return max(0.0, self.need_rads(rin) - out)

    def hp_short(self, ex=-1):
        heal, out, rin, _ = self.totals(ex)
        return max(0.0, self.need_hp_given(out, rin) - heal)

    def food_pool(self):
        return sum(c['count'] for c in self.k if c['in_pool'])

    def cola_planned(self):
        return sum(1 for e in self.P if e[0]['in_cola'])

    def cola_pool(self):
        return sum(c['count'] for c in self.k if c['in_cola'])

    def reserve_blocks(self, c):
        if self.p.cola_reserve > 0 and c['in_cola'] and \
                self.cola_pool() - self.cola_planned() - 1 < self.p.cola_reserve:
            self.reserve_hit = True
            return True
        """ReserveBlocks: ещё одна штука опустила бы запас еды ниже порога."""
        if self.p.food_reserve <= 0 or not c['in_pool']:
            return False
        taken = sum(1 for e in self.P if e[0]['in_pool'])
        if self.food_pool() - taken - 1 < self.p.food_reserve:
            self.reserve_hit = True
            return True
        return False

    def planned(self, c):
        return sum(1 for e in self.P if e[0] is c)

    def left(self, c):
        return c['avail'] - self.planned(c)

    def cost(self, c):
        cost = c['value'] + COST_PER_ITEM
        risk = c['risk'] * COST_PER_RISK_PCT
        if has(c['flags'], 'FLAG_IMMEDIATE_CHECK'):
            risk *= 2.0
        cost += risk
        if has(c['flags'], 'FLAG_IMMUNO_DEF'):
            cost += COST_IMMUNO_ACTIVE if (self.p.immuno or self.totals()[3]) else COST_IMMUNO
        cost += COST_SCARCITY / max(1, c['count'] - self.planned(c))
        return cost

    def rads_allowed(self, c):
        if c['rad_in'] <= 0:
            return True
        rin = self.totals()[2]
        if rin + c['rad_in'] > MAX_INGESTED_RADS:
            return False
        if RAD_CAP_WITHOUT_CURE and self.rads_count == 0 and \
                self.p.rads + rin + c['rad_in'] >= self.rad_trigger:
            return False
        return True

    def gain(self, c, need, rem):
        hp_per_rad = self.p.max_hp / RADS_MAX
        if need == NEED_RADS:
            return min(c['rad_out'], rem) - c['rad_in']
        g = min(c['heal'], rem) - c['rad_in'] * hp_per_rad
        rr = self.rad_short()
        if rr > 0:
            g += min(c['rad_out'], rr) * hp_per_rad
        return g

    def best_for(self, need, rem):
        scored = []
        for c in self.k:
            fits = c['rad_out'] > 0 if need == NEED_RADS else c['heal'] > 0
            if fits and self.left(c) > 0 and self.rads_allowed(c) and not self.reserve_blocks(c):
                g = self.gain(c, need, rem)
                if g > 0:
                    scored.append((g / self.cost(c), c, g))
        if not scored:
            return None
        scored.sort(key=lambda x: -x[0])
        min_score = MIN_SCORE_RADS  # для ОЗ best_for больше не зовётся
        rejected = scored[0][0] < min_score
        self.trace.append('PICK %s rem %d: %s gain %d / cost %.1f = %.2f  (second: %s)%s' % (
            NEED_NAMES[need], rem, scored[0][1]['name'], scored[0][2], self.cost(scored[0][1]),
            scored[0][0], '%s %.2f' % (scored[1][1]['name'], scored[1][0]) if len(scored) > 1 else '-',
            '  -> REJECTED' if rejected else ''))
        if rejected:
            self.notes.append('%s: rest unprofitable' % NEED_NAMES[need])
            return None
        return scored[0][1]

    def add(self, c, need):
        if len(self.P) >= MAX_PLAN_ITEMS:
            self.limit_hit = True
            return False
        self.P.append([c, need, self.cost(c)])
        return True

    def plan_rads(self):
        rem = self.rad_short()
        while rem > RAD_TOLERANCE:
            c = self.best_for(NEED_RADS, rem)
            if c is None or not self.add(c, NEED_RADS):
                return
            rem = self.rad_short()

    def plan_limbs(self):
        if self.n_limbs <= 0:
            return
        if self.p.in_heal_pct > 0:
            self.notes.append('limbs: stimpak in flight')
            return
        cands = [c for c in self.k if c['limbs'] and self.left(c) > 0]
        if cands:
            self.add(min(cands, key=self.cost), NEED_LIMBS)

    def plan_cures(self):
        for count, flag, need in ((self.p.diseases, 'FLAG_CURES_DISEASE', NEED_DISEASE),
                                  (self.p.addictions, 'FLAG_CURES_ADDICTION', NEED_ADDICTION)):
            if count <= 0:
                continue
            cands = [c for c in self.k if has(c['flags'], flag) and not c['dead'] and not c['ap_locked']
                     and self.left(c) > 0 and self.rads_allowed(c) and not self.reserve_blocks(c)]
            if cands:
                self.add(min(cands, key=lambda c: self.cost(c) - min(c['heal'], self.hp_short()) * 0.1),
                         need)

    # --- PlanHealth: набор с минимальным перелечением (HealSearch в .psc) ---
    # Цена здесь — только последний тай-брейк: ключ сравнения наборов —
    # (не добрали?, потери ОЗ, штук, цена). Потери = перелечение (или
    # недобор, если не добрать) + потолок, съеденный радиацией еды.
    def plan_health(self):
        tol = self.hp_tol()
        rem = self.hp_short()
        if rem <= tol:
            return
        p = self.p
        hpr = p.max_hp / RADS_MAX
        tgt = HEAL_TARGET_PCT / 100.0
        heal, out, rin, _ = self.totals()
        rads_now = max(0.0, p.rads - p.in_rad_out - out + rin)
        rad_room = MAX_INGESTED_RADS - rin
        rad_cap = None
        if RAD_CAP_WITHOUT_CURE and self.rads_count == 0:
            rad_cap = self.rad_trigger - p.rads - rin
        pool_room = None
        if p.food_reserve > 0:
            taken = sum(1 for e in self.P if e[0]['in_pool'])
            pool_room = self.food_pool() - taken - p.food_reserve
        cola_room = None
        if p.cola_reserve > 0:
            cola_room = self.cola_pool() - self.cola_planned() - p.cola_reserve
        types = []
        for c in self.k:
            if c['heal'] <= 0 or self.left(c) <= 0:
                continue
            # Грязная вода и т. п.: риск с немедленной проверкой ради пары
            # десятков ОЗ не берём (раньше это отсекал MIN_SCORE_HP).
            if c['risk'] > 0 and has(c['flags'], 'FLAG_IMMEDIATE_CHECK'):
                continue
            # Радиация еды опускает потолок (нужда меньше), вывод поднимает.
            cov = c['heal'] + (c['rad_in'] - min(c['rad_out'], rads_now)) * hpr * tgt
            if cov <= 0:
                continue
            types.append({'c': c, 'cov': cov, 'pen': c['rad_in'] * hpr, 'cost': self.cost(c),
                          'left': self.left(c), 'pool': c['in_pool'] and pool_room is not None,
                          'cola': c['in_cola'] and cola_room is not None,
                          'rad': c['rad_in']})
        if not types:
            return
        types.sort(key=lambda t: (-t['cov'], t['cost']))
        s = {'rem': rem, 'goal': rem - tol, 'slots': MAX_PLAN_ITEMS - len(self.P),
             'rad_room': rad_room, 'rad_cap': rad_cap, 'pool_room': pool_room, 'cola_room': cola_room,
             'cur': [0] * len(types), 'best': None, 'nodes': 0}
        if s['slots'] <= 0:
            self.limit_hit = True
            return
        self.heal_search(types, s, 0, 0.0, 0.0, 0, 0.0, 0, 0, 0.0)
        best = s['best']
        if best is None:
            return
        self.trace.append('HEAL rem %d: %s  cls %d waste %.1f, %d nodes' % (
            rem, ' + '.join('%s x%d' % (types[i]['c']['name'], n) for i, n in enumerate(best[4]) if n),
            best[0], best[1], s['nodes']))
        for i, n in enumerate(best[4]):
            for _ in range(n):
                if not self.add(types[i]['c'], NEED_HP):
                    return
        if best[0] == 1 and s['slots'] == sum(best[4]):
            self.limit_hit = True
        if best[0] == 1 and any(t['pool'] or t['cola'] for t in types):
            self.reserve_hit = True

    HEAL_NODE_BUDGET, HEAL_EPS = 1000, 0.5

    @staticmethod
    def heal_better(a, b):
        if b is None:
            return True
        if a[0] != b[0]:
            return a[0] < b[0]
        if abs(a[1] - b[1]) > Planner.HEAL_EPS:
            return a[1] < b[1]
        if a[2] != b[2]:
            return a[2] < b[2]
        return a[3] < b[3] - 0.01

    def heal_offer(self, s, total, pen, n, cost):
        if n == 0:
            return
        if total >= s['goal']:
            key = (0, max(0.0, total - s['rem']) + pen, n, cost)
        else:
            key = (1, s['rem'] - total + pen, n, cost)
        if self.heal_better(key, s['best']):
            s['best'] = key + (list(s['cur']),)

    def heal_search(self, types, s, i, total, pen, n, cost, pool, cola, rads):
        s['nodes'] += 1
        if i >= len(types) or n >= s['slots'] or s['nodes'] > self.HEAL_NODE_BUDGET:
            self.heal_offer(s, total, pen, n, cost)
            return
        best = s['best']
        # Уже добранный набор не улучшить: следующие штуки только добавят потерь.
        if best is not None and best[0] == 0:
            lb = pen + max(0.0, total - s['rem'])
            if lb > best[1] + self.HEAL_EPS:
                return
            # Типы идут по убыванию cov: добрать — не меньше more штук.
            more = int(-(-(s['goal'] - total) // types[i]['cov'])) if total < s['goal'] else 1
            if n + more > s['slots']:
                return
            # Потери строго не улучшить, а штук выйдет больше — ничья проиграна.
            if lb >= best[1] - self.HEAL_EPS and n + more > best[2]:
                return
        t = types[i]
        mx = min(t['left'], s['slots'] - n)
        if t['pool']:
            mx = min(mx, s['pool_room'] - pool)
        if t['cola']:
            mx = min(mx, s['cola_room'] - cola)
        if t['rad'] > 0:
            room = s['rad_room'] - rads
            if s['rad_cap'] is not None:
                room = min(room, s['rad_cap'] - rads - 0.001)
            mx = min(mx, int(room // t['rad']) if room > 0 else 0)
        mx = max(0, mx)
        # Сколько штук нужно, чтобы добрать; больше — только лишнее перелечение.
        need = s['goal'] - total
        reach = int(-(-need // t['cov'])) if need > 0 else 0
        top = min(mx, reach)
        for k in range(top, -1, -1):
            s['cur'][i] = k
            args = (total + k * t['cov'], pen + k * t['pen'], n + k, cost + k * t['cost'],
                    pool + (k if t['pool'] else 0), cola + (k if t['cola'] else 0), rads + k * t['rad'])
            if k > 0 and args[0] >= s['goal']:
                s['nodes'] += 1
                self.heal_offer(s, *args[:4])
            else:
                self.heal_search(types, s, i + 1, *args)
        s['cur'][i] = 0

    def do_trim(self):
        tol_hp = self.hp_tol()
        while True:
            base_hp = max(self.hp_short(), tol_hp)
            base_rad = max(self.rad_short(), RAD_TOLERANCE)
            drop = None
            for i, (c, need, cost) in enumerate(self.P):
                if need not in (NEED_HP, NEED_RADS):
                    continue
                if self.hp_short(i) <= base_hp + 0.01 and self.rad_short(i) <= base_rad + 0.01:
                    if drop is None or cost > self.P[drop][2]:
                        drop = i
            if drop is None:
                return
            self.trim.append('%s [%s]' % (self.P[drop][0]['name'], NEED_NAMES[self.P[drop][1]]))
            del self.P[drop]

    # --- отчёт ---
    def result(self):
        """{(имя, нужда): штук} — то, с чем сравнивается ожидаемый набор."""
        out = {}
        for c, need, _ in self.P:
            key = (c['name'], NEED_NAMES[need])
            out[key] = out.get(key, 0) + 1
        return out

    def report(self):
        heal, out, rin, _ = self.totals()
        lines = ['  need hp=%d rads=%d limbs=%d | hunger closes: %s' % (
            self.n_hp, self.n_rads, self.n_limbs, bool(self.hunger_will_close))]
        if self.verbose:
            lines += ['  ' + t for t in self.trace]
        for (name, need), qty in self.result().items():
            lines.append('  PLAN %-6s <- %s x%d' % (need, name, qty))
        if self.trim:
            lines.append('  TRIM ' + ', '.join(self.trim))
        lines.append('  COVER hp %d/%d (heal %d), rads %d/%d (+%.1f eaten)  short hp %d rad %d' % (
            min(heal, self.need_hp_given(out, rin)), self.need_hp_given(out, rin), heal,
            min(out, self.need_rads(rin)), self.need_rads(rin), rin, self.hp_short(), self.rad_short()))
        if self.notes:
            lines.append('  NOTE ' + '; '.join(self.notes))
        return '\n'.join(lines)


# --- подготовленные ситуации: игрок, инвентарь, ожидаемый план ---
# Ожидание посчитано вручную из правил §4.2 (обоснование — в комментарии).
BASE_INV = {'Stimpak': 5, 'RadAway': 3, 'Purified Water': 4, 'Dirty Water': 3,
            'Grilled Radroach': 2, 'Tato': 4, 'Carrot': 3, 'Mutant Hound Chops': 2}

SCENARIOS = [
    ('1. ОЗ 30 %, сыт, без перков',
     # need = 480-144 = 336, допуск 9.6. Минимум перелечения: стимпак x2 (288)
     # + вода 40 = 328 — недобор 8 в допуске, потерь 0; с Hound Chops (60)
     # было бы 348 — перелечение 12. (До 2026-09-22 по ОЗ/крышку брались Chops.)
     dict(hp=144), BASE_INV,
     {('Stimpak', 'hp'): 2, ('Purified Water', 'hp'): 1}),
    ('2. ОЗ 30 %, голоден, еды на голод нет (M4)',
     # Голод не закроется: еда (Tato, Carrot, Radroach, Chops) мертва. Лечат
     # стимпак и вода — вода не ObjectTypeFood.
     dict(hp=144, hunger=2), {'Stimpak': 5, 'Purified Water': 4, 'Nuka-Cola': 1},
     {('Stimpak', 'hp'): 2, ('Purified Water', 'hp'): 1}),
    ('3. Конечность, ОЗ 80 %',
     # Стимпак на конечность (144 ОЗ) покрывает нужду 96 — лечение едой не нужно.
     dict(hp=384, limbs=1), BASE_INV,
     {('Stimpak', 'limbs'): 1}),
    ('4. Конечность, стимпак уже в полёте (M6)',
     dict(hp=384, limbs=1, in_heal=144, in_heal_pct=144), BASE_INV, {}),
    ('5. 400 rad, ОЗ под потолком',
     # Потолок сейчас 288, после вывода 480: hp 288 = 60 % -> лечить 192.
     # Радиация: RadAway 300 (80+5+60+3.3=148c, 2.0/c) против Hound Chops
     # 50/(12+5+5+5 = 27c)=1.85 и X-111 нет. RadAway x1 (300), остаток 100: RadAway
     # 100/(80+5+15+5)=0.95 vs Chops 50/27=1.85 -> Chops x2 (100). Дальше ОЗ 192.
     # Лечение рад-предметов идёт в зачёт ОЗ: 192 - 2x60 = 72 -> Radroach 30/22 = 1.36,
     # затем вода 40/32.5 = 1.23; остаток 2 < допуска 9.6.
     dict(hp=288, rads=400), BASE_INV,
     {('RadAway', 'rads'): 1, ('Mutant Hound Chops', 'rads'): 2,
      ('Grilled Radroach', 'hp'): 1, ('Purified Water', 'hp'): 1}),
    ('6. 400 rad + низкое ОЗ, Medic 3 + бобблхед (M1, M7)',
     # RadAway = (60+100)*5*1.1 = 880 >= 400 — один. Стимпак 88 % = 422 ОЗ.
     dict(hp=100, rads=400, medic=3, bobble=True), BASE_INV,
     {('RadAway', 'rads'): 1, ('Stimpak', 'hp'): 1}),
    ('7. Болезнь + зависимость',
     dict(diseases=1, addictions=1),
     {'Antibiotics': 2, 'Addictol': 1, 'Radscorpion Egg Omelette': 1},
     {('Antibiotics', 'disease'): 1, ('Radscorpion Egg Omelette', 'addict'): 1}),
    ('8. Конечность, стимпаков только резерв',
     dict(hp=470, limbs=1), {'Stimpak': 2, 'Purified Water': 2}, {}),
    ('9. ОЗ 50 %, лечить нечем, кроме облучённой еды (решение 1)',
     # Средств вывода нет: грязная вода (+7 rad) и радроуч допускаются, пока
     # сумма < 150. rads 140: первая же грязная вода даёт 147 — можно, вторая нет.
     # Radroach x3 (1.48 / 1.36 / 1.11); дальше только грязная вода: 16 ОЗ за
     # 7 % риска с немедленной проверкой = 0.2 < MIN_SCORE_HP -> не брать.
     dict(hp=240, rads=140), {'Dirty Water': 5, 'Grilled Radroach': 3},
     {('Grilled Radroach', 'hp'): 3}),
    ('10. Обрезка: 150 rad, Nuka-Grape и Chops',
     # A: Nuka-Grape 400 (150/(20+5+10+10)=3.3) побеждает Chops 50/27=1.85. Одна штука.
     # ОД 20 %: иначе Nuka-Grape (ОД-напиток) заперта и берутся Chops x3.
     dict(hp=480, rads=150, ap_pct=0.2, in_combat=True), {'Nuka-Grape': 1, 'Mutant Hound Chops': 3, 'RadAway': 2},
     {('Nuka-Grape', 'rads'): 1}),
    ('11. 170 rad: остаток 20 не стоит RadAway (MIN_SCORE_RADS)',
     # Chops 1.97 / 1.85 / 1.56 -> 150; остаток 20: RadAway 20/150 = 0.13 < 0.5.
     # ОЗ у потолка 398, после вывода 150 потолок 470 -> нужда 72, её закрывает
     # лечение тех же Chops (180).
     dict(hp=398, rads=170), {'Mutant Hound Chops': 3, 'RadAway': 2},
     {('Mutant Hound Chops', 'rads'): 3}),
    # --- шаг 7: запас еды и файл исключений ---
    ('12. Запас еды 10: из 11 штук на ОЗ уходит одна',
     # need 336, стимпаков нет. Mirelurk Cake 140/(35+5+5+3.3) = 2.9 лучше Radroach
     # 30/18.25 = 1.64. Запас: 3 + 8 = 11 штук, тратить можно 11 - 10 = 1.
     dict(hp=144, food_reserve=FOOD_RESERVE_DEFAULT),
     {'Mirelurk Cake': 3, 'Grilled Radroach': 8},
     {('Mirelurk Cake', 'hp'): 1}),
    ('13. Запас без облучённой еды: Cram тратится, Radroach бережётся',
     # need 96 (80 % < 90). Radroach — ровно 10 чистых = весь запас. Cram (+5 rad)
     # в запас не входит: 25 - 5*0.48 = 22.6 / (25+5+5+3.3) = 0.59 > 0.3, x3 = 75.
     dict(hp=384, food_reserve=FOOD_RESERVE_DEFAULT, food_reserve_rads=False),
     {'Grilled Radroach': 10, 'Cram': 3},
     {('Cram', 'hp'): 3}),
    ('14. То же, облучённая еда в запасе: запас 13, тратить 3',
     # Radroach 30/(7+5+5+1) = 1.67 против Cram 0.59 — три Radroach закрывают 90 из 96.
     dict(hp=384, food_reserve=FOOD_RESERVE_DEFAULT, food_reserve_rads=True),
     {'Grilled Radroach': 10, 'Cram': 3},
     {('Grilled Radroach', 'hp'): 3}),
    ('15. Файл исключений: Tato и Carrot — семена, лечить нечем',
     dict(hp=384), {'Tato': 5, 'Carrot': 5}, {}),
    ('16. Файл исключений выключен: Tato и Carrot снова кандидаты',
     # 10 - 5*0.48 = 7.6 ОЗ за Tato: 7.6/(7+5+5+2) = 0.4 > 0.3; Carrot 10 - 1.44 = 8.6 /
     # (3+5+5+2) = 0.57 — сначала вся морковь (80 из 96 с учётом её радиации), потом Tato.
     dict(hp=384, use_exclusions=False), {'Tato': 5, 'Carrot': 5},
     {('Carrot', 'hp'): 5, ('Tato', 'hp'): 3}),
    # --- 2026-09-22: ОЗ — минимум перелечения, цена только тай-брейк ---
    ('17. Нужда 80: вода 40 + кротокрыс 50 лучше оленя 120',
     # 40 + 50 = 90 — перелечение 10; Grilled Radstag 120 — 40, хотя он одной штукой.
     dict(hp=400), {'Purified Water': 1, 'Mole Rat Chunks': 1, 'Grilled Radstag': 1},
     {('Purified Water', 'hp'): 1, ('Mole Rat Chunks', 'hp'): 1}),
    ('19. Лог #51: ОД 100 %, Ядер-Вишня (25 ОД > 9) заперта — лапша x3',
     # need 97. Nuka-Cherry 50 ОЗ, но 25 ОД > 10 % от 90 — не трогаем. Две штуки дают
     # 80 < 87.4 (допуск), три — 120: лапша x3 и лапша x2 + вода равны по потерям и
     # штукам, лапша дешевле.
     dict(hp=383), {'Nuka-Cherry': 3, 'Noodle Cup': 3, 'Purified Water': 1},
     {('Noodle Cup', 'hp'): 3}),
    ('20. То же при ОД 20 %: Ядер-Вишня снова кандидат',
     # Вишня 50 - 5 rad + лапша 40 = 90 + 2.2 от радиации: недобор в допуске, потери 2.4.
     dict(hp=383, ap_pct=0.2, in_combat=True), {'Nuka-Cherry': 3, 'Noodle Cup': 3, 'Purified Water': 1},
     {('Nuka-Cherry', 'hp'): 1, ('Noodle Cup', 'hp'): 1}),
    ('21. Запас колы 3: из 4 колы на лечение уходит одна',
     # ОД низкие, стимпаков нет. Nuka-Cherry 50 x? — тратить можно 4 - 3 = 1.
     dict(hp=280, ap_pct=0.2, in_combat=True, cola_reserve=3), {'Nuka-Cherry': 4},
     {('Nuka-Cherry', 'hp'): 1}),
    ('18. Лог 2026-09-22 #38: сыт, Medic 3, нужда 181 — еда, а не стимпак',
     # Стимпак 422 — перелечение 241. Cake 140 + Soup 55 = 195 (14). Soup x3 + Cram
     # = 165 + 27.4 = 192.4 (11.4 + 2.4 радиацией = 13.8) — в пределах 0.5 от 14,
     # решает число штук: 2 < 4.
     dict(hp=299, medic=3, bobble=True),
     {'Stimpak': 10, 'Mirelurk Cake': 2, 'Vegetable Soup': 3, 'Cram': 5},
     {('Mirelurk Cake', 'hp'): 1, ('Vegetable Soup', 'hp'): 1}),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('-v', action='store_true')
    args = ap.parse_args()
    table = Table()
    failed = 0
    for title, player, inv, expected in SCENARIOS:
        planner = Planner(table, Player(**player), inv, args.v)
        got = planner.result()
        status = 'нет ожидания' if expected is None else ('OK' if got == expected else 'РАЗНИЦА')
        if expected is not None and got != expected:
            failed += 1
        print('%s  [%s]' % (title, status))
        print(planner.report())
        if expected is not None and got != expected:
            print('  ожидалось: %s' % expected)
        print()
    print('итог: %d ситуаций, расхождений %d' % (len(SCENARIOS), failed))


if __name__ == '__main__':
    main()
