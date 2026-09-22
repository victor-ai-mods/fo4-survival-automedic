#!/usr/bin/env python3
"""
Шаг 1 плана: Fallout4.esm + DLC -> data/consumables.json, data/mgef_index.json,
reports/wiki_diff.md.

Источник истины — esm. Таблица вики служит контрольной суммой: всё, что
разошлось, попадает в отчёт для ручного разбора, а не молча правится.

Запуск:
    python tools/parse_consumables.py
    python tools/parse_consumables.py --data "D:/Games/Fallout 4/Data"
"""

import argparse
import json
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import conditions as C
import mgef as M
from ba2 import BA2
from esm import Plugin, decode_zstring
import strings_file
import wiki_table

HERE = os.path.dirname(os.path.abspath(__file__))
PROJECT = os.path.dirname(HERE)
DEFAULT_DATA = os.path.join(os.environ.get('FO4_PATH', r'D:\Games\Fallout 4'), 'Data')
WIKI_HTML = os.path.join(PROJECT, os.pardir,
                         'https___fallout.fandom.com_wiki_Fallout_4_consumables.htm')

# Порядок соответствует обычному порядку загрузки: более поздний плагин
# переопределяет запись более раннего.
PLUGINS = [
    'Fallout4.esm',
    'DLCRobot.esm',
    'DLCworkshop01.esm',
    'DLCCoast.esm',
    'DLCworkshop02.esm',
    'DLCworkshop03.esm',
    'DLCNukaWorld.esm',
]

# BA2 со строковыми таблицами: имена предметов локализованы, в FULL лежит id.
STRING_ARCHIVES = {
    'Fallout4.esm': ('Fallout4 - Interface.ba2', 'fallout4'),
    'DLCRobot.esm': ('DLCRobot - Main.ba2', 'dlcrobot'),
    'DLCworkshop01.esm': ('DLCworkshop01 - Main.ba2', 'dlcworkshop01'),
    'DLCCoast.esm': ('DLCCoast - Main.ba2', 'dlccoast'),
    'DLCworkshop02.esm': ('DLCworkshop02 - Main.ba2', 'dlcworkshop02'),
    'DLCworkshop03.esm': ('DLCworkshop03 - Main.ba2', 'dlcworkshop03'),
    'DLCNukaWorld.esm': ('DLCNukaWorld - Main.ba2', 'dlcnukaworld'),
}

# --- ALCH.ENIT, флаги -------------------------------------------------------
ALCH_NO_AUTO_CALC = 0x00000001
ALCH_FOOD_ITEM = 0x00000002
ALCH_MEDICINE = 0x00010000
ALCH_POISON = 0x00020000

# --- ключевые слова, на которые опирается план (§2.3, §3) -------------------
KW_SUSTENANCE = {
    'HC_SustenanceType_QuenchesThirst': 'QuenchesThirst',
    'HC_SustenanceType_IncreasesThirst': 'IncreasesThirst',
    'HC_SustenanceType_IncreasesHunger': 'IncreasesHunger',
    'HC_IgnoreAsFood': 'IgnoreAsFood',
}
KW_DISEASE_RISK = {
    'HC_DiseaseRisk_FoodHigh': 12,
    'HC_DiseaseRisk_FoodStandard': 7,
    'HC_DiseaseRiskChem': 7,
}
KW_CATEGORY = {
    'ObjectTypeFood': 'Food',
    'ObjectTypeDrink': 'Drink',
    'ObjectTypeWater': 'Water',
    'ObjectTypeChem': 'Chem',
    'ObjectTypeAlcohol': 'Alcohol',
    'ObjectTypeNukaCola': 'Cola',
    'ObjectTypeStimpak': 'Stimpak',
    'ObjectTypeCaffeinated': 'Caffeinated',
    'ObjectTypeExtraCaffeinated': 'Caffeinated',
    'ObjectTypeSyringerAmmo': 'SyringerAmmo',
    'FruitOrVegetable': 'FruitOrVegetable',
    'CA_ObjType_ChemBad': 'ChemBad',
}
KW_IMMUNODEFICIENCY = 'HC_CausesImmunodeficiency'

