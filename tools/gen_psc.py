"""
Генератор `papyrus/AutoMedicTables.psc` (шаг 2 плана, §9).

Вход  — `data/consumables.json` со шага 1.
Выход — Papyrus-скрипт с запечёнными числами: логика берётся из шаблона
`tools/templates/AutoMedicTables.psc.in`, генератор подставляет в него данные.

Что обязано доехать до рантайма (и почему):
  * локальный FormID + имя файла   — иначе не собрать таблицу без DLC в мастерах;
  * healHP / healPctOfMax / healSeconds / radsAdd / radsRemove / apRestore;
  * diseaseRiskPct + признак немедленной проверки — это `cost()` планировщика (M14);
  * perkScaling — без него не реализуется M7: планировщик читает перк в рантайме
    и подменяет базовую величину;
  * chanceEffects — оценка риска для ветки радиации.
Профиль `normalMode` НЕ идёт: он существовал только для сверки с вики.

    python tools/gen_psc.py [--data "D:\\Games\\Fallout 4\\Data"]
"""

import argparse
import datetime
import json
import os
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHUNK_SIZE = 128
INDENT = ' ' * 4

# --- роли эффектов ---------------------------------------------------
# Порядок фиксирован: значения уезжают в скомпилированный скрипт, менять
# существующие нельзя, только дописывать в конец.
ROLES = [
    ('NONE', 'none'),
    ('HEAL_HP', 'heal_hp'),
    ('HEAL_HP_PCT', 'heal_hp_pct'),
    ('RADS_REMOVE', 'rads_remove'),
    ('RADS_ADD', 'rads_add'),
    ('AP_RESTORE', 'ap_restore'),
    ('CURE_DISEASE', 'cure_disease'),
    ('CURE_ADDICTION', 'cure_addiction'),
    ('BUFF', 'buff'),
    ('DEBUFF', 'debuff'),
    ('MAXHP_BUFF', 'maxhp_buff'),
    ('DAMAGE_HP', 'damage_hp'),
    ('ADDICTION_ODDS', 'addiction_odds'),
    ('SCRIPT', 'script'),
    ('OTHER', 'other'),
]
ROLE_VALUE = {json_name: i for i, (_, json_name) in enumerate(ROLES)}

# --- биты поля Flags -------------------------------------------------
# Старший бит не занимаем: Int в Papyrus знаковый, а HasFlag() делит.
FLAGS = [
    ('FLAG_FOOD', 0x00000001, 'ENIT: предмет-еда'),
    ('FLAG_MEDICINE', 0x00000002, 'ENIT: медицина'),
    ('FLAG_POISON', 0x00000004, 'ENIT: яд'),
    ('FLAG_CURES_DISEASE', 0x00000008, 'лечит болезни Survival'),
    ('FLAG_CURES_ADDICTION', 0x00000010, 'снимает зависимости'),
    ('FLAG_HAS_BUFF', 0x00000020, 'ЛЮБОЙ временный баф -> нельзя есть голодным (M4.2)'),
    ('FLAG_IMMEDIATE_CHECK', 0x00000040, 'вызывает немедленную проверку болезни (M14)'),
    ('FLAG_IMMUNO_DEF', 0x00000080, 'даёт иммунодефицит: риск болезни x1.2 (M8)'),
    ('FLAG_WILD_PLANT', 0x00000100, 'дикое растение: голод не утоляет, баф даёт (M4.1)'),
    ('FLAG_HERBAL_REMEDY', 0x00000200, 'травяное снадобье, окно 1 игровой час (M13)'),
    ('FLAG_BLACKLISTED', 0x00000400, 'не трогать никогда (квестовое и т. п.)'),
    ('FLAG_QUENCHES_THIRST', 0x00000800, 'HC_SustenanceType_QuenchesThirst'),
    ('FLAG_INCREASES_HUNGER', 0x00001000, 'HC_SustenanceType_IncreasesHunger'),
    ('FLAG_INCREASES_THIRST', 0x00002000, 'HC_SustenanceType_IncreasesThirst'),
    ('FLAG_IGNORE_AS_FOOD', 0x00004000, 'HC_IgnoreAsFood'),
    ('FLAG_ADDICTIVE', 0x00008000, 'в ENIT прописана зависимость'),
    ('FLAG_CAT_FOOD', 0x00010000, 'ObjectTypeFood'),
    ('FLAG_CAT_DRINK', 0x00020000, 'ObjectTypeDrink'),
    ('FLAG_CAT_WATER', 0x00040000, 'ObjectTypeWater'),
    ('FLAG_CAT_CHEM', 0x00080000, 'ObjectTypeChem'),
    ('FLAG_CAT_CHEM_BAD', 0x00100000, 'химия с плохой репутацией'),
    ('FLAG_CAT_ALCOHOL', 0x00200000, 'ObjectTypeAlcohol'),
    ('FLAG_CAT_COLA', 0x00400000, 'ObjectTypeNukaCola (M8: жажда 40 %, голод растёт)'),
    ('FLAG_CAT_CAFFEINATED', 0x00800000, 'ObjectTypeCaffeinated'),
    ('FLAG_CAT_STIMPAK', 0x01000000, 'ObjectTypeStimpak'),
    ('FLAG_CAT_FRUIT_VEG', 0x02000000, 'фрукт или овощ'),
    ('FLAG_CAT_SYRINGER', 0x04000000, 'боеприпас шприцемёта, не для употребления'),
    ('FLAG_SATES_HUNGER', 0x08000000, 'HC_Manager: ObjectTypeFood и нет NonFoodKeywords'),
    ('FLAG_SATES_THIRST', 0x10000000, 'HC_Manager: AnimFurnWater или QuenchesThirst'),
]

