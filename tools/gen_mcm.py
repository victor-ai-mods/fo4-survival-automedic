"""
MCM и локализация (шаг 7, §7.2): всё из одного `data/mcm.json`.

    python tools/gen_mcm.py                  — собрать
    python tools/gen_mcm.py --template de    — шаблон перевода для нового языка

На выходе:
    build/mcm/MCM/Config/SurvivalAutoMedic/config.json      только токены $AM_*
    build/mcm/Interface/Translations/SurvivalAutoMedic_<lang>.txt
    papyrus/AutoMedicSettings.psc                          свойства с дефолтами

Почему настройки — свойства скрипта (PropertyValue*), а не ModSetting* с ini.
Дефолт свойства живёт в самом скрипте, поэтому значение есть с первой загрузки,
без единого клика в MCM. У ModSetting* без settings.ini `switcher` читается как
false, пока игрок его не тронет (§7) — у свойств этой ловушки нет вовсе.
Скрипт настроек висит на СВОЁМ квесте AM_Settings: в PropertyValue* нельзя
указать имя скрипта, а на AM_Quest их два.

Формат файла перевода (проверен на установленных LootMan/LIF/HUD++): UTF-16 LE
с BOM, строки через CRLF, «$КЛЮЧ<TAB>текст». Язык выбирается по sLanguage игры.

Генератор падает, если у какой-то строки нет перевода на один из языков
`languages`, если id повторяется, и если после сборки в config.json нашёлся
токен, которого нет в файле перевода (или наоборот).
"""

import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from gen_esp import FID_QUST_MAIN, FID_QUST_SETTINGS, PLUGIN_NAME, SCRIPT_QUEST, SCRIPT_SETTINGS

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SPEC = os.path.join(ROOT, 'data', 'mcm.json')
OUT_MCM = os.path.join(ROOT, 'build', 'mcm')
OUT_PSC = os.path.join(ROOT, 'papyrus', 'AutoMedicSettings.psc')

PREFIX = 'AM_'
SCRIPTS = {
    'main': (FID_QUST_MAIN, SCRIPT_QUEST),
    'settings': (FID_QUST_SETTINGS, SCRIPT_SETTINGS),
}
VALUE_TYPES = {'switcher': 'Bool', 'slider': 'Int', 'dropdown': 'Int'}


class SpecError(Exception):
    pass


# Подсказка MCM: панель по высоте — одна строка, текст ужимается под рамку.
# Замер по скриншотам 1920x1200 (2026-09-22): при двух строках шрифт ~6.2 px на
# символ, ширина панели ~1030 px -> ~165 символов в строке. Однострочная подсказка
# до этой длины идёт шрифтом не мельче двухстрочного; длиннее — выгоднее две
# строки. Порог с запасом: латиница и кириллица шириной различаются.
HELP_WRAP_AT = 150
HELP_LINE_MAX = 165


def wrap_help(text):
    """Длинную подсказку без своего \\n — на две строки, по возможности поровну и
    после знака препинания."""
    if '\n' in text or len(text) <= HELP_WRAP_AT:
        return text
    # Разрывы по приоритету: конец предложения, запятая/тире, любой пробел.
    # Внутри класса — самый ровный; класс годится, если обе строки влезают.
    classes = ([], [], [])
    for i, ch in enumerate(text):
        if ch != ' ':
            continue
        left, right = text[:i].rstrip(), text[i + 1:].lstrip()
        if not left or not right:
            continue
        # «т. п.», «e.g.» — не конец предложения: после конца идёт заглавная или цифра.
        if left[-1] in ':;' or (left[-1] == '.' and (right[0].isupper() or right[0].isdigit())):
            cls = 0
        elif left[-1] in ',)' or left.endswith(' -'):
            cls = 1
        else:
            cls = 2
        classes[cls].append((max(len(left), len(right)), left, right))
    for cands in classes:
        fits = [c for c in cands if c[0] <= HELP_WRAP_AT]
        if fits:
            _, left, right = min(fits)
            return left + '\n' + right
    if classes[2]:
        _, left, right = min(classes[2])
        return left + '\n' + right
    return text


