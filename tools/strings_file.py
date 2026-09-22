"""
Читатель .STRINGS / .DLSTRINGS / .ILSTRINGS.

Fallout4.esm локализован: сабрекорд FULL хранит не текст, а 4-байтовый id строки.

Формат: count(u32) dataSize(u32), затем count x (stringId u32, offset u32),
затем блок данных dataSize байт.
  .STRINGS                 — строки с нулём на конце, без префикса длины;
  .DLSTRINGS / .ILSTRINGS  — перед строкой u32 с её длиной.
"""

import struct


def parse(blob, length_prefixed):
    count, data_size = struct.unpack_from('<II', blob, 0)
    directory = 8
    data = 8 + count * 8
    out = {}
    for i in range(count):
        sid, off = struct.unpack_from('<II', blob, directory + i * 8)
        pos = data + off
        if length_prefixed:
            (ln,) = struct.unpack_from('<I', blob, pos)
            pos += 4
            raw = blob[pos:pos + ln]
        else:
            end = blob.index(b'\x00', pos)
            raw = blob[pos:end]
        raw = raw.rstrip(b'\x00')
        # FO4 хранит локализованные строки в UTF-8 (для ru это принципиально);
        # cp1252 остаётся запасным вариантом для битых записей.
        try:
            out[sid] = raw.decode('utf-8')
        except UnicodeDecodeError:
            out[sid] = raw.decode('cp1252', 'replace')
    return out


def load_from_ba2(archive, plugin_stem, lang):
    """Все три таблицы одного плагина одним словарём id -> текст."""
    table = {}
    for ext, prefixed in (('strings', False), ('dlstrings', True), ('ilstrings', True)):
        name = 'strings/%s_%s.%s' % (plugin_stem.lower(), lang, ext)
        if name in archive.entries:
            table.update(parse(archive.read(name), prefixed))
    return table