# Производные флаги голода и жажды — ровно по правилам ванильного
# HC_ManagerScript.ProcessSingleFoodItem() и OnItemEquipped(). Массивы
# ключевых слов сняты с VMAD квеста HC_Manager (Fallout4.esm):
#   QuenchesThirstKeywords = AnimFurnWater, HC_SustenanceType_QuenchesThirst
#   NonFoodKeywords        = HC_EffectType_*, AddictionKeywordJet, HC_IgnoreAsFood
# Именно AnimFurnWater, а не ObjectTypeWater: у Institute Water второго нет.
# Nuka-Cola в «утоляет жажду» НЕ входит — у неё отдельная ветка (40 % цены),
# её видно по FLAG_CAT_COLA.
HUNGER_KEYWORD = 'ObjectTypeFood'
NON_FOOD_KEYWORDS = {'HC_EffectType_Disease', 'HC_EffectType_Hunger', 'HC_EffectType_Sleep',
                     'HC_EffectType_Thirst', 'HC_EffectType_Adrenaline',
                     'AddictionKeywordJet', 'HC_IgnoreAsFood'}
THIRST_KEYWORDS = {'AnimFurnWater', 'HC_SustenanceType_QuenchesThirst'}

# Роли эффектов, которые попадают в таблицу эффектов: по ним считается
# недоставленное «в полёте» из GetActiveEffects (§5).
EFFECT_ROLES = ('heal_hp', 'heal_hp_pct', 'rads_remove', 'rads_add', 'ap_restore',
                'damage_hp')

# catFlags из JSON -> бит
CAT_TO_FLAG = {
    'Food': 'FLAG_CAT_FOOD',
    'Drink': 'FLAG_CAT_DRINK',
    'Water': 'FLAG_CAT_WATER',
    'Chem': 'FLAG_CAT_CHEM',
    'ChemBad': 'FLAG_CAT_CHEM_BAD',
    'Alcohol': 'FLAG_CAT_ALCOHOL',
    'Cola': 'FLAG_CAT_COLA',
    'Caffeinated': 'FLAG_CAT_CAFFEINATED',
    'Stimpak': 'FLAG_CAT_STIMPAK',
    'FruitOrVegetable': 'FLAG_CAT_FRUIT_VEG',
    'SyringerAmmo': 'FLAG_CAT_SYRINGER',
}

SUSTENANCE_TO_FLAG = {
    'QuenchesThirst': 'FLAG_QUENCHES_THIRST',
    'IncreasesHunger': 'FLAG_INCREASES_HUNGER',
    'IncreasesThirst': 'FLAG_INCREASES_THIRST',
    'IgnoreAsFood': 'FLAG_IGNORE_AS_FOOD',
}

FLAG_VALUE = {name: value for name, value, _ in FLAGS}