def form_ref(form_id):
    """'SurvivalAutoMedic.esp|808' — локальный id без индекса загрузки."""
    return '%s|%X' % (PLUGIN_NAME, form_id & 0xFFFFFF)


class Builder:
    def __init__(self, spec):
        self.spec = spec
        self.langs = spec['languages']
        self.strings = {}          # ключ без $ -> {lang: текст}
        self.settings = []         # (id, тип Papyrus, дефолт, элемент)
        self.ids = set()

    # --- строки -----------------------------------------------------------

    def token(self, key, texts, where):
        if not isinstance(texts, dict):
            raise SpecError('%s: ожидался словарь {язык: текст}, а не %r' % (where, texts))
        missing = [lang for lang in self.langs if not texts.get(lang)]
        if missing:
            raise SpecError('%s: нет перевода на %s' % (where, ', '.join(missing)))
        extra = sorted(set(texts) - set(self.langs))
        if extra:
            raise SpecError('%s: язык %s не объявлен в languages' % (where, ', '.join(extra)))
        for lang, text in texts.items():
            if '\t' in text or '\r' in text:
                raise SpecError('%s [%s]: табуляция и CR ломают файл перевода' % (where, lang))
        # Перенос строки: \n в mcm.json -> одиночный CR в файле перевода. Строки
        # файла разделены CRLF, одиночный CR их не рвёт, а поле MCM показывает его
        # как перенос (проверено в игре 2026-09-22). `<br>` и буквальное «\n» MCM
        # выводит как есть. Панель подсказки по высоте — одна строка: несколько
        # строк ужимаются по высоте, так что переносить имеет смысл только длинное.
        texts = {lang: text.replace('\n', '\r') for lang, text in texts.items()}
        full = PREFIX + key
        if full in self.strings and self.strings[full] != texts:
            raise SpecError('%s: ключ $%s уже занят другим текстом' % (where, full))
        self.strings[full] = texts
        return '$' + full

    # --- элементы ---------------------------------------------------------

    def element(self, item, page_id):
        kind = item['type']
        if kind == 'spacer':
            return {'type': 'spacer'}
        item_id = item.get('id')
        if not item_id:
            raise SpecError('%s: у элемента %s нет id' % (page_id, kind))
        if item_id in self.ids:
            raise SpecError('%s: id %s повторяется' % (page_id, item_id))
        self.ids.add(item_id)
        where = '%s/%s' % (page_id, item_id)
        out = {'type': kind, 'text': self.token(item_id, item['text'], where)}
        if kind in ('section', 'text'):
            return out
        out['id'] = item_id
        helps = {lang: wrap_help(text) for lang, text in item['help'].items()}
        for lang, text in helps.items():
            for line in text.split('\n'):
                if len(line) > HELP_LINE_MAX:
                    print('  ВНИМАНИЕ: %s (help) [%s]: строка %d симв. > %d — шрифт будет мельче, '
                          'сократите' % (where, lang, len(line), HELP_LINE_MAX))
            if text.count('\n') > 1:
                print('  ВНИМАНИЕ: %s (help) [%s]: больше двух строк — шрифт будет мельче'
                      % (where, lang))
        out['help'] = self.token(item_id + '_HELP', helps, where + ' (help)')

        if kind == 'button':
            form_id, script = SCRIPTS[item['script']]
            out['action'] = {
                'type': 'CallFunction',
                'form': form_ref(form_id),
                'scriptName': script,
                'function': item['function'],
                'params': [],
            }
            return out

        if kind not in VALUE_TYPES:
            raise SpecError('%s: тип %s генератор не знает' % (where, kind))
        ptype = VALUE_TYPES[kind]
        # Дробный ползунок (шаг 0.1 и т. п.): свойство Float, PropertyValueFloat.
        if kind == 'slider' and item.get('float'):
            ptype = 'Float'
        default = item['default']
        opts = {}
        if kind == 'slider':
            lo, hi = item['min'], item['max']
            if not lo <= default <= hi:
                raise SpecError('%s: дефолт %r вне [%r, %r]' % (where, default, lo, hi))
            opts.update({'min': lo, 'max': hi, 'step': item.get('step', 1)})
        elif kind == 'dropdown':
            options = item['options']
            # first/last — часть общего списка (стадии: «начинать с» без 0, «до» без 5).
            # Ключи перевода — по номеру в полном списке, свойство хранит индекс
            # в вырезанном: скрипт прибавляет first (см. комментарий в .psc).
            first = item.get('first', 0)
            if isinstance(options, str):
                list_key = options
                options = self.spec['optionLists'][options]
            else:
                list_key = item_id
            last = item.get('last', len(options) - 1)
            shown = list(enumerate(options))[first:last + 1]
            if not shown:
                raise SpecError('%s: first/last дают пустой список' % where)
            if not 0 <= default < len(shown):
                raise SpecError('%s: дефолт %r вне списка из %d' % (where, default, len(shown)))
            opts['options'] = [self.token('%s_%d' % (list_key, n), text, '%s #%d' % (where, n))
                               for n, text in shown]
        elif not isinstance(default, bool):
            raise SpecError('%s: у switcher дефолт должен быть true/false' % where)
        opts.update({
            'sourceType': 'PropertyValue' + ptype,
            'sourceForm': form_ref(FID_QUST_SETTINGS),
            'propertyName': item_id,
        })
        out['valueOptions'] = opts
        self.settings.append((item_id, ptype, default, item))
        return out

    def config(self):
        spec = self.spec
        about = spec['about']
        pages = []
        for page in spec['pages']:
            pages.append({
                'pageDisplayName': self.token(page['id'], page['text'], page['id']),
                'content': [self.element(item, page['id']) for item in page['content']],
            })
        return {
            'modName': spec['modName'],
            'displayName': self.token('MOD_NAME', spec['displayName'], 'displayName'),
            'minMcmVersion': 2,
            'pluginRequirements': [PLUGIN_NAME],
            'content': [
                {'type': 'section', 'text': self.token('ABOUT', about['section'], 'about')},
                {'type': 'text', 'text': self.token('ABOUT_TEXT', about['text'], 'about text')},
            ],
            'pages': pages,
        }

    # --- выходные файлы ---------------------------------------------------

    def translation(self, lang):
        lines = ['$%s\t%s' % (key, texts[lang]) for key, texts in sorted(self.strings.items())]
        return '﻿' + '\r\n'.join(lines) + '\r\n'

    def papyrus(self):
        decl, reset = [], []
        for item_id, ptype, default, item in self.settings:
            if ptype == 'Bool':
                value = 'true' if default else 'false'
            elif ptype == 'Float':
                value = repr(float(default))
            else:
                value = str(default)
            en = item['text']['en']
            if item.get('first'):
                en += ' (индекс: значение = индекс + %d)' % item['first']
            decl.append('%s Property %s = %s Auto  ; %s' % (ptype, item_id, value, en))
            reset.append('    %s = %s' % (item_id, value))
        return PSC_TEMPLATE % {
            'plugin': PLUGIN_NAME,
            'form': FID_QUST_SETTINGS & 0xFFFFFF,
            'decl': '\n'.join(decl),
            'reset': '\n'.join(reset),
            'count': len(self.settings),
        }