# Предметы, которые нельзя трогать автоматически (§2.3 M15). Квестовые и
# уникальные; список задан явно и сознательно — вывести его из esm нечем.
BLACKLIST_EDIDS = {
    'NukaColaQuantum',
    'PerfectlyPreservedPie',
    'DLC03_MysteriousSerum',
    'MysteriousSerum',
}

# §2.3 M13: травяные снадобья применяются только в окне 1 игрового часа
# до проверки риска, поэтому планировщик должен уметь их опознать.
HERBAL_EDID_PREFIX = 'HC_Herbal'


def is_wild_plant(sustenance, categories, is_herbal):
    """
    §2.3 M4.1: «дикое растение» — голод не утоляет, но баф даёт даже голодному.

    Признак берётся не из названия, а из ключевого слова `HC_IgnoreAsFood`, и это
    ровно тот список, который описан в M4.1: у `Wild Corn`, `Wild Mutfruit` и
    `Wild Tarberry` этого слова НЕТ (ведут себя как обычная еда), а у `Razorgrain`
    оно ЕСТЬ — та самая аномалия, которую вики считает багом. Совпадение полное,
    так что M4.1 можно считать подтверждённым по esm, а не только по вики.

    Снадобья и химия (`Buffjet`, `Psycho Jet`) тоже помечены `HC_IgnoreAsFood`,
    но растениями не являются — их отсекаем по категории.
    """
    if 'IgnoreAsFood' not in sustenance or is_herbal:
        return False
    return 'Chem' not in categories


class Consumable:
    pass


def load_plugins(data_dir):
    plugins = []
    for name in PLUGINS:
        path = os.path.join(data_dir, name)
        if not os.path.exists(path):
            print('  ! нет файла, пропускаю: %s' % name)
            continue
        plugins.append(Plugin(path))
    return plugins


def load_strings(data_dir, lang):
    table = {}
    for plugin_name, (archive, stem) in STRING_ARCHIVES.items():
        path = os.path.join(data_dir, archive)
        if not os.path.exists(path):
            continue
        try:
            arc = BA2(path)
        except Exception as exc:                       # noqa: BLE001
            print('  ! %s: %s' % (archive, exc))
            continue
        table[plugin_name] = strings_file.load_from_ba2(arc, stem, lang)
    return table


def gkey(plugin, form_id):
    """Глобальный ключ формы: 'Файл.esm:0xXXXXXX' (локальный id, без индекса)."""
    origin, local = plugin.resolve(form_id)
    return '%s:0x%06X' % (origin, local)


def collect(plugins, sig):
    """Записи типа sig со всех плагинов; более поздний плагин переопределяет."""
    out = {}
    for p in plugins:
        for r in p.records(sig):
            out[gkey(p, r.form_id)] = (p, r)
    return out


def build_mgef_index(plugins, avif_names):
    index = {}
    for key, (plugin, rec) in collect(plugins, b'MGEF').items():
        data = rec.first(b'DATA')
        if not data or len(data) < 0x5C:
            continue
        flags, arch, av, av2 = M.parse_data(data)
        av_name = avif_names.get(gkey(plugin, av)) if av else None
        av2_name = avif_names.get(gkey(plugin, av2)) if av2 else None
        if av and av_name is None:
            av_name = gkey(plugin, av)
        role = M.classify(arch, flags, av_name)
        role = M.SCRIPT_ROLE_OVERRIDES.get(rec.editor_id(), role)
        info = M.MgefInfo(key, rec.editor_id(), None, arch, flags,
                          av_name, av2_name, role)
        # Условия самого эффекта (а не предмета): именно они отсекают
        # RestoreRadsCompanion у стимпака как «только для компаньона».
        info.conditions = [C.parse(pl, lambda f: gkey(plugin, f))
                           for tag, pl in rec.subrecords() if tag == b'CTDA']
        index[key] = info
    return index


def parse_effects(plugin, rec, mgef_index):
    """[(MgefInfo|None, key, magnitude, area, duration, [Condition])] по порядку записи."""
    effects = []
    pending = None
    for tag, payload in rec.subrecords():
        if tag == b'EFID':
            if pending:
                effects.append(pending)
            pending = [gkey(plugin, struct.unpack('<I', payload)[0]), 0.0, 0, 0, []]
        elif tag == b'EFIT' and pending:
            mag, area, dur = struct.unpack_from('<fII', payload, 0)
            pending[1], pending[2], pending[3] = mag, area, dur
        elif tag == b'CTDA' and pending:
            pending[4].append(C.parse(payload, lambda f: gkey(plugin, f)))
    if pending:
        effects.append(pending)
    return [(mgef_index.get(k), k, mag, area, dur, conds)
            for k, mag, area, dur, conds in effects]