# Эффекты, которые усиливает перк Medic (и бобблхед «Медицина»). Скан esm на
# шаге 5: все точки входа Medic01..04 обусловлены ключевыми словами MGEF
# ChemTypeStimpack / ChemTypeRadaway, а эти слова стоят ровно на трёх эффектах.
# Medic ПРИБАВЛЯЕТ к магнитуде (ранг 4 ещё и -2 с к длительности), поэтому
# рантайму нужны магнитуда и длительность самого эффекта, а не итог предмета.
MEDIC_HEAL_EFFECTS = {'Fallout4.esm:0x21DDB8',  # RestoreHealthStimpak
                      'Fallout4.esm:0x024000'}  # RestoreHealthChem
MEDIC_RAD_EFFECTS = {'Fallout4.esm:0x023738'}   # RestoreRadsChem

# Предметы, которые планировщик не трогает никогда (шаг 5). Ставится тот же
# FLAG_BLACKLISTED, что и у квестовых.
PLANNER_BLACKLIST = {
    # В Survival выводит 100 rad, а не 1000 из таблицы (вики), и даёт
    # иммунодефицит; §2.3 M10: по умолчанию мод его не использует.
    'RefreshingBeverage',
    # «-36000 rad» — это AbsorbRads на час, а не разовый вывод; плюс
    # зависимость и иммунодефицит (итоги шага 3).
    'MS09LorenzoSerum',
    # Ремкомплект робота-компаньона: игрок сам его не применяет.
    'DLC01RepairKit',
    # Служебная копия антибиотиков, у игрока не бывает.
    'HC_Antibiotics_SILENT_SCRIPT_ONLY',
}


def medic_fields(item):
    """Магнитуда и длительность эффекта, который масштабирует Medic (M7)."""
    out = {}
    for effect in item.get('effects', ()):
        key = effect['mgef']
        if effect.get('conditions'):
            continue
        if key in MEDIC_HEAL_EFFECTS and 'MedicHealMag' not in out:
            out['MedicHealMag'] = effect['magnitude']
            out['MedicHealDur'] = float(effect['duration'])
        elif key in MEDIC_RAD_EFFECTS and 'MedicRadMag' not in out:
            out['MedicRadMag'] = effect['magnitude']
            out['MedicRadDur'] = float(effect['duration'])
    # Сверка: итог в таблице обязан включать этот эффект целиком, иначе
    # рантайм вычтет из итога то, чего в нём нет.
    for mag, dur, total in (('MedicHealMag', 'MedicHealDur', 'healPctOfMax'),
                            ('MedicRadMag', 'MedicRadDur', 'radsRemove')):
        if mag in out:
            part = out[mag] * (out[dur] if out[dur] > 0 else 1.0)
            if item.get(total, 0.0) + 1e-6 < part:
                raise ValueError('%s: %s = %s меньше вклада эффекта Medic %s'
                                 % (item['key'], total, item.get(total), part))
    return out


# --- форматирование Papyrus ------------------------------------------

def pfloat(value):
    text = repr(round(float(value), 4))
    if 'e' in text or 'E' in text:
        text = '%.6f' % value
    if '.' not in text:
        text += '.0'
    return text


def chunk_ranges(total, size=CHUNK_SIZE):
    """[(начало, длина), ...] — последний чанк ровно по остатку, без хвоста пустышек."""
    if total == 0:
        return [(0, 0)]
    return [(start, min(size, total - start)) for start in range(0, total, size)]


# --- сбор данных -----------------------------------------------------

