"""
Раскладка собранного мода по игре.

  python tools/deploy.py            — скопировать esp и .pex, включить плагин
  python tools/deploy.py --remove   — снять плагин с загрузки и убрать файлы

Что важно знать про эту установку (см. заметку «Fallout 4 modding setup»):
`Plugins.txt` живёт в ДВУХ местах, и правка только одного молча не работает —
игра читает `%LOCALAPPDATA%\\Fallout4\\Plugins.txt`, а в папке игры лежит его
копия-исходник. Скрипт правит оба.

Всё, что перезаписывается, сначала уезжает в `<игра>\\Backup`.
"""

import argparse
import datetime
import os
import shutil

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Папка игры. Другой путь — переменная окружения FO4_PATH.
GAME = os.environ.get('FO4_PATH', r'D:\Games\Fallout 4')
PLUGIN = 'SurvivalAutoMedic.esp'
SCRIPTS = ['AutoMedicTables.pex', 'AutoMedicSettings.pex', 'AutoMedicQuestScript.pex',
           'AutoMedicScript.pex']
# Шаг 7: MCM и переводы — из build/mcm (собирает tools/gen_mcm.py), пути как в Data.
MCM_ROOT = os.path.join(ROOT, 'build', 'mcm')


def mcm_files():
    """Относительные пути (от Data) всего, что собрал gen_mcm.py."""
    out = []
    for base, _, names in os.walk(MCM_ROOT):
        for name in names:
            out.append(os.path.relpath(os.path.join(base, name), MCM_ROOT))
    return sorted(out)


# Прочие файлы мода: (источник в проекте, путь от Data). exclusions-user.json
# сюда не входит — это файл игрока, раскладка его не трогает.
EXTRA_FILES = [
    (os.path.join(ROOT, 'data', 'exclusions-default.json'),
     os.path.join('SurvivalAutoMedic', 'exclusions-default.json')),
]


def data_files():
    """(источник, путь от Data) — всё, кроме esp и .pex."""
    return ([(os.path.join(MCM_ROOT, rel), rel) for rel in mcm_files()] + EXTRA_FILES)


PLUGIN_LISTS = [
    os.path.join(os.environ['LOCALAPPDATA'],
                 'Fallout4', 'Plugins.txt'),
    os.path.join(GAME, 'fallout4', 'Plugins.txt'),
]


def backup(path):
    if not os.path.exists(path):
        return None
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    target_dir = os.path.join(GAME, 'Backup')
    os.makedirs(target_dir, exist_ok=True)
    target = os.path.join(target_dir, '%s.%s.bak' % (os.path.basename(path), stamp))
    shutil.copy2(path, target)
    return target


def copy(src, dst):
    saved = backup(dst)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)
    print('  %s%s' % (dst, ('  (старый -> %s)' % os.path.basename(saved)) if saved else ''))


def read_lines(path):
    with open(path, encoding='utf-8-sig') as f:
        return f.read().splitlines()


def write_lines(path, lines):
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write('\n'.join(lines) + '\n')


def set_enabled(enabled):
    for path in PLUGIN_LISTS:
        if not os.path.exists(path):
            print('  нет %s — пропущено' % path)
            continue
        lines = read_lines(path)
        kept = [line for line in lines if line.lstrip('*').strip().lower() != PLUGIN.lower()]
        changed = len(kept) != len(lines)
        if enabled:
            kept.append('*' + PLUGIN)
            changed = True
        if changed:
            backup(path)
            write_lines(path, kept)
        print('  %s: %s' % (path, 'включён' if enabled else 'выключен'))


def install():
    print('Файлы:')
    copy(os.path.join(ROOT, 'build', PLUGIN), os.path.join(GAME, 'Data', PLUGIN))
    for name in SCRIPTS:
        copy(os.path.join(ROOT, 'build', 'scripts', name),
             os.path.join(GAME, 'Data', 'Scripts', name))
    for src, rel in data_files():
        copy(src, os.path.join(GAME, 'Data', rel))
    print('Порядок загрузки:')
    set_enabled(True)


def remove():
    print('Порядок загрузки:')
    set_enabled(False)
    print('Файлы:')
    for path in ([os.path.join(GAME, 'Data', PLUGIN)] +
                 [os.path.join(GAME, 'Data', 'Scripts', name) for name in SCRIPTS] +
                 [os.path.join(GAME, 'Data', rel) for _, rel in data_files()]):
        if os.path.exists(path):
            backup(path)
            os.remove(path)
            print('  удалён %s' % path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--remove', action='store_true')
    args = ap.parse_args()
    if args.remove:
        remove()
    else:
        install()
    print('\nЗамена .pex на лету не подхватывается — нужен ПОЛНЫЙ перезапуск игры.')


if __name__ == '__main__':
    main()