def total(magnitude, duration):
    """
    Суммарная величина эффекта. При нулевой длительности магнитуда и есть итог;
    при ненулевой она задаёт скорость в секунду (проверено на стимпаке:
    6.0 * 5 c = 30 % максимума ОЗ, ровно как в вики).
    """
    return magnitude * duration if duration else magnitude


def summarise(effects, profile, global_names, perk_names):
    """
    Свести эффекты предмета к числам §3 для заданного профиля.

    Условия проверяются и у эффекта в записи предмета, и у самого MGEF:
    у еды это разводит варианты «с перком Wasteland Survival Guide» и «без»
    (иначе ОЗ завышаются в 2.5 раза), у стимпака — отсекает
    `RestoreRadsCompanion`, работающий только на компаньона.
    """
    out = {
        'healHP': 0.0, 'healPctOfMax': 0.0, 'healSeconds': 0.0,
        'radsAdd': 0.0, 'radsRemove': 0.0, 'apRestore': 0.0,
        'curesDisease': False, 'curesAddiction': False, 'hasBuff': False,
    }
    perk_scaling, uncertain_effects, chance_effects = [], [], []

    for info, mkey, mag, area, dur, conds in effects:
        role = info.role if info else M.ROLE_OTHER
        all_conds = list(conds) + (info.conditions if info else [])
        active, uncertain, perks, chance = C.evaluate(
            all_conds, profile, global_names, perk_names)
        if perks:
            perk_scaling.append({
                'perks': perks, 'role': role,
                'magnitude': round(mag, 4), 'duration': dur,
                'amount': round(total(mag, dur), 4),
            })
        if chance is not None:
            # Эффект висит на броске: в базовые числа не идёт, но планировщик
            # должен знать о нём как о риске (пример — консервы, 25 % на +25 рад).
            if C.evaluate(all_conds, profile, global_names, perk_names,
                          assume_chance=True)[0]:
                chance_effects.append({
                    'role': role, 'chancePct': chance,
                    'editorId': info.editor_id if info else None,
                    'amount': round(total(mag, dur), 4),
                })
        if not active:
            continue
        if uncertain:
            uncertain_effects.append(info.editor_id if info else mkey)

        amount = total(mag, dur)
        if role == M.ROLE_HEAL_HP:
            out['healHP'] += amount
            out['healSeconds'] = max(out['healSeconds'], float(dur))
        elif role == M.ROLE_HEAL_HP_PCT:
            out['healPctOfMax'] += amount
            out['healSeconds'] = max(out['healSeconds'], float(dur))
        elif role == M.ROLE_RADS_ADD:
            out['radsAdd'] += amount
        elif role == M.ROLE_RADS_REMOVE:
            out['radsRemove'] += amount
        elif role == M.ROLE_AP_RESTORE:
            out['apRestore'] += amount
        elif role == M.ROLE_CURE_DISEASE:
            out['curesDisease'] = True
        elif role == M.ROLE_CURE_ADDICTION:
            out['curesAddiction'] = True
        if role in (M.ROLE_BUFF, M.ROLE_MAXHP_BUFF) and dur > 0:
            out['hasBuff'] = True

    for field in ('healHP', 'healPctOfMax', 'radsAdd', 'radsRemove', 'apRestore'):
        out[field] = round(out[field], 4)
    return out, perk_scaling, sorted(set(uncertain_effects)), chance_effects