def item_flags(item):
    value = 0
    if item.get('isFood'):
        value |= FLAG_VALUE['FLAG_FOOD']
    if item.get('isMedicine'):
        value |= FLAG_VALUE['FLAG_MEDICINE']
    if item.get('isPoison'):
        value |= FLAG_VALUE['FLAG_POISON']
    if item.get('curesDisease'):
        value |= FLAG_VALUE['FLAG_CURES_DISEASE']
    if item.get('curesAddiction'):
        value |= FLAG_VALUE['FLAG_CURES_ADDICTION']
    if item.get('hasBuff'):
        value |= FLAG_VALUE['FLAG_HAS_BUFF']
    if item.get('immediateCheck'):
        value |= FLAG_VALUE['FLAG_IMMEDIATE_CHECK']
    if item.get('causesImmunoDef'):
        value |= FLAG_VALUE['FLAG_IMMUNO_DEF']
    if item.get('isWildPlant'):
        value |= FLAG_VALUE['FLAG_WILD_PLANT']
    if item.get('isHerbalRemedy'):
        value |= FLAG_VALUE['FLAG_HERBAL_REMEDY']
    if item.get('blacklisted') or item.get('editorId') in PLANNER_BLACKLIST:
        value |= FLAG_VALUE['FLAG_BLACKLISTED']
    if item.get('addiction'):
        value |= FLAG_VALUE['FLAG_ADDICTIVE']
    for name in item.get('sustenanceFlags', ()):
        flag = SUSTENANCE_TO_FLAG.get(name)
        if flag:
            value |= FLAG_VALUE[flag]
        elif name not in SUSTENANCE_TO_FLAG:
            raise KeyError('неизвестный sustenanceFlag %r у %s' % (name, item['key']))
    keywords = set(item.get('keywords', ()))
    if HUNGER_KEYWORD in keywords and not keywords & NON_FOOD_KEYWORDS:
        value |= FLAG_VALUE['FLAG_SATES_HUNGER']
    if keywords & THIRST_KEYWORDS:
        value |= FLAG_VALUE['FLAG_SATES_THIRST']
    for name in item.get('catFlags', ()):
        flag = CAT_TO_FLAG.get(name)
        if flag is None:
            raise KeyError('неизвестный catFlag %r у %s' % (name, item['key']))
        value |= FLAG_VALUE[flag]
    return value


def load_perk_ids(data_dir, needed):
    """
    EDID перка -> локальный FormID в Fallout4.esm.

    Результат кешируется в `data/perk_ids.json`, чтобы повторная сборка не
    требовала игры на диске: сами перки в perkScaling названы только EDID,
    а рантайму нужны FormID.
    """
    cache_path = os.path.join(ROOT, 'data', 'perk_ids.json')
    cache = {}
    if os.path.exists(cache_path):
        with open(cache_path, encoding='utf-8') as f:
            cache = json.load(f)
    missing = sorted(set(needed) - set(cache))
    if missing:
        from esm import Plugin
        esm_path = os.path.join(data_dir, 'Fallout4.esm')
        if not os.path.exists(esm_path):
            raise SystemExit('нет %s, а перки %s ещё не в кеше %s'
                             % (esm_path, ', '.join(missing), cache_path))
        plugin = Plugin(esm_path)
        for record in plugin.records(b'PERK'):
            edid = record.editor_id()
            if edid in missing:
                cache[edid] = '0x%06X' % record.local_id
        still = sorted(set(needed) - set(cache))
        if still:
            raise SystemExit('перки не найдены в Fallout4.esm: %s' % ', '.join(still))
        with open(cache_path, 'w', encoding='utf-8') as f:
            json.dump(dict(sorted(cache.items())), f, ensure_ascii=False, indent=1)
    return {name: int(cache[name], 16) for name in needed}


def collect(items, perk_ids):
    perks = []
    chances = []
    for index, item in enumerate(items):
        for variant in item.get('perkScaling', ()):
            ids = [perk_ids[name] for name in variant['perks']]
            if len(ids) > 3:
                raise SystemExit('у %s вариант с %d перками, в структуре место на 3'
                                 % (item['key'], len(ids)))
            ids += [0] * (3 - len(ids))
            perks.append({
                'ItemIndex': index,
                'Role': ROLE_VALUE.get(variant['role'], ROLE_VALUE['other']),
                'Amount': variant.get('amount', 0.0),
                'Perk1': ids[0], 'Perk2': ids[1], 'Perk3': ids[2],
            })
        for effect in item.get('chanceEffects', ()):
            chances.append({
                'ItemIndex': index,
                'Role': ROLE_VALUE.get(effect['role'], ROLE_VALUE['other']),
                'ChancePct': int(round(effect.get('chancePct', effect.get('chance', 0)))),
                'Amount': effect.get('amount', effect.get('magnitude', 0.0)),
            })
    return perks, chances


# --- генерация текста ------------------------------------------------