PSC_TEMPLATE = """\
Scriptname AutoMedicSettings extends Quest

; СГЕНЕРИРОВАНО tools/gen_mcm.py из data/mcm.json — руками не править.
;
; Настройки MCM (шаг 7): квест AM_Settings (%(plugin)s|%(form)X).
; MCM читает и пишет эти свойства напрямую (PropertyValue*), а
; AutoMedicQuestScript копирует их к себе в начале каждого цикла
; (LoadSettings), поэтому изменения действуют со следующего нажатия.
; Дефолты — инициализаторы ниже: значение есть с первой загрузки, клик в MCM
; не нужен. Свойств: %(count)d.

%(decl)s

; Кнопка MCM «Сбросить все настройки».
Function ResetDefaults()
%(reset)s
    Debug.Notification("AutoMedic: settings reset / настройки сброшены")
EndFunction
"""


def write(path, data, binary=False):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb' if binary else 'w', **({} if binary else
                                               {'encoding': 'utf-8', 'newline': '\n'})) as f:
        f.write(data)
    print('  %s' % os.path.relpath(path, ROOT))


def check_output(config_path, translation_paths):
    """Перечитать то, что легло на диск: токены конфига == ключи каждого перевода."""
    with open(config_path, encoding='utf-8') as f:
        tokens = set(re.findall(r'"\$(AM_[A-Za-z0-9_]+)"', f.read()))
    for path in translation_paths:
        with open(path, 'rb') as f:
            raw = f.read()
        if not raw.startswith(b'\xff\xfe'):
            raise SpecError('%s: нет BOM UTF-16 LE' % path)
        keys = set()
        for line in raw.decode('utf-16').split('\r\n'):
            if not line:
                continue
            key, sep, text = line.partition('\t')
            if not sep or not key.startswith('$') or not text:
                raise SpecError('%s: битая строка %r' % (path, line))
            keys.add(key[1:])
        if tokens - keys:
            raise SpecError('%s: нет перевода для %s' % (path, ', '.join(sorted(tokens - keys))))
        if keys - tokens:
            raise SpecError('%s: лишние ключи %s' % (path, ', '.join(sorted(keys - tokens))))
    print('  проверка: %d токенов, в каждом из %d переводов все и только они'
          % (len(tokens), len(translation_paths)))


