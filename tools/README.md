# tools — офлайн-инструменты Survival AutoMedic

Игра нужна только как источник данных (`Fallout4.esm` и DLC) и как место,
куда всё раскладывается.

## Шаг 1: esm → таблица предметов

```
python tools/parse_consumables.py [--data "D:\Games\Fallout 4\Data"]
```

| Файл | Что внутри |
|---|---|
| `data/consumables.json` | 352 предмета `ALCH` по модели §3 |
| `data/mgef_index.json` | 220 магических эффектов, встречающихся у этих предметов, с ролью каждого |
| `reports/wiki_diff.md` | сверка с вики: выборка, расхождения, подтверждённые и опровергнутые допущения плана |

## Шаг 2: esp, скриптовая таблица, установка

```
python tools/gen_esp.py                       # build/SurvivalAutoMedic.esp
python tools/gen_psc.py                       # papyrus/AutoMedicTables.psc
"D:\Games\Fallout 4\Papyrus Compiler\PapyrusCompiler.exe" build/compile.ppj
python tools/deploy.py                        # разложить по игре и включить плагин
python tools/deploy.py --remove               # и обратно
python tools/plan_sim.py                      # шаг 5: проверка планировщика без игры
python tools/gen_mcm.py                       # шаг 7: MCM, переводы, AutoMedicSettings.psc
python tools/gen_mcm.py --template de         # шаблон перевода для нового языка
```

`build/f4se_stubs/ObjectReference.psc` — ванильный `ObjectReference.psc` + объявление F4SE
`GetInventoryItems()`: в игре исходников F4SE нет, только `.pex` (оригиналы — github.com/ianpatt/f4se).
Импортируется в `compile.ppj` первым. Комментарий внутри `<Imports>` компилятор не принимает
(«файл содержит недопустимые знаки»).

| Файл | Что внутри |
|---|---|
| `build/SurvivalAutoMedic.esp` | 3 `GLOB`, `MGEF` со скриптом, `ALCH`-инструмент, `QUST` Start Game Enabled, пустой `FLST` |
| `papyrus/AutoMedicTables.psc` | сгенерированная таблица: 352 предмета, 159 вариантов по перкам |
| `build/scripts/*.pex` | скомпилированные скрипты |

`gen_esp.py` после сборки сам перечитывает файл и проверяет главное: мастер
остался один и ни одна ссылка не уехала на чужой индекс загрузки.
Посмотреть содержимое любого плагина (своего или чужого, с разобранным VMAD):
`python tools/dump_esp.py <файл.esp>`.

## Модули

| Модуль | Отвечает за |
|---|---|
| `esm.py` | чтение ESM/ESP: группы, записи, сабрекорды, распаковка zlib |
| `ba2.py` | чтение BA2 (general-архивы) — нужен ради строковых таблиц |
| `strings_file.py` | `.STRINGS` / `.DLSTRINGS` / `.ILSTRINGS`: `FULL` хранит id, а не текст |
| `mgef.py` | раскладка `MGEF.DATA` и классификация эффекта по роли |
| `conditions.py` | `CTDA`: разбор и офлайн-вычисление условий |
| `wiki_table.py` | контрольная таблица из локальной копии страницы вики |
| `parse_consumables.py` | сборка всего вместе, JSON и отчёт |
| `esp_writer.py` | запись .esp: заголовок, группы, записи, VMAD |
| `gen_esp.py` | сам плагин |
| `gen_psc.py` | `AutoMedicTables.psc` из шаблона `templates/` и JSON |
| `dump_esp.py` | читаемый дамп плагина (VMAD, включая структуры и массивы структур) |
| `pex_disasm.py` | дизассемблер `.pex` FO4: переменные с умолчаниями, свойства, функции с номерами строк. Шаг 4 прочитал им `HC_ManagerScript` (ванильный — из `Fallout4 - Misc.ba2` через `ba2.py`, и SCM-версию) |
| `deploy.py` | копирование в игру и правка обоих `Plugins.txt` |
| `gen_mcm.py` | шаг 7: `data/mcm.json` → `build/mcm/` (config.json + переводы UTF-16) и `papyrus/AutoMedicSettings.psc`; падает на пропущенном переводе. Подробности — `docs/mcm.md` |
| `plan_sim.py` | шаг 5: зеркало планировщика `AutoMedicQuestScript` на Python и 11 ситуаций с ручным расчётом ожидаемого плана (`-v` — строки `PICK`). Правишь логику в `.psc` — правь и здесь. Подробности — `docs/planner.md` |

## Три вещи, на которых легко ошибиться

**Верхнеуровневых групп одного типа бывает несколько.** В `Fallout4.esm` по две
группы `ALCH`, `WEAP`, `NPC_` и других. Парсер, который держит по одной группе на
тип, увидит 60 предметов вместо 231 — и это единственное, что будет заметно.

**Эффекты предмета нельзя складывать.** Почти у каждой еды два взаимоисключающих
эффекта лечения (`HasPerk(PerkMagWastelandSurvival01)` = 0 и = 1); у стимпака
висит `RestoreRadsCompanion` на 1000 рад, действующий только на компаньона; часть
эффектов включается броском `GetRandomPercent`, часть — только в Survival. Суммой
получается ОЗ в 2.5 раза выше правды. Условия разбирает `conditions.py`.

**Actor Value в `MGEF.DATA` — это FormID записи `AVIF`**, а не индекс, как в
Skyrim. Раскладка полей и то, на чём она проверена, расписаны в шапке `mgef.py`
и в отчёте.

## Профили

Числа считаются дважды:

* основной набор полей — профиль **Survival, без перков**: его использует мод;
* `normalMode` — то же вне Survival: по нему идёт сверка с вики, потому что
  вики-таблица составлена именно для обычного режима.

Эффекты, включаемые перками, лежат отдельно в `perkScaling` — планировщик читает
перки в рантайме (§2.3 M7). Вероятностные — в `chanceEffects`. Эффекты с
условиями, которые офлайн не трактуются, перечислены в `uncertainEffects`.

В скриптовую таблицу `normalMode` не идёт вообще, а `perkScaling` и
`chanceEffects` — идут: без первого не реализуется M7, второе нужно ветке
радиации как оценка риска.

## Ограничения Papyrus, из-за которых таблица выглядит именно так

**Массив создаётся не длиннее 128 элементов** — отсюда чанки и арифметика
`index / CHUNK_SIZE` вместо одного массива на 352 позиции.

**`new Struct[n]` не создаёт структуры, а создаёт `None`-ссылки.** `a[i].Поле = x`
до явного `a[i] = new Struct` компилируется молча и падает в игре с
`Cannot access a variable of a None struct`. Генератор пишет `a[i] = new ItemData`
для каждого элемента.

**Битовых операций в ванильном Papyrus нет.** `Flags` читается через
`HasFlag(flags, mask)` = `(flags / mask) % 2 == 1` — работает только для
однобитных масок, зато не тянет за собой F4SE-расширение `Math`.

**`Release`/`Final` в `.ppj` обязаны быть `false`.** Весь ванильный `Debug.psc` —
`DebugOnly`, и release-сборка вырезает из `.pex` `OpenUserLog`, `TraceUser` и
`Notification` без единого предупреждения. Мод работает, но молчит. Проверка:
`python -c "print(b'TraceUser' in open('build/scripts/AutoMedicQuestScript.pex','rb').read())"`

**Предметы DLC в esp не попадают.** Таблица хранит пару «локальный FormID +
имя файла», формы разрешаются на `OnQuestInit` через `Game.GetFormFromFile`.
Нет DLC — позиция молча пропускается, мастер по-прежнему один (§8.1).
