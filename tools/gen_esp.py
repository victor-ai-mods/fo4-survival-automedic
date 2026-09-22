"""
Генератор `SurvivalAutoMedic.esp` (шаг 2 плана, §9).

Единственный мастер — `Fallout4.esm`. Предметы DLC в esp не попадают вообще:
таблица форм собирается в рантайме через `Game.GetFormFromFile` (§8.1), поэтому
ни одного DLC в мастерах быть не должно — это и есть главный критерий готовности.

Состав файла:
    GLOB  AM_RadRateLastSample, AM_RadRateLastTime, AM_LastAutoRunTime   (§5)
    MGEF  AM_UseEffect      — архетип Script + VMAD на AutoMedicScript
    ALCH  AM_Tool           — сам предмет-инструмент, единственный эффект = AM_UseEffect
    QUST  AM_Quest          — Start Game Enabled, два скрипта в VMAD
    QUST  AM_Settings       — настройки MCM (шаг 7), один скрипт AutoMedicSettings
    FLST  AM_AllConsumables — пустой, наполняется на OnQuestInit

Формы-шаблоны (OBND, MGEF.DATA, QUST.DNAM, звук, ключевое слово) сняты с реальных
рабочих записей: `QuickAid.esp` и ванильного `Stimpak` — см. комментарии по месту.

    python tools/gen_esp.py [--out build/SurvivalAutoMedic.esp]
"""

import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from esp_writer import PROP_OBJECT, Record, Script, build_plugin, vmad, zstring

PLUGIN_NAME = 'SurvivalAutoMedic.esp'

# --- FormID собственных записей (индекс файла 0x01, первые 0x800 зарезервированы) ---
FID_GLOB_RAD_SAMPLE = 0x01000800
FID_GLOB_RAD_TIME = 0x01000801
FID_GLOB_LAST_AUTO = 0x01000802
FID_MGEF_USE = 0x01000803
FID_ALCH_TOOL = 0x01000804
FID_QUST_MAIN = 0x01000805
FID_FLST_ITEMS = 0x01000806
FID_GLOB_TEST_MODE = 0x01000807
FID_QUST_SETTINGS = 0x01000808
# Списки предметов по нужде (2026-09-22): пустые, наполняются в BuildTables.
# По ним опрос авторежима одним GetItemCount видит, что появилось средство от
# незакрытой нужды. Порядок = биты USE_* в AutoMedicQuestScript.
NEED_LISTS = [
    (0x01000809, 'AM_ListHP'),
    (0x0100080A, 'AM_ListRads'),
    (0x0100080B, 'AM_ListHunger'),
    (0x0100080C, 'AM_ListThirst'),
    (0x0100080D, 'AM_ListDisease'),
    (0x0100080E, 'AM_ListAddiction'),
    (0x0100080F, 'AM_ListLimbs'),
]
NEXT_OBJECT_ID = 0x00000810

# --- ванильные FormID (Fallout4.esm), проверены разбором записей ---
KYWD_OBJECT_TYPE_STIMPAK = 0x000F4AEB      # вкладка «Помощь», рядом со стимпаками
# Выводит предмет из-под HC_Manager: его OnItemEquipped пропускает всё, что
# несёт одно из NonFoodKeywords. Без этого ObjectTypeStimpak делает инструмент
# «стимпаком», а стимпак в Survival сушит: под SCM каждое нажатие отнимало
# 2 очка жажды (Hardcore.0.log, 2026-09-21). В ванили потеря 0 — только
# потому, что цена предмета 0.
KYWD_HC_IGNORE_AS_FOOD = 0x00249F52
SNDR_USE = 0x0002BAF2                      # звук применения стимпака

SCRIPT_EFFECT = 'AutoMedicScript'
SCRIPT_QUEST = 'AutoMedicQuestScript'
SCRIPT_TABLES = 'AutoMedicTables'
SCRIPT_SETTINGS = 'AutoMedicSettings'

ITEM_NAME = 'AutoMedic'
ITEM_DESC = ('Survival AutoMedic: eat, drink, heal, cleanse and cure in one press. '
             'Reusable - returns to your inventory after every use.')