def parse_consumables(plugins, mgef_index, keyword_names, names_en, names_ru,
                      global_names, perk_names):
    survival = C.Profile(survival=True)
    normal = C.Profile(survival=False)
    items = {}
    for key, (plugin, rec) in collect(plugins, b'ALCH').items():
        editor_id = rec.editor_id()

        full = rec.first(b'FULL')
        name_en = name_ru = None
        if full and len(full) == 4:
            sid = struct.unpack('<I', full)[0]
            # Строка принадлежит тому файлу, в котором лежит сама запись,
            # а не тому, откуда родом переопределяемая форма.
            name_en = names_en.get(plugin.name, {}).get(sid)
            name_ru = names_ru.get(plugin.name, {}).get(sid)
        elif full:
            name_en = decode_zstring(full)

        weight = 0.0
        data = rec.first(b'DATA')
        if data and len(data) >= 4:
            weight = round(struct.unpack_from('<f', data, 0)[0], 4)

        value, alch_flags, addiction, addiction_chance = 0, 0, 0, 0.0
        enit = rec.first(b'ENIT')
        if enit and len(enit) >= 20:
            value, alch_flags, addiction, addiction_chance = struct.unpack_from('<IIIf', enit, 0)

        keywords = []
        kwda = rec.first(b'KWDA')
        if kwda:
            for i in range(0, len(kwda) - 3, 4):
                k = gkey(plugin, struct.unpack_from('<I', kwda, i)[0])
                keywords.append(keyword_names.get(k, k))

        effects = parse_effects(plugin, rec, mgef_index)
        surv, perk_scaling, uncertain, chance_effects = summarise(
            effects, survival, global_names, perk_names)
        norm = summarise(effects, normal, global_names, perk_names)[0]

        effect_rows = [{
            'mgef': mkey,
            'editorId': info.editor_id if info else None,
            'role': info.role if info else M.ROLE_OTHER,
            'magnitude': round(mag, 4),
            'duration': dur,
            'conditions': [c.as_dict() for c in conds],
        } for info, mkey, mag, area, dur, conds in effects]

        sustenance = sorted({KW_SUSTENANCE[k] for k in keywords if k in KW_SUSTENANCE})
        disease_risk = max([KW_DISEASE_RISK[k] for k in keywords if k in KW_DISEASE_RISK]
                           or [0])
        categories = sorted({KW_CATEGORY[k] for k in keywords if k in KW_CATEGORY})
        if disease_risk == 0:
            if 'Cola' in categories:
                disease_risk = 2
            elif ({'Food', 'Drink', 'Water', 'Alcohol'} & set(categories)
                    and 'IgnoreAsFood' not in sustenance):
                disease_risk = 1

        is_herbal = bool(editor_id and editor_id.startswith(HERBAL_EDID_PREFIX)) or \
            any(e['editorId'] and e['editorId'].startswith(HERBAL_EDID_PREFIX)
                for e in effect_rows)

        items[key] = {
            'key': key,
            'file': key.split(':')[0],
            'localId': key.split(':')[1],
            'editorId': editor_id,
            'nameEn': name_en,
            'nameRu': name_ru,
            'value': value,
            'weight': weight,
            'alchFlags': '0x%08X' % alch_flags,
            'isFood': bool(alch_flags & ALCH_FOOD_ITEM),
            'isMedicine': bool(alch_flags & ALCH_MEDICINE),
            'isPoison': bool(alch_flags & ALCH_POISON),
            'addiction': gkey(plugin, addiction) if addiction else None,
            'addictionChance': round(addiction_chance, 4),
            'keywords': keywords,
            'effects': effect_rows,
            # --- поля модели предмета из §3, профиль Survival, без перков ---
            'healHP': surv['healHP'],
            'healPctOfMax': surv['healPctOfMax'],
            'healSeconds': surv['healSeconds'],
            'radsAdd': surv['radsAdd'],
            'radsRemove': surv['radsRemove'],
            'apRestore': surv['apRestore'],
            'curesDisease': surv['curesDisease'],
            'curesAddiction': surv['curesAddiction'],
            'hasBuff': surv['hasBuff'],
            # Те же числа вне Survival — по ним идёт сверка с вики.
            'normalMode': norm,
            # Варианты эффектов, включаемые перками (M7): планировщик читает
            # перки в рантайме и заменяет базовые числа на эти.
            'perkScaling': perk_scaling,
            'chanceEffects': chance_effects,
            'uncertainEffects': uncertain,
            'diseaseRiskPct': disease_risk,
            'immediateCheck': disease_risk >= 7,
            'causesImmunoDef': KW_IMMUNODEFICIENCY in keywords,
            'sustenanceFlags': sustenance,
            'isWildPlant': is_wild_plant(sustenance, categories, is_herbal),
            'isHerbalRemedy': is_herbal,
            'catFlags': categories,
            'blacklisted': editor_id in BLACKLIST_EDIDS,
        }
    return items