def template(builder, lang):
    """Шаблон для переводчика: ключ, английский текст, пустое поле нового языка."""
    rows = ['# %s -> %s: впишите перевод после TAB и сохраните как UTF-16 LE с BOM'
            % (builder.spec['fallback'], lang)]
    for key, texts in sorted(builder.strings.items()):
        rows.append('# %s' % texts[builder.spec['fallback']])
        rows.append('$%s\t' % key)
    return '\n'.join(rows) + '\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--spec', default=SPEC)
    ap.add_argument('--template', metavar='LANG', help='вывести шаблон перевода и выйти')
    args = ap.parse_args()

    with open(args.spec, encoding='utf-8') as f:
        spec = json.load(f)
    builder = Builder(spec)
    try:
        config = builder.config()
    except SpecError as exc:
        sys.exit('gen_mcm: ОШИБКА: %s' % exc)

    if args.template:
        sys.stdout.write(template(builder, args.template))
        return

    mod = spec['modName']
    config_path = os.path.join(OUT_MCM, 'MCM', 'Config', mod, 'config.json')
    write(config_path, json.dumps(config, ensure_ascii=False, indent=2) + '\n')
    translations = []
    for lang in builder.langs:
        path = os.path.join(OUT_MCM, 'Interface', 'Translations', '%s_%s.txt' % (mod, lang))
        write(path, builder.translation(lang).encode('utf-16-le'), binary=True)
        translations.append(path)
    write(OUT_PSC, builder.papyrus())
    try:
        check_output(config_path, translations)
    except SpecError as exc:
        sys.exit('gen_mcm: ОШИБКА: %s' % exc)
    print('  настроек %d, строк %d, языков %d'
          % (len(builder.settings), len(builder.strings), len(builder.langs)))


if __name__ == '__main__':
    main()