def mgef_data():
    """
    MGEF.DATA — 152 байта. Значащие поля (раскладка проверена на шаге 1):
        +0x00 флаги, +0x40 Archetype, +0x44 Actor Value (FormID записи AVIF).
    Для эффекта-скрипта нужен Archetype = 1 (Script) и нулевой AV.
    Остальные ненулевые байты скопированы с рабочего QuickAid.esp как есть:
    смысл +0x50, +0x70 и +0x8C не выяснен, но именно с ними эффект работает.
    """
    data = bytearray(152)
    struct.pack_into('<I', data, 0x40, 1)          # Archetype = Script
    struct.pack_into('<I', data, 0x44, 0)          # Actor Value не используется
    struct.pack_into('<I', data, 0x50, 1)
    struct.pack_into('<f', data, 0x70, 1.0)
    struct.pack_into('<I', data, 0x8C, 1)
    return bytes(data)


def build_globals():
    out = []
    for form_id, edid in ((FID_GLOB_RAD_SAMPLE, 'AM_RadRateLastSample'),
                          (FID_GLOB_RAD_TIME, 'AM_RadRateLastTime'),
                          (FID_GLOB_LAST_AUTO, 'AM_LastAutoRunTime'),
                          (FID_GLOB_TEST_MODE, 'AM_TestMode')):
        r = Record(b'GLOB', form_id, edid)
        r.add(b'FNAM', b'f')                        # тип значения: float
        r.add(b'FLTV', struct.pack('<f', 0.0))
        out.append(r)
    return out


def build_mgef():
    r = Record(b'MGEF', FID_MGEF_USE, 'AM_UseEffect')
    effect_script = Script(SCRIPT_EFFECT)
    effect_script.prop('AutoMedicQuest', PROP_OBJECT, FID_QUST_MAIN)
    effect_script.prop('AutoMedicTool', PROP_OBJECT, FID_ALCH_TOOL)
    r.add(b'VMAD', vmad([effect_script]))
    r.add(b'FULL', zstring(ITEM_NAME))
    r.add(b'DATA', mgef_data())
    r.add(b'SNDD', b'')                             # звуков у эффекта нет
    r.add(b'DNAM', b'\x00')
    return r


def build_alch():
    r = Record(b'ALCH', FID_ALCH_TOOL, 'AM_Tool')
    r.add(b'OBND', struct.pack('<6h', -5, -13, 0, 6, 11, 2))   # габариты стимпака
    r.add(b'FULL', zstring(ITEM_NAME))
    r.add(b'KSIZ', struct.pack('<I', 2))
    r.add(b'KWDA', struct.pack('<II', KYWD_OBJECT_TYPE_STIMPAK, KYWD_HC_IGNORE_AS_FOOD))
    r.add(b'MODL', zstring('Props\\Stimpack01.nif'))
    # Минимальный MODT (только версия) — ровно такой стоит в QuickAid.esp и работает:
    # хеши текстур движок берёт из самой модели.
    r.add(b'MODT', struct.pack('<I', 4) + bytes(16))
    r.add(b'DESC', zstring(ITEM_DESC))
    r.add(b'DATA', struct.pack('<f', 0.0))          # вес
    # ENIT: цена(i32), флаги(u32), зависимость(FormID), шанс(float), звук(FormID).
    # 0x00000001 NoAutoCalc, 0x00010000 Medicine — предмет уходит на вкладку «Помощь».
    r.add(b'ENIT', struct.pack('<iIIfI', 0, 0x00010001, 0, 0.0, SNDR_USE))
    r.add(b'DNAM', struct.pack('<I', 0))
    r.add(b'EFID', struct.pack('<I', FID_MGEF_USE))
    r.add(b'EFIT', struct.pack('<fII', 0.0, 0, 0))  # магнитуда, область, длительность
    return r


