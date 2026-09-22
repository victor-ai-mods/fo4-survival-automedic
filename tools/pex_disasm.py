"""
Дизассемблер .pex Fallout 4 (little-endian, версия 3.x) — без Champollion.

Нужен ради шага 4: логика Survival (насыщение, растяжение лечения, проверка
болезни во сне) живёт в `HC_ManagerScript.pex` внутри `Fallout4 - Misc.ba2`,
исходника в `Scripts\Source\Base` нет.

    python tools/pex_disasm.py <файл.pex> [--func ИмяФункции] [--list]

Печатает переменные, свойства и функции с листингом инструкций; номера
строк исходника берутся из отладочной информации, если она есть.
"""

import argparse
import struct
import sys

OPS = [
    ('nop', 0), ('iadd', 3), ('fadd', 3), ('isub', 3), ('fsub', 3), ('imul', 3),
    ('fmul', 3), ('idiv', 3), ('fdiv', 3), ('imod', 3), ('not', 2), ('ineg', 2),
    ('fneg', 2), ('assign', 2), ('cast', 2), ('cmp_eq', 3), ('cmp_lt', 3),
    ('cmp_le', 3), ('cmp_gt', 3), ('cmp_ge', 3), ('jmp', 1), ('jmpt', 2), ('jmpf', 2),
    ('callmethod', 3), ('callparent', 2), ('callstatic', 3), ('return', 1),
    ('strcat', 3), ('propget', 3), ('propset', 3), ('array_create', 2),
    ('array_length', 2), ('array_getelement', 3), ('array_setelement', 3),
    ('array_findelement', 4), ('array_rfindelement', 4), ('is', 3),
    ('struct_create', 1), ('struct_get', 3), ('struct_set', 3),
    ('array_findstruct', 5), ('array_rfindstruct', 5), ('array_add', 3),
    ('array_insert', 3), ('array_removelast', 1), ('array_remove', 3),
    ('array_clear', 1),
]
VARARG = {'callmethod', 'callparent', 'callstatic'}


class Reader:
    def __init__(self, buf):
        self.b = buf
        self.p = 0
        self.strings = []

    def u8(self):
        v = self.b[self.p]
        self.p += 1
        return v

    def _s(self, fmt):
        v = struct.unpack_from('<' + fmt, self.b, self.p)[0]
        self.p += struct.calcsize(fmt)
        return v

    def u16(self):
        return self._s('H')

    def u32(self):
        return self._s('I')

    def u64(self):
        return self._s('Q')

    def wstr(self):
        n = self.u16()
        s = self.b[self.p:self.p + n].decode('cp1252', 'replace')
        self.p += n
        return s

    def sidx(self):
        return self.strings[self.u16()]

    def var(self):
        t = self.u8()
        if t == 0:
            return 'None'
        if t == 1:
            return self.sidx()
        if t == 2:
            return repr(self.sidx())
        if t == 3:
            return str(self._s('i'))
        if t == 4:
            return repr(round(self._s('f'), 6))
        if t == 5:
            return 'true' if self.u8() else 'false'
        raise ValueError('тип переменной %d на 0x%x' % (t, self.p))


def read_function(r):
    f = {'ret': r.sidx(), 'doc': r.sidx(), 'uflags': r.u32(), 'flags': r.u8()}
    f['params'] = [(r.sidx(), r.sidx()) for _ in range(r.u16())]
    f['locals'] = [(r.sidx(), r.sidx()) for _ in range(r.u16())]
    code = []
    for _ in range(r.u16()):
        op = r.u8()
        name, n = OPS[op]
        args = [r.var() for _ in range(n)]
        if name in VARARG:
            cnt = int(r.var())
            args += [r.var() for _ in range(cnt)]
        code.append((name, args))
    f['code'] = code
    return f