def gen_consts(pairs, hex_values=False):
    width = max(len(name) for name, *_ in pairs)
    lines = []
    for entry in pairs:
        name, value = entry[0], entry[1]
        comment = ('  ; ' + entry[2]) if len(entry) > 2 else ''
        text = ('0x%08X' % value) if hex_values else str(value)
        lines.append('Int Property %-*s = %s AutoReadOnly Hidden%s'
                     % (width, name, text, comment))
    return '\n'.join(lines)


def gen_cache_vars(item_chunks, perk_chunks, chance_chunks):
    lines = []
    for i in range(item_chunks):
        lines.append('ItemData[] AM_Items%d' % i)
    for i in range(perk_chunks):
        lines.append('PerkVariant[] AM_Perks%d' % i)
    for i in range(chance_chunks):
        lines.append('ChanceEffect[] AM_Chances%d' % i)
    return '\n'.join(lines)


def gen_dispatch(func, ret_type, count, body):
    """Пара «взять чанк / положить чанк» — обычный if-каскад, без магии."""
    get_lines = ['%s[] Function %sChunk(Int aChunk)' % (ret_type, func)]
    set_lines = ['Function Set%sChunk(Int aChunk, %s[] aRows)' % (func, ret_type)]
    for i in range(count):
        keyword = 'If' if i == 0 else 'ElseIf'
        get_lines.append('%s%s aChunk == %d' % (INDENT, keyword, i))
        get_lines.append('%sReturn %s%d' % (INDENT * 2, body, i))
        set_lines.append('%s%s aChunk == %d' % (INDENT, keyword, i))
        set_lines.append('%s%s%d = aRows' % (INDENT * 2, body, i))
    get_lines.append('%sEndIf' % INDENT)
    get_lines.append('%sReturn None' % INDENT)
    get_lines.append('EndFunction')
    set_lines.append('%sEndIf' % INDENT)
    set_lines.append('EndFunction')
    return '\n'.join(get_lines) + '\n\n' + '\n'.join(set_lines)


def gen_plugin_files(files):
    lines = ['String[] Function PluginFiles() global',
             '%sString[] a = new String[%d]' % (INDENT, len(files))]
    for i, name in enumerate(files):
        lines.append('%sa[%d] = "%s"' % (INDENT, i, name))
    lines.append('%sReturn a' % INDENT)
    lines.append('EndFunction')
    return '\n'.join(lines)


def gen_raw_dispatch(name, ret_type, count):
    lines = ['%s[] Function Raw%s(Int aChunk) global' % (ret_type, name)]
    for i in range(count):
        keyword = 'If' if i == 0 else 'ElseIf'
        lines.append('%s%s aChunk == %d' % (INDENT, keyword, i))
        lines.append('%sReturn Raw%s%d()' % (INDENT * 2, name, i))
    lines.append('%sEndIf' % INDENT)
    lines.append('%sReturn new %s[0]' % (INDENT, ret_type))
    lines.append('EndFunction')
    return '\n'.join(lines)


def gen_raw_chunk(func_name, struct_name, rows, fields, labels=None):
    """
    Один сгенерированный чанк.

    `new Struct[n]` НЕ создаёт n структур — он создаёт n ссылок `None`, и любое
    `a[i].Поле = ...` до явного `a[i] = new Struct` падает в рантайме с
    «Cannot access a variable of a None struct». Компилятор это пропускает
    молча, ловится только в игре. Поэтому строка `a[i] = new Struct` пишется
    для КАЖДОГО элемента, даже если дальше у него нет ни одного поля.

    Сами поля пишутся только ненулевые: новая структура уже вся в нулях.
    """
    lines = ['%s[] Function %s() global' % (struct_name, func_name),
             '%s%s[] a = new %s[%d]' % (INDENT, struct_name, struct_name, len(rows))]
    for slot, row in enumerate(rows):
        if labels:
            lines.append('%s; [%s] %s' % (INDENT, row['_index'], labels[slot]))
        lines.append('%sa[%d] = new %s' % (INDENT, slot, struct_name))
        for field, kind in fields:
            value = row.get(field, 0)
            if not value:
                continue
            if kind == 'hex':
                text = '0x%06X' % value
            elif kind == 'hex32':
                text = '0x%08X' % value
            elif kind == 'float':
                text = pfloat(value)
            else:
                text = str(int(value))
            lines.append('%sa[%d].%s = %s' % (INDENT, slot, field, text))
    lines.append('%sReturn a' % INDENT)
    lines.append('EndFunction')
    return '\n'.join(lines)


