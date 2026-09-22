"""
Минимальный читатель BA2 (только general-архивы, тип GNRL) — нужен, чтобы достать
из `Fallout4 - Interface.ba2` файлы Strings/*.STRINGS с именами предметов.

Header (24): 'BTDX' version(u32) type(4) fileCount(u32) nameTableOffset(u64)
GNRL FileEntry (36): nameHash(u32) ext(4) dirHash(u32) flags(u32)
                     offset(u64) packedSize(u32) unpackedSize(u32) align(u32)
packedSize != 0 -> поток zlib.
Таблица имён в конце: на файл u16 длина + байты имени.
"""

import struct
import zlib

_HDR = struct.Struct('<4sI4sIQ')
_ENTRY = struct.Struct('<I4sIIQIII')


class BA2:
    def __init__(self, path):
        self.path = str(path)
        with open(self.path, 'rb') as f:
            self.buf = f.read()
        magic, version, kind, count, name_off = _HDR.unpack_from(self.buf, 0)
        if magic != b'BTDX':
            raise ValueError('%s: не BA2' % self.path)
        self.kind = kind
        self.entries = {}
        if kind != b'GNRL':
            return
        raw = [_ENTRY.unpack_from(self.buf, 24 + i * _ENTRY.size) for i in range(count)]
        pos = name_off
        for i in range(count):
            (ln,) = struct.unpack_from('<H', self.buf, pos)
            pos += 2
            name = self.buf[pos:pos + ln].decode('cp1252', 'replace')
            pos += ln
            _, _, _, _, off, packed, unpacked, _ = raw[i]
            self.entries[name.lower().replace('\\', '/')] = (off, packed, unpacked)

    def names(self):
        return sorted(self.entries)

    def read(self, name):
        off, packed, unpacked = self.entries[name.lower().replace('\\', '/')]
        if packed:
            return zlib.decompress(self.buf[off:off + packed])
        return self.buf[off:off + unpacked]