def build_qust():
    r = Record(b'QUST', FID_QUST_MAIN, 'AM_Quest')
    quest_script = Script(SCRIPT_QUEST)
    quest_script.prop('AM_Tool', PROP_OBJECT, FID_ALCH_TOOL)
    quest_script.prop('AM_AllConsumables', PROP_OBJECT, FID_FLST_ITEMS)
    quest_script.prop('AM_RadRateLastSample', PROP_OBJECT, FID_GLOB_RAD_SAMPLE)
    quest_script.prop('AM_RadRateLastTime', PROP_OBJECT, FID_GLOB_RAD_TIME)
    quest_script.prop('AM_LastAutoRunTime', PROP_OBJECT, FID_GLOB_LAST_AUTO)
    quest_script.prop('AM_TestMode', PROP_OBJECT, FID_GLOB_TEST_MODE)
    # Свойство ссылается на сам квест: на нём же висит второй скрипт, и Papyrus
    # отдаёт его как AutoMedicTables.
    quest_script.prop('AM_Tables', PROP_OBJECT, FID_QUST_MAIN)
    quest_script.prop('AM_Settings', PROP_OBJECT, FID_QUST_SETTINGS)

    tables_script = Script(SCRIPT_TABLES)
    tables_script.prop('AM_AllConsumables', PROP_OBJECT, FID_FLST_ITEMS)
    for form_id, edid in NEED_LISTS:
        tables_script.prop(edid, PROP_OBJECT, form_id)

    r.add(b'VMAD', vmad([quest_script, tables_script]))
    r.add(b'FULL', zstring('Survival AutoMedic'))
    # DNAM: флаги(u16) приоритет(u8) не используется(u8) + два u32.
    # 0x0111 = Start Game Enabled | 0x0010 | Run Once — как у квеста-инициализатора
    # QuickAid, который заведомо стартует сам.
    r.add(b'DNAM', struct.pack('<HBBII', 0x0111, 0, 0x5E, 0, 0))
    r.add(b'NEXT', b'')
    r.add(b'ANAM', struct.pack('<I', 0))            # следующий id алиаса; алиасов нет
    return r


def build_settings_qust():
    """
    Шаг 7: носитель настроек MCM. Отдельный квест, а не третий скрипт на AM_Quest:
    у PropertyValue* в config.json нет имени скрипта, и на форме с двумя
    скриптами неизвестно, у какого из них MCM станет искать свойство.
    Свойств в VMAD нет — дефолты берутся из инициализаторов в самом скрипте.
    """
    r = Record(b'QUST', FID_QUST_SETTINGS, 'AM_Settings')
    r.add(b'VMAD', vmad([Script(SCRIPT_SETTINGS)]))
    r.add(b'FULL', zstring('Survival AutoMedic Settings'))
    r.add(b'DNAM', struct.pack('<HBBII', 0x0111, 0, 0x5E, 0, 0))
    r.add(b'NEXT', b'')
    r.add(b'ANAM', struct.pack('<I', 0))
    return r


def build_flst():
    # Пустые списки: наполняются в рантайме, чтобы не тащить DLC в мастера (§8.1).
    return [Record(b'FLST', FID_FLST_ITEMS, 'AM_AllConsumables')] + \
        [Record(b'FLST', form_id, edid) for form_id, edid in NEED_LISTS]


def check(path):
    """
    Перечитать собранное и убедиться в главном. Мастер должен остаться один:
    стоит случайно положить в запись FormID из DLC — и плагин потребует этот
    DLC, а весь смысл §8.1 в обратном.
    """
    from esm import Plugin
    plugin = Plugin(path)
    assert plugin.masters == ['Fallout4.esm'], 'мастера: %r' % (plugin.masters,)
    seen = {}
    for sig in (b'GLOB', b'MGEF', b'ALCH', b'QUST', b'FLST'):
        seen[sig] = [r.editor_id() for r in plugin.records(sig)]
        assert seen[sig], 'нет ни одной записи %s' % sig.decode()
    for sig, records in seen.items():
        for record in plugin.records(sig):
            for tag, payload in record.subrecords():
                if tag in (b'EFID', b'KWDA'):
                    ref = struct.unpack('<I', payload[:4])[0]
                    assert ref >> 24 in (0x00, 0x01), \
                        '%s ссылается на индекс загрузки %02X' % (sig.decode(), ref >> 24)
    print('  проверка: мастер один, записи на месте (%s)'
          % ', '.join('%s=%d' % (s.decode(), len(v)) for s, v in seen.items()))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default=None, help='куда писать .esp')
    args = ap.parse_args()

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    out_path = args.out or os.path.join(root, 'build', PLUGIN_NAME)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    groups = [
        (b'GLOB', build_globals()),
        (b'MGEF', [build_mgef()]),
        (b'ALCH', [build_alch()]),
        (b'QUST', [build_qust(), build_settings_qust()]),
        (b'FLST', build_flst()),
    ]
    blob = build_plugin(['Fallout4.esm'], groups, NEXT_OBJECT_ID)
    with open(out_path, 'wb') as f:
        f.write(blob)
    print('%s: %d байт, %d записей в %d группах'
          % (out_path, len(blob), sum(len(r) for _, r in groups), len(groups)))
    check(out_path)


if __name__ == '__main__':
    main()
