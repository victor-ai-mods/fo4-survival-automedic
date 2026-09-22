"""
Низкоуровневый читатель ESM/ESP (Fallout 4).

Только то, что нужно шагу 1: пройти верхнеуровневые GRUP, достать записи
интересующих типов, распаковать сжатые, разобрать их на сабрекорды.

Формат (проверено ранее по реальным записям, см. заметки по бинарному формату):
  Record header (24): sig(4) size(4) flags(4) formid(4) revision(4) version(2) unknown(2)
      size = число байт сабрекордов, идущих следом.
  GRUP header (24): "GRUP" size(4, ВКЛЮЧАЯ эти 24 байта) label(4) groupType(4) stamp(8)
  Subrecord: tag(4) len(u16) payload(len)
      Если len не помещается в u16, перед записью идёт XXXX(u32) с настоящей длиной,
      а у следующего сабрекорда len == 0.
  Сжатая запись: флаг 0x00040000; payload = uncompressedSize(u32) + zlib-поток.
"""

import os
import struct
import zlib

COMPRESSED = 0x00040000

_REC_HDR = struct.Struct('<4sIIIIHH')
_GRUP_HDR = struct.Struct('<4sIIIQ')
_SUB_HDR = struct.Struct('<4sH')


def decode_zstring(payload):
    """Сабрекорд-строка: cp1252 с завершающим нулём."""
    if not payload:
        return None
    return payload.rstrip(b'\x00').decode('cp1252', 'replace')


class Record:
    __slots__ = ('sig', 'form_id', 'flags', 'data', 'plugin')

    def __init__(self, sig, form_id, flags, data, plugin):
        self.sig = sig
        self.form_id = form_id
        self.flags = flags
        self.data = data
        self.plugin = plugin

    @property
    def local_id(self):
        """FormID без байта индекса загрузки."""
        return self.form_id & 0x00FFFFFF

    def subrecords(self):
        """Итератор (tag, payload) по сабрекордам записи."""
        d = self.data
        pos = 0
        n = len(d)
        pending_size = None
        while pos + 6 <= n:
            tag, size = _SUB_HDR.unpack_from(d, pos)
            pos += 6
            if tag == b'XXXX':
                pending_size = struct.unpack_from('<I', d, pos)[0]
                pos += size
                continue
            if pending_size is not None:
                size = pending_size
                pending_size = None
            yield tag, d[pos:pos + size]
            pos += size

    def first(self, tag):
        for t, payload in self.subrecords():
            if t == tag:
                return payload
        return None

    def editor_id(self):
        return decode_zstring(self.first(b'EDID'))

    def __repr__(self):
        return '<%s %08X %s>' % (self.sig.decode(), self.form_id, self.editor_id())


class Plugin:
    """Один .esm/.esp: список мастеров + выборочное чтение верхнеуровневых групп."""

    def __init__(self, path, name=None):
        self.path = str(path)
        self.name = name or os.path.basename(self.path)
        with open(self.path, 'rb') as f:
            self.buf = f.read()
        self.masters = []
        # b'ALCH' -> [(offset, size), ...].
        # Список, а не одна пара: Fallout4.esm содержит НЕСКОЛЬКО верхнеуровневых
        # групп с одним и тем же label (ALCH, WEAP, NPC_ и др. встречаются дважды).
        # Если хранить по одной, теряется половина записей.
        self.groups = {}
        self._read_header()
        self._scan_top_groups()

    # -- служебное ---------------------------------------------------------

    def _read_header(self):
        sig, size, flags, form_id, rev, ver, unk = _REC_HDR.unpack_from(self.buf, 0)
        if sig != b'TES4':
            raise ValueError('%s: не TES4-заголовок (%r)' % (self.name, sig))
        hdr = Record(sig, form_id, flags, self.buf[24:24 + size], self.name)
        for tag, payload in hdr.subrecords():
            if tag == b'MAST':
                self.masters.append(decode_zstring(payload))
        self._header_end = 24 + size

    def _scan_top_groups(self):
        pos = self._header_end
        n = len(self.buf)
        while pos + 24 <= n:
            sig, size, label, gtype, stamp = _GRUP_HDR.unpack_from(self.buf, pos)
            if sig != b'GRUP':
                raise ValueError('%s: ожидался GRUP на 0x%X, получен %r' % (self.name, pos, sig))
            if gtype == 0:
                self.groups.setdefault(struct.pack('<I', label), []).append((pos + 24, size - 24))
            pos += size

    # -- публичное ---------------------------------------------------------

    def resolve(self, form_id):
        """(имя_файла, локальный_id) для FormID, записанного внутри этого плагина."""
        idx = form_id >> 24
        if idx < len(self.masters):
            return self.masters[idx], form_id & 0x00FFFFFF
        return self.name, form_id & 0x00FFFFFF

    def records(self, sig):
        """Все записи заданного типа из верхнеуровневой группы (с рекурсией в подгруппы)."""
        for off, size in self.groups.get(sig, ()):
            yield from self._walk(off, off + size, sig)

    def _walk(self, start, end, want):
        buf = self.buf
        pos = start
        while pos + 24 <= end:
            sig, size, f3, f4, f5, f6, f7 = _REC_HDR.unpack_from(buf, pos)
            if sig == b'GRUP':
                # у GRUP поля дальше читаются иначе, но size лежит в тех же байтах 4..8
                yield from self._walk(pos + 24, pos + size, want)
                pos += size
                continue
            body = buf[pos + 24:pos + 24 + size]
            if sig == want:
                if f3 & COMPRESSED:
                    body = zlib.decompress(body[4:])
                yield Record(sig, f4, f3, body, self.name)
            pos += 24 + size
