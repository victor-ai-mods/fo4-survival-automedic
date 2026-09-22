"""
Извлечение контрольной таблицы из локальной копии страницы вики
`Fallout 4 consumables`.

Файл сохранён Firefox'ом как «просмотр исходного кода»: настоящий HTML лежит
внутри подсвеченной разметки как текст. Поэтому сначала снимаем теги и
раскрываем сущности — получается исходный HTML страницы, — и только потом
разбираем таблицы.

Заголовки колонок — иконки без текста, поэтому колонки опознаются по alt/title
картинки в ячейке шапки ("HP Restored", "Rads", "Weight", "Value", "AP Restored").
"""

import html
import re

_TAG = re.compile(r'<[^>]*>')
_ROW = re.compile(r'<tr[^>]*>(.*?)</tr>', re.S)
_CELL = re.compile(r'(<t[hd][^>]*>.*?</t[hd]>)', re.S)
_ALT = re.compile(r'(?:alt|title)="([^"]+)"')
_NUM = re.compile(r'-?\d+(?:\.\d+)?')
_ID_RUN = re.compile(r'(?<![0-9A-Za-z])((?:(?:xx|XX|[0-9A-Fa-f]{2})[0-9A-Fa-f]{6})+)'
                     r'(?![0-9A-Za-z])')


def unwrap_view_source(raw):
    return html.unescape(_TAG.sub('', raw))


def _text(cell):
    return re.sub(r'\s+', ' ', _TAG.sub('', cell)).strip()


def _header_label(cell):
    for a in _ALT.findall(cell):
        a = a.strip()
        if a and not a.lower().startswith('fallout'):
            return a
    return _text(cell)


def _number(text):
    m = _NUM.search(text.replace(',', ''))
    return float(m.group()) if m else None


def _form_ids(text):
    """
    Ячейка Form ID: восьмизначные id, иногда несколько подряд без разделителя
    (Antibiotics -> '000008AB00249F2C'). Первые два знака — индекс загрузки
    ('xx' для предметов из DLC), нам нужны последние шесть.
    """
    out = []
    # Берём только цельные шестнадцатеричные прогоны длиной, кратной 8: иначе из
    # ячейки вроде "xx02B5D4 (see also ...)" вылезают ложные «id» из обычных слов,
    # а они могут случайно совпасть с настоящим предметом.
    for run in _ID_RUN.findall(''.join(text.split())):
        for i in range(0, len(run), 8):
            out.append(run[i + 2:i + 8].upper())
    return out


def parse(raw):
    """Список словарей: name / formIds / hp / ap / rads / weight / value / effect."""
    src = unwrap_view_source(raw)
    out = []
    for m in re.finditer(r'<table[^>]*class="[^"]*va-table[^"]*"[^>]*>', src):
        start = m.end()
        end = src.index('</table>', start)
        rows = _ROW.findall(src[start:end])
        if not rows:
            continue
        header = [_header_label(c) for c in _CELL.findall(rows[0])]
        if 'Name' not in header or 'Form ID' not in header:
            continue
        # Шапка на двух строках: под "Effects" (colspan=2) лежат Effect + длительность.
        cols = {}
        idx = 0
        for label in header:
            if label == 'Effects':
                cols['Effect'] = idx
                idx += 2
                continue
            cols.setdefault(label, idx)
            idx += 1
        span = 2 if 'Effects' in header else 1
        body = rows[1 + (span - 1):]
        for row in body:
            cells = [_text(c) for c in _CELL.findall(row)]
            if len(cells) < idx or 'Name' not in cols:
                continue

            def at(label):
                i = cols.get(label)
                return cells[i] if i is not None and i < len(cells) else ''

            name = at('Name')
            raw_id = at('Form ID')
            ids = _form_ids(raw_id)
            # Контент Creation Club живёт в «лёгких» плагинах и записан как
            # FExxxNNN. В базовой игре и шести DLC его нет — помечаем, чтобы он
            # не выглядел как потерянный при сверке.
            creation_club = 'FEXXX' in raw_id.upper()
            if not name or (not ids and not creation_club):
                continue
            out.append({
                'name': name,
                'formIds': ids,
                'creationClub': creation_club,
                'hp': _number(at('HP Restored')),
                'ap': _number(at('AP Restored')),
                'rads': _number(at('Rads')),
                'weight': _number(at('Weight')),
                'value': _number(at('Value')),
                'effect': at('Effect'),
            })
    return out
