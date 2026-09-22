"""
Читаемый дамп .esp: группы, записи, сабрекорды, разобранный VMAD.

Нужен как проверка того, что собрал `gen_esp.py`, и как способ посмотреть
на чужой рабочий плагин, когда надо скопировать форму записи.

    python tools/dump_esp.py build/SurvivalAutoMedic.esp
"""

import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from esm import Plugin, decode_zstring

_REC_HDR = struct.Struct('<4sIIIIHH')

PROP_TYPES = {1: 'Object', 2: 'String', 3: 'Int', 4: 'Float', 5: 'Bool', 7: 'Struct',
              11: 'Object[]', 12: 'String[]', 13: 'Int[]', 14: 'Float[]', 15: 'Bool[]',
              17: 'Struct[]'}


def _wstring(buf, pos):
    n = struct.unpack_from('<H', buf, pos)[0]
    return buf[pos + 2:pos + 2 + n].decode('cp1252'), pos + 2 + n


def _prop_value(buf, pos, ptype):
    if ptype == 1:
        unused, alias, form_id = struct.unpack_from('<HhI', buf, pos)
        return '%08X (alias %d)' % (form_id, alias), pos + 8
    if ptype == 2:
        return _wstring(buf, pos)
    if ptype == 3:
        return str(struct.unpack_from('<i', buf, pos)[0]), pos + 4
    if ptype == 4:
        return '%g' % struct.unpack_from('<f', buf, pos)[0], pos + 4
    if ptype == 5:
        return str(bool(buf[pos])), pos + 1
    if ptype == 7:
        # Struct: u32 число членов, у каждого имя, тип, статус и значение.
        count = struct.unpack_from('<I', buf, pos)[0]
        pos += 4
        members = []
        for _ in range(count):
            name, pos = _wstring(buf, pos)
            mtype = buf[pos]
            text, pos = _prop_value(buf, pos + 2, mtype)
            members.append('%s=%s' % (name, text))
        return '{%s}' % ', '.join(members), pos
    if ptype in (11, 12, 13, 14, 15, 17):
        count = struct.unpack_from('<I', buf, pos)[0]
        pos += 4
        items = []
        for _ in range(count):
            text, pos = _prop_value(buf, pos, ptype - 10)
            items.append(text)
        return '[%s]' % ', '.join(items), pos
    raise ValueError('неизвестный тип свойства VMAD: %d' % ptype)


def describe_vmad(payload):
    version, obj_format, script_count = struct.unpack_from('<HHH', payload, 0)
    lines = ['version=%d objFormat=%d scripts=%d' % (version, obj_format, script_count)]
    pos = 6
    for _ in range(script_count):
        name, pos = _wstring(payload, pos)
        status = payload[pos]
        prop_count = struct.unpack_from('<H', payload, pos + 1)[0]
        pos += 3
        lines.append('  script %s (status %d, %d свойств)' % (name, status, prop_count))
        for _ in range(prop_count):
            prop_name, pos = _wstring(payload, pos)
            ptype, pstatus = payload[pos], payload[pos + 1]
            pos += 2
            text, pos = _prop_value(payload, pos, ptype)
            lines.append('    %-22s %-9s = %s'
                         % (prop_name, PROP_TYPES.get(ptype, ptype), text))
    if pos != len(payload):
        lines.append('  ХВОСТ %d байт: %s' % (len(payload) - pos, payload[pos:].hex(' ')))
    return lines


def dump(path):
    plugin = Plugin(path)
    print('%s — %d байт' % (os.path.basename(path), len(plugin.buf)))
    print('мастера: %s' % (', '.join(plugin.masters) or '(нет)'))
    for sig, spans in plugin.groups.items():
        for rec in plugin.records(sig):
            print('\n%s %08X  %s' % (sig.decode(), rec.form_id, rec.editor_id() or ''))
            for tag, payload in rec.subrecords():
                if tag == b'VMAD':
                    print('  VMAD (%d)' % len(payload))
                    for line in describe_vmad(payload):
                        print('  ' + line)
                elif tag in (b'FULL', b'DESC', b'MODL'):
                    print('  %s (%d) %r' % (tag.decode(), len(payload),
                                            decode_zstring(payload)))
                else:
                    shown = payload[:48].hex(' ')
                    more = ' …' if len(payload) > 48 else ''
                    print('  %s (%d) %s%s' % (tag.decode(), len(payload), shown, more))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('path')
    dump(ap.parse_args().path)


if __name__ == '__main__':
    main()