def parse(buf):
    r = Reader(buf)
    magic = r.u32()
    if magic != 0xFA57C0DE:
        raise ValueError('не pex FO4 (magic %08x)' % magic)
    r.u8(), r.u8(), r.u16(), r.u64()
    src, _user, _machine = r.wstr(), r.wstr(), r.wstr()
    r.strings = [r.wstr() for _ in range(r.u16())]
    lines = {}
    if r.u8():
        r.u64()
        for _ in range(r.u16()):
            obj, state, fn = r.sidx(), r.sidx(), r.sidx()
            r.u8()
            lines[(state, fn.lower())] = [r.u16() for _ in range(r.u16())]
        for _ in range(r.u16()):          # property groups
            r.sidx(), r.sidx(), r.sidx(), r.u32()
            [r.sidx() for _ in range(r.u16())]
        for _ in range(r.u16()):          # struct orders
            r.sidx(), r.sidx()
            [r.sidx() for _ in range(r.u16())]
    for _ in range(r.u16()):              # user flags
        r.sidx(), r.u8()
    objs = []
    for _ in range(r.u16()):
        o = {'name': r.sidx()}
        r.u32()
        o['parent'], _doc, _const, _uf, o['autostate'] = r.sidx(), r.sidx(), r.u8(), r.u32(), r.sidx()
        o['structs'] = []
        for _ in range(r.u16()):
            sname = r.sidx()
            members = []
            for _ in range(r.u16()):
                m = (r.sidx(), r.sidx())
                r.u32()
                val = r.var()
                r.u8(), r.sidx()
                members.append((m[0], m[1], val))
            o['structs'].append((sname, members))
        o['vars'] = []
        for _ in range(r.u16()):
            name, typ = r.sidx(), r.sidx()
            r.u32()
            val = r.var()
            r.u8()
            o['vars'].append((name, typ, val))
        o['props'] = []
        for _ in range(r.u16()):
            name, typ, _d, _uf, fl = r.sidx(), r.sidx(), r.sidx(), r.u32(), r.u8()
            auto = None
            if fl & 4:
                auto = r.sidx()
            else:
                if fl & 1:
                    read_function(r)
                if fl & 2:
                    read_function(r)
            o['props'].append((name, typ, auto))
        o['states'] = []
        for _ in range(r.u16()):
            sname = r.sidx()
            fns = []
            for _ in range(r.u16()):
                fname = r.sidx()
                fns.append((fname, read_function(r)))
            o['states'].append((sname, fns))
        objs.append(o)
    return src, objs, lines


def dump_function(state, fname, f, lines, out):
    params = ', '.join('%s %s' % (t, n) for n, t in f['params'])
    st = ' [state %s]' % state if state else ''
    out.append('\n%s %s(%s)%s' % (f['ret'], fname, params, st))
    if f['locals']:
        out.append('  locals: ' + ', '.join('%s %s' % (t, n) for n, t in f['locals']))
    ln = lines.get((state, fname.lower()), [])
    for i, (op, args) in enumerate(f['code']):
        src = ('L%-4d' % ln[i]) if i < len(ln) else '     '
        out.append('  %s %3d  %-18s %s' % (src, i, op, ', '.join(args)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('pex')
    ap.add_argument('--func', action='append', help='только эти функции (без учёта регистра)')
    ap.add_argument('--list', action='store_true', help='только перечень функций')
    a = ap.parse_args()
    src, objs, lines = parse(open(a.pex, 'rb').read())
    out = ['; ' + src]
    want = {x.lower() for x in a.func or []}
    for o in objs:
        out.append('Scriptname %s extends %s' % (o['name'], o['parent']))
        if not want:
            for sname, members in o['structs']:
                out.append('Struct %s: %s' % (sname, ', '.join('%s %s=%s' % (t, n, v) for n, t, v in members)))
            for n, t, v in o['vars']:
                out.append('  var %s %s = %s' % (t, n, v))
            for n, t, auto in o['props']:
                out.append('  prop %s %s%s' % (t, n, ' -> ' + auto if auto else ''))
        for sname, fns in o['states']:
            for fname, f in fns:
                if want and fname.lower() not in want:
                    continue
                if a.list:
                    out.append('  %s%s (%d ops)' % (fname, ' [' + sname + ']' if sname else '', len(f['code'])))
                else:
                    dump_function(sname, fname, f, lines, out)
    sys.stdout.reconfigure(encoding='utf-8')
    print('\n'.join(out))


if __name__ == '__main__':
    main()