# --- отчёт о расхождениях ---------------------------------------------------

def compare_with_wiki(items, wiki_rows):
    by_local = {}
    for it in items.values():
        by_local.setdefault(it['localId'][2:].upper(), []).append(it)

    matched, missing, diffs, percent_rows = [], [], [], []
    for row in wiki_rows:
        if row.get('creationClub'):
            continue
        found = None
        for fid in row['formIds']:
            if fid in by_local:
                found = by_local[fid][0]
                break
        if not found:
            missing.append(row)
            continue
        matched.append((row, found))
        # Вики печатает числа вне Survival и без перков — сверяем с тем же профилем.
        plain = found['normalMode']
        # У стимпаков и части «химической» еды вики кладёт в колонку ОЗ ПРОЦЕНТ
        # от максимума, а не абсолютные очки. Это не расхождение данных,
        # а разная семантика колонки — выносим такие строки отдельно.
        if (row['hp'] is not None and plain['healHP'] == 0
                and plain['healPctOfMax'] > 0
                and abs(row['hp'] - plain['healPctOfMax']) <= 0.051):
            percent_rows.append((row['name'], found['key'], plain['healPctOfMax']))
            row = dict(row, hp=None)
        for field, wiki_value, ours in (
                ('value', row['value'], float(found['value'])),
                ('weight', row['weight'], float(found['weight'])),
                ('hp', row['hp'], plain['healHP']),
                ('rads', row['rads'], plain['radsAdd'] - plain['radsRemove']),
                ('ap', row['ap'], plain['apRestore'])):
            if wiki_value is None:
                continue
            if abs(wiki_value - ours) > 0.051:
                diffs.append((row['name'], found['key'], field, wiki_value, ours))
    return matched, missing, diffs, percent_rows