ITEM_FIELDS = [
    ('LocalId', 'hex'),
    ('PluginId', 'int'),
    ('HealHP', 'float'),
    ('HealPctOfMax', 'float'),
    ('HealSeconds', 'float'),
    ('RadsAdd', 'float'),
    ('RadsRemove', 'float'),
    ('ApRestore', 'float'),
    ('AddictionChance', 'float'),
    ('DiseaseRiskPct', 'int'),
    ('Flags', 'hex32'),
    ('MedicHealMag', 'float'),
    ('MedicHealDur', 'float'),
    ('MedicRadMag', 'float'),
    ('MedicRadDur', 'float'),
]

PERK_FIELDS = [
    ('ItemIndex', 'int'),
    ('Role', 'int'),
    ('Amount', 'float'),
    ('Perk1', 'hex'),
    ('Perk2', 'hex'),
    ('Perk3', 'hex'),
]

EFFECT_FIELDS = [
    ('LocalId', 'hex'),
    ('PluginId', 'int'),
    ('Role', 'int'),
]

CHANCE_FIELDS = [
    ('ItemIndex', 'int'),
    ('Role', 'int'),
    ('ChancePct', 'int'),
    ('Amount', 'float'),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--data',
                    default=os.path.join(os.environ.get('FO4_PATH', r'D:\Games\Fallout 4'), 'Data'),
                    help='папка Data игры (нужна только чтобы разрешить EDID перков)')
    ap.add_argument('--out', default=os.path.join(ROOT, 'papyrus', 'AutoMedicTables.psc'))
    args = ap.parse_args()

    with open(os.path.join(ROOT, 'data', 'consumables.json'), encoding='utf-8') as f:
        source = json.load(f)
    files = source['plugins']
    items = source['items']
    file_index = {name: i for i, name in enumerate(files)}

    needed_perks = sorted({name for item in items
                           for variant in item.get('perkScaling', ())
                           for name in variant['perks']})
    perk_ids = load_perk_ids(args.data, needed_perks)

    missing = PLANNER_BLACKLIST - {item.get('editorId') for item in items}
    if missing:
        raise SystemExit('PLANNER_BLACKLIST: нет в таблице %s' % ', '.join(sorted(missing)))

    rows = []
    for index, item in enumerate(items):
        rows.append(dict(medic_fields(item), **{
            '_index': index,
            '_label': '%s (%s)' % (item.get('editorId') or '?', item['file']),
            'LocalId': int(item['localId'], 16),
            'PluginId': file_index[item['file']],
            'HealHP': item.get('healHP', 0.0),
            'HealPctOfMax': item.get('healPctOfMax', 0.0),
            'HealSeconds': item.get('healSeconds', 0.0),
            'RadsAdd': item.get('radsAdd', 0.0),
            'RadsRemove': item.get('radsRemove', 0.0),
            'ApRestore': item.get('apRestore', 0.0),
            'AddictionChance': item.get('addictionChance', 0.0),
            'DiseaseRiskPct': item.get('diseaseRiskPct', 0),
            'Flags': item_flags(item),
        }))
    with open(os.path.join(ROOT, 'data', 'mgef_index.json'), encoding='utf-8') as f:
        mgefs = json.load(f)['effects']
    effects = []
    for effect in sorted(mgefs, key=lambda e: e['key']):
        if effect['role'] not in EFFECT_ROLES:
            continue
        plugin, local = effect['key'].split(':')
        if plugin not in file_index:
            raise KeyError('эффект %s из файла вне таблицы плагинов' % effect['key'])
        effects.append({'_index': len(effects), 'LocalId': int(local, 16),
                        'PluginId': file_index[plugin],
                        'Role': ROLE_VALUE[effect['role']],
                        '_label': effect['editorId'] or effect['key']})
    if len(effects) > CHUNK_SIZE:
        raise ValueError('эффектов %d, а таблица эффектов не разбита на чанки' % len(effects))

    perks, chances = collect(items, perk_ids)
    for i, row in enumerate(perks):
        row['_index'] = i
    for i, row in enumerate(chances):
        row['_index'] = i

    item_spans = chunk_ranges(len(rows))
    perk_spans = chunk_ranges(len(perks))
    chance_spans = chunk_ranges(len(chances))

    sizes = [
        ('ITEM_COUNT', len(rows)),
        ('CHUNK_SIZE', CHUNK_SIZE),
        ('ITEM_CHUNKS', len(item_spans)),
        ('PERK_COUNT', len(perks)),
        ('PERK_CHUNKS', len(perk_spans)),
        ('CHANCE_COUNT', len(chances)),
        ('CHANCE_CHUNKS', len(chance_spans)),
        ('EFFECT_COUNT', len(effects)),
    ]

    raw_parts = []
    for chunk, (start, length) in enumerate(item_spans):
        block = rows[start:start + length]
        raw_parts.append(gen_raw_chunk('RawItems%d' % chunk, 'ItemData', block,
                                       ITEM_FIELDS,
                                       labels=[r['_label'] for r in block]))
    for chunk, (start, length) in enumerate(perk_spans):
        raw_parts.append(gen_raw_chunk('RawPerks%d' % chunk, 'PerkVariant',
                                       perks[start:start + length], PERK_FIELDS))
    for chunk, (start, length) in enumerate(chance_spans):
        raw_parts.append(gen_raw_chunk('RawChances%d' % chunk, 'ChanceEffect',
                                       chances[start:start + length], CHANCE_FIELDS))

    raw_parts.append(gen_raw_chunk('RawEffects', 'EffectData', effects, EFFECT_FIELDS,
                                   labels=[r['_label'] for r in effects]))

    chunk_access = '\n\n'.join([
        gen_dispatch('Item', 'ItemData', len(item_spans), 'AM_Items'),
        gen_dispatch('Perk', 'PerkVariant', len(perk_spans), 'AM_Perks'),
        gen_dispatch('Chance', 'ChanceEffect', len(chance_spans), 'AM_Chances'),
    ])
    raw_dispatch = '\n\n'.join([
        gen_raw_dispatch('Items', 'ItemData', len(item_spans)),
        gen_raw_dispatch('Perks', 'PerkVariant', len(perk_spans)),
        gen_raw_dispatch('Chances', 'ChanceEffect', len(chance_spans)),
    ])

    with open(os.path.join(ROOT, 'tools', 'templates', 'AutoMedicTables.psc.in'),
              encoding='utf-8') as f:
        template = f.read()

    body = (template
            .replace('%%ROLES%%', gen_consts([('ROLE_' + name, i)
                                              for i, (name, _) in enumerate(ROLES)]))
            .replace('%%FLAGS%%', gen_consts(FLAGS, hex_values=True))
            .replace('%%CACHE_VARS%%', gen_cache_vars(len(item_spans), len(perk_spans),
                                                      len(chance_spans)))
            .replace('%%CHUNK_ACCESS%%', chunk_access)
            .replace('%%PLUGIN_FILES%%', gen_plugin_files(files))
            .replace('%%RAW_DISPATCH%%', raw_dispatch)
            .replace('%%RAW_DATA%%', '\n\n'.join(raw_parts)))

    # Версия данных — контрольная сумма сгенерированного тела. Любая правка
    # таблицы меняет её, и BuildTables() на следующей загрузке пересоберётся сам.
    version = zlib.crc32(body.encode('utf-8')) & 0x7FFFFFFF
    body = body.replace('%%SIZES%%',
                        gen_consts(sizes + [('DATA_VERSION', version)]))
    stamp = ('собрано %s из %d предметов, %d вариантов по перкам, %d по броску, %d эффектов'
             % (datetime.date.today().isoformat(), len(rows), len(perks), len(chances),
                len(effects)))
    body = body.replace('%%STAMP%%', stamp)

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, 'w', encoding='utf-8', newline='\r\n') as f:
        f.write(body)
    print('%s: %d строк, DATA_VERSION = %d'
          % (args.out, body.count('\n') + 1, version))
    print('  предметы: %d в %d чанках' % (len(rows), len(item_spans)))
    print('  перки:    %d в %d чанках' % (len(perks), len(perk_spans)))
    print('  бросок:   %d в %d чанках' % (len(chances), len(chance_spans)))
    print('  эффекты:  %d' % len(effects))


if __name__ == '__main__':
    main()
