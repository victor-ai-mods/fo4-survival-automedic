"""
Сборка .esp с нуля: заголовок, верхнеуровневые группы, записи, сабрекорды, VMAD.

Проверено на разборе реального рабочего `QuickAid.esp` (MGEF со скриптом + ALCH +
QUST Start Game Enabled) — все константы ниже сняты с него, а не угаданы.

  Record header (24): sig(4) size(4) flags(4) formid(4) revision(4) version(2) unknown(2)
      size = число байт сабрекордов, идущих следом.
  GRUP header (24): "GRUP" size(4, ВКЛЮЧАЯ эти 24 байта) label(4) groupType(4) stamp(8)
  Subrecord: tag(4) len(u16) payload(len)

VMAD (objFormat = 2):
  u16 version=6, u16 objFormat=2, u16 scriptCount, затем на каждый скрипт:
      wstring имя, u8 status, u16 propCount, затем свойства:
      wstring имя, u8 type, u8 status, значение.
  Значение типа Object — 8 байт `00 00 FF FF <formid LE>`: сначала unused(u16),
  затем aliasId(i16) = -1, и только потом FormID. Порядок не skyrim-овский,
  снят с байтов QuickAid.esp и сверен с известным FormID.
"""

import struct

# Версия записи и «version control info» — ровно те, что стоят в QuickAid.esp.
REC_VERSION = 131
REC_REVISION = 0

# --- типы свойств VMAD ---------------------------------------------------

PROP_OBJECT = 1
PROP_STRING = 2
PROP_INT = 3
PROP_FLOAT = 4
PROP_BOOL = 5
PROP_ARRAY_OBJECT = 11
PROP_ARRAY_STRING = 12
PROP_ARRAY_INT = 13
PROP_ARRAY_FLOAT = 14
PROP_ARRAY_BOOL = 15


def wstring(text):
    """Строка VMAD: u16 длина + байты, БЕЗ завершающего нуля."""
    raw = text.encode('cp1252')
    return struct.pack('<H', len(raw)) + raw


def zstring(text):
    """Строка сабрекорда: cp1252 + завершающий ноль."""
    return text.encode('cp1252') + b'\x00'


def _object_value(form_id):
    return struct.pack('<HhI', 0, -1, form_id)


def _prop_value(ptype, value):
    if ptype == PROP_OBJECT:
        return _object_value(value)
    if ptype == PROP_STRING:
        return wstring(value)
    if ptype == PROP_INT:
        return struct.pack('<i', value)
    if ptype == PROP_FLOAT:
        return struct.pack('<f', value)
    if ptype == PROP_BOOL:
        return struct.pack('<B', 1 if value else 0)
    if ptype == PROP_ARRAY_OBJECT:
        return struct.pack('<I', len(value)) + b''.join(_object_value(v) for v in value)
    if ptype == PROP_ARRAY_INT:
        return struct.pack('<I', len(value)) + b''.join(struct.pack('<i', v) for v in value)
    if ptype == PROP_ARRAY_FLOAT:
        return struct.pack('<I', len(value)) + b''.join(struct.pack('<f', v) for v in value)
    if ptype == PROP_ARRAY_BOOL:
        return struct.pack('<I', len(value)) + bytes(1 if v else 0 for v in value)
    if ptype == PROP_ARRAY_STRING:
        return struct.pack('<I', len(value)) + b''.join(wstring(v) for v in value)
    raise ValueError('неизвестный тип свойства VMAD: %r' % (ptype,))


class Script:
    """Один скрипт в VMAD: имя + свойства [(имя, тип, значение), ...]."""

    def __init__(self, name, properties=()):
        self.name = name
        self.properties = list(properties)

    def prop(self, name, ptype, value):
        self.properties.append((name, ptype, value))
        return self

    def to_bytes(self):
        out = [wstring(self.name), b'\x00', struct.pack('<H', len(self.properties))]
        for name, ptype, value in self.properties:
            out.append(wstring(name))
            out.append(struct.pack('<BB', ptype, 1))  # status 1 = «отредактировано»
            out.append(_prop_value(ptype, value))
        return b''.join(out)


def vmad(scripts):
    out = [struct.pack('<HHH', 6, 2, len(scripts))]
    for s in scripts:
        out.append(s.to_bytes())
    return b''.join(out)


# --- записи и группы -----------------------------------------------------

class Record:
    """Запись .esp: сигнатура, FormID, упорядоченный список сабрекордов."""

    def __init__(self, sig, form_id, editor_id=None):
        self.sig = sig if isinstance(sig, bytes) else sig.encode('ascii')
        self.form_id = form_id
        self.subs = []
        if editor_id is not None:
            self.add(b'EDID', zstring(editor_id))

    def add(self, tag, payload):
        if isinstance(tag, str):
            tag = tag.encode('ascii')
        if len(payload) > 0xFFFF:
            raise ValueError('сабрекорд %r длиннее 0xFFFF — нужен XXXX, здесь не реализован'
                             % (tag,))
        self.subs.append((tag, payload))
        return self

    def to_bytes(self):
        body = b''.join(struct.pack('<4sH', tag, len(p)) + p for tag, p in self.subs)
        head = struct.pack('<4sIIIIHH', self.sig, len(body), 0, self.form_id,
                           REC_REVISION, REC_VERSION, 0)
        return head + body


def top_group(records):
    """Верхнеуровневая GRUP (groupType 0) для набора записей одного типа."""
    body = b''.join(r.to_bytes() for r in records)
    label = struct.unpack('<I', records[0].sig)[0]
    return struct.pack('<4sIIIQ', b'GRUP', len(body) + 24, label, 0, 0) + body


def tes4(masters, num_records, next_object_id, version=0.95):
    r = Record(b'TES4', 0)
    r.add(b'HEDR', struct.pack('<fiI', version, num_records, next_object_id))
    r.add(b'CNAM', zstring('DEFAULT'))
    for m in masters:
        r.add(b'MAST', zstring(m))
        r.add(b'DATA', struct.pack('<Q', 0))
    r.add(b'INTV', struct.pack('<I', 1))
    return r


def build_plugin(masters, groups_by_sig, next_object_id):
    """
    groups_by_sig — список (sig, [Record, ...]) в том порядке, в каком группы
    должны лечь в файл. Число записей в HEDR считает и записи, и группы:
    именно так устроен QuickAid.esp (3 записи + 3 группы = 6).
    """
    groups = [(sig, recs) for sig, recs in groups_by_sig if recs]
    num = sum(len(recs) for _, recs in groups) + len(groups)
    out = [tes4(masters, num, next_object_id).to_bytes()]
    for _, recs in groups:
        out.append(top_group(recs))
    return b''.join(out)