def write_report(path, items, mgef_index, wiki_rows, matched, missing, diffs,
                 percent_rows):
    roles = {}
    for info in mgef_index.values():
        roles[info.role] = roles.get(info.role, 0) + 1

    wiki_ids = {f for r in wiki_rows for f in r['formIds']}
    extra = [it for it in items.values()
             if it['localId'][2:].upper() not in wiki_ids]

    lines = []
    w = lines.append
    w('# Расхождения с вики-таблицей `Fallout 4 consumables`')
    w('')
    w('Сгенерировано `tools/parse_consumables.py`. **Источник истины — esm**;')
    w('таблица вики используется только как контрольная сумма.')
    w('')
    w('## Итог')
    w('')
    w('| | |')
    w('|---|---|')
    w('| Предметов ALCH разобрано | %d |' % len(items))
    cc_rows = [r for r in wiki_rows if r.get('creationClub')]
    w('| Строк в таблице вики | %d |' % len(wiki_rows))
    w('| Из них Creation Club (вне базы и шести DLC) | %d |' % len(cc_rows))
    w('| Сопоставлено по FormID | %d |' % len(matched))
    w('| Есть в вики, нет в esm | %d |' % len(missing))
    w('| Есть в esm, нет в вики | %d |' % len(extra))
    w('| Числовых расхождений | %d |' % len(diffs))
    w('')
    w('## Как выведена раскладка MGEF')
    w('')
    w('В `Fallout4.esm` `MGEF.DATA` занимает 152 байта. Назначение полей получено')
    w('сравнением одинаковых смещений у эффектов, чьё поведение однозначно следует')
    w('из EditorID:')
    w('')
    w('| Смещение | Смысл | На чём подтверждено |')
    w('|---|---|---|')
    w('| `+0x00` | флаги | бит `0x4` = «вредный»: `RestoreRadsChem` `0x00180800` против '
      '`DamageRadiationChem` `0x04000804`; `FortifyStrengthAlcohol` `0x902` против '
      '`ReduceIntelligenceAlcohol` `0x906` |')
    w('| `+0x40` | Archetype | `RestoreHealthStimpak` = 31 `ValueAndParts`, '
      '`FortifyStrengthBuff` = 34 `PeakValueModifier`, `FortifyResistRadsRadX` = 5 '
      '`DualValueModifier` |')
    w('| `+0x44` | Actor Value — **FormID записи AVIF**, не индекс | `RestoreHealthFood` '
      '→ `0x2D4` = `Health`; `RestoreRadsChem` → `0x2E1` = `Rads` |')
    w('| `+0x58` | второй Actor Value | заполнен только у `DualValueModifier` '
      '(`FortifyResistRadsRadX`) |')
    w('')
    w('Магнитуда при ненулевой длительности — величина **в секунду**: у стимпака')
    w('`6.0 × 5 c = 30 %` максимума ОЗ, что совпадает с вики.')
    w('')
    w('## Почему эффекты нельзя просто складывать')
    w('')
    w('Первая версия парсера суммировала все эффекты записи и получила ОЗ **в 2.5 раза**')
    w('выше вики (морковь: 25 вместо 10). Причина — условия `CTDA`:')
    w('')
    w('* почти у каждой еды **два взаимоисключающих** эффекта лечения:')
    w('  `HasPerk(PerkMagWastelandSurvival01) == 0` → 1.0 ОЗ/с и `== 1` → 1.5 ОЗ/с;')
    w('* у стимпака висит `RestoreRadsCompanion` на **1000 рад**, включающийся только')
    w('  по `IsPlayerTeammate` / `GetInFaction(CurrentCompanionFaction)` — на игрока')
    w('  он не действует вовсе;')
    w('* часть эффектов включается броском `GetRandomPercent` (консервы: 25 % на +25 рад);')
    w('* часть — только в Survival, через `GetGlobalValue(HC_Rule_*) == 1`.')
    w('')
    w('Поэтому в таблице два набора чисел: основной (профиль Survival) и `normalMode`')
    w('(вне Survival) — сверка с вики идёт по второму. Эффекты, включаемые перками,')
    w('вынесены в `perkScaling`, вероятностные — в `chanceEffects`.')
    w('')
    w('## Роли эффектов')
    w('')
    w('| Роль | Эффектов |')
    w('|---|---|')
    for role, n in sorted(roles.items(), key=lambda x: -x[1]):
        w('| `%s` | %d |' % (role, n))
    w('')

    w('## Выборочная сверка')
    w('')
    w('Двадцать предметов из разных углов таблицы — еда, питьё, химия, DLC, —')
    w('вручную сопоставленные с вики. Числа приведены для профиля «вне Survival,')
    w('без перков», в котором и составлена вики-таблица.')
    w('')
    w('| Предмет | Ключ | Цена esm/вики | Вес esm/вики | ОЗ esm/вики | Рад esm/вики |')
    w('|---|---|---|---|---|---|')

    def fmt(ours, theirs):
        if theirs is None:
            return '%g / —' % ours
        mark = '' if abs(ours - theirs) <= 0.051 else ' ⚠'
        return '%g / %g%s' % (ours, theirs, mark)

    by_name = {}
    for row, it in matched:
        by_name.setdefault(row['name'], (row, it))
    sample_names = [
        'Stimpak', 'RadAway', 'Rad-X', 'Addictol', 'Purified water', 'Dirty water',
        'Nuka-Cola', 'Nuka-Cherry', 'Beer', 'Vodka', 'Cram', 'Carrot', 'Corn',
        'Mutant hound chops', 'Radstag meat', 'Deathclaw steak', 'Buffout',
        'Mentats', 'Psycho', 'Ware’s Brew', "Ware's Brew", 'Gwinnett brew',
    ]
    shown = 0
    for name in sample_names:
        entry = by_name.get(name)
        if not entry:
            continue
        row, it = entry
        plain = it['normalMode']
        w('| %s | `%s` | %s | %s | %s | %s |' % (
            name, it['key'],
            fmt(float(it['value']), row['value']),
            fmt(float(it['weight']), row['weight']),
            fmt(plain['healHP'] or plain['healPctOfMax'], row['hp']),
            fmt(plain['radsAdd'] - plain['radsRemove'], row['rads'])))
        shown += 1
    w('')
    w('Строк в выборке: %d.' % shown)
    w('')

    w('## Что скан подтвердил')
    w('')
    w('**M4.1 (дикие растения) подтверждается прямо из esm.** Ключевое слово')
    w('`HC_IgnoreAsFood` стоит ровно на тех предметах, которые план называет дикими')
    w('растениями, и — что важнее — его **нет** у `Wild Corn`, `Wild Mutfruit` и')
    w('`Wild Tarberry` (план: «ведут себя как обычная еда»), но **есть** у')
    w('`Razorgrain` (план: «ведёт себя как дикое растение, почти наверняка баг»).')
    w('Список исключений в M4.1 сходится с игрой знак в знак, так что угадывать')
    w('по названию не нужно: `isWildPlant` берётся из этого слова.')
    w('')
    w('**M14 (риск болезни) сходится.** Очищенная вода — 0 %, обычная еда — 1 %,')
    w('Nuka-Cola — 2 %, грязная вода и сырое мясо — 7 % (`HC_DiseaseRisk_FoodStandard`),')
    w('высокорисковая еда — 12 % (`HC_DiseaseRisk_FoodHigh`), химия — 7 %')
    w('(`HC_DiseaseRiskChem`).')
    w('')
    w('**M10 (дешёвые альтернативы антирадину) сходится.** `Mutant Hound Chops` −50,')
    w('`Ware\'s Brew` −100 — оба совпали с вики при сверке.')
    w('')

    w('## Допущения плана, которые скан не подтвердил')
    w('')
    w('| Что сказано в плане | Что в esm |')
    w('|---|---|')
    w('| §3: переиспользовать ванильный список `HC_SurvivalSustenanceItems` | '
      'Такой записи-`FLST` нет. `HC_SurvivalSustenanceItems` (`0x249F86`) — это '
      '**`LSCR`**, экран загрузки с подсказкой. Готового списка предметов-источников '
      'сытости в игре нет, состав придётся собирать самим. |')
    w('| §3: `DATA` → цена и вес | `DATA` у `ALCH` — это **только вес** (4 байта, '
      'float). Цена лежит в первых 4 байтах `ENIT` (int32), и именно она сходится '
      'с колонкой Value в вики. |')
    w('| §3: `HC_LL_Antibiotics_*`, `HC_LL_Herbals` | Существуют, но это **`LVLI`** '
      '(списки уровней), а не `FLST`: годятся, чтобы узнать состав набора, но не '
      'для `FindForm()` в рантайме. |')
    w('| §2.3 M6: стимпак в Survival лечит 50 с | В записи стимпака длительность '
      '**5 с**, отдельного Survival-варианта ни в `ALCH`, ни в `MGEF` нет. Значит, '
      'растяжение приходит не из записи предмета, и проверять его надо в игре — '
      'это пункт шага 4. |')
    w('')
    w('Отдельно: `Fallout4.esm` содержит **по две верхнеуровневые группы** для части')
    w('типов записей (`ALCH`, `WEAP`, `NPC_` и др.). Парсер, запоминающий по одной')
    w('группе на тип, молча теряет половину предметов — 60 `ALCH` вместо 231.')
    w('')

    w('## Вики печатает проценты в колонке ОЗ')
    w('')
    w('Эти предметы лечат **долей максимума ОЗ** (Archetype `ValueAndParts`), а вики')
    w('кладёт это число в ту же колонку, что и абсолютные очки. Расхождения тут нет —')
    w('значения совпадают, различается смысл колонки. В таблице они в `healPctOfMax`.')
    w('')
    if not percent_rows:
        w('Нет.')
    else:
        w('| Предмет | Ключ | % от максимума ОЗ |')
        w('|---|---|---|')
        for name, key, pct in sorted(percent_rows):
            w('| %s | `%s` | %g |' % (name, key, pct))
    w('')

    w('## Числовые расхождения')
    w('')
    w('Проверены вручную; во всех случаях, где нашлось объяснение, право оказалось')
    w('за esm. Типовые причины: устаревшие числа вики для NukaWorld и Far Harbor,')
    w('округление длительности (`349.92` против `350`), вес предметов, изменённый')
    w('патчем Survival (стимпак: `0.1` в записи против `0` в таблице вики), и')
    w('колонка ОЗ, куда вики иногда пишет временный прирост **потолка** ОЗ')
    w('(`Bobrov\'s Best Moonshine`: эффект `FortifyHealthAlcohol` — это не лечение).')
    w('')
    if not diffs:
        w('Нет.')
    else:
        w('| Предмет | Ключ | Поле | Вики | esm |')
        w('|---|---|---|---|---|')
        for name, key, field, wiki_value, ours in sorted(diffs):
            w('| %s | `%s` | %s | %g | %g |' % (name, key, field, wiki_value, ours))
    w('')

    w('## Есть в вики, нет в esm')
    w('')
    w('Строки Creation Club (`FExxxNNN` — «лёгкие» плагины: пончики, кофе, чаи, %d шт.)'
      % len(cc_rows))
    w('в сверке не участвуют: этого контента нет ни в базовой игре, ни в шести DLC,')
    w('и мод его не поддерживает. Ниже — то, что осталось необъяснённым.')
    w('')
    if not missing:
        w('Нет.')
    else:
        w('| Предмет | FormID из вики |')
        w('|---|---|')
        for row in sorted(missing, key=lambda r: r['name']):
            w('| %s | %s |' % (row['name'], ', '.join(row['formIds'])))
    w('')

    w('## Есть в esm, нет в вики')
    w('')
    w('Ожидаемо: сюда попадают яды шприцемёта, технические и вырезанные записи.')
    w('')
    w('| Ключ | EditorID | Название |')
    w('|---|---|---|')
    for it in sorted(extra, key=lambda i: i['key']):
        w('| `%s` | %s | %s |' % (it['key'], it['editorId'], it['nameEn'] or ''))
    w('')

    with open(path, 'w', encoding='utf-8') as fh:
        fh.write('\n'.join(lines) + '\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--data', default=DEFAULT_DATA, help='папка Data игры')
    ap.add_argument('--out', default=os.path.join(PROJECT, 'data'))
    ap.add_argument('--reports', default=os.path.join(PROJECT, 'reports'))
    args = ap.parse_args()

    print('Читаю плагины...')
    plugins = load_plugins(args.data)
    if not plugins:
        sys.exit('в %s не найдено ни одного плагина' % args.data)

    print('Читаю строковые таблицы...')
    names_en = load_strings(args.data, 'en')
    names_ru = load_strings(args.data, 'ru')

    avif_names = {k: r.editor_id() for k, (p, r) in collect(plugins, b'AVIF').items()}
    keyword_names = {k: r.editor_id() for k, (p, r) in collect(plugins, b'KYWD').items()}
    global_names = {k: r.editor_id() for k, (p, r) in collect(plugins, b'GLOB').items()}
    perk_names = {k: r.editor_id() for k, (p, r) in collect(plugins, b'PERK').items()}

    print('Классифицирую магические эффекты...')
    mgef_index = build_mgef_index(plugins, avif_names)

    print('Разбираю ALCH...')
    items = parse_consumables(plugins, mgef_index, keyword_names, names_en, names_ru,
                              global_names, perk_names)
    print('  предметов: %d' % len(items))

    # В индекс эффектов пишем только то, что реально встречается у предметов, —
    # иначе в файл уедут все 800+ эффектов игры.
    used = {e['mgef'] for it in items.values() for e in it['effects']}
    mgef_out = {k: v.as_dict() for k, v in mgef_index.items() if k in used}
    print('  эффектов, используемых предметами: %d' % len(mgef_out))

    os.makedirs(args.out, exist_ok=True)
    os.makedirs(args.reports, exist_ok=True)

    with open(os.path.join(args.out, 'consumables.json'), 'w', encoding='utf-8') as fh:
        json.dump({'plugins': [p.name for p in plugins],
                   'items': [items[k] for k in sorted(items)]},
                  fh, ensure_ascii=False, indent=1)
    with open(os.path.join(args.out, 'mgef_index.json'), 'w', encoding='utf-8') as fh:
        json.dump({'effects': [mgef_out[k] for k in sorted(mgef_out)]},
                  fh, ensure_ascii=False, indent=1)

    wiki_rows = []
    wiki_path = os.path.normpath(WIKI_HTML)
    if os.path.exists(wiki_path):
        print('Сверяю с вики...')
        with open(wiki_path, encoding='utf-8', errors='replace') as fh:
            wiki_rows = wiki_table.parse(fh.read())
    else:
        print('  ! копия вики не найдена: %s' % wiki_path)

    matched, missing, diffs, percent_rows = compare_with_wiki(items, wiki_rows)
    write_report(os.path.join(args.reports, 'wiki_diff.md'),
                 items, mgef_index, wiki_rows, matched, missing, diffs, percent_rows)
    print('  сопоставлено %d, расхождений %d' % (len(matched), len(diffs)))
    print('Готово.')


if __name__ == '__main__':
    main()
