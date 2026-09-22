# Survival AutoMedic — план: публикация на Nexus Mods

Прежний план разработки заархивирован: `docs/archive/PLAN-2026-09-22.md`. Как мод работает
сейчас — `README.ru.md` (описание по коду).

**Статус на 2026-09-22:** мод в тестировании (автор проверяет в игре, вносит отдельные
правки). Ниже — только то, что понадобится, когда будет решено публиковать. Решение о
публикации принимает автор; сама публикация необратима, последний клик «Publish» — только
после его подтверждения.

---

## 1. Перед сборкой релиза

- [ ] Автор закончил тесты и доволен поведением. Открытые пункты тестов — в `docs/auto.md`
      (A1–A12, A7б) и заметках предыдущих сессий.
- [ ] Решить, входит ли в первый релиз кола на ОД как самостоятельная нужда. Сейчас её нет
      (`README.ru.md` §12); если нет — так и написать в описании.
- [ ] Проверить A21: отображается ли `displayName` MCM через перевод или остаётся токеном.
- [ ] Дефолты MCM, с которыми мод уйдёт к игрокам (`data/mcm.json`), — особенно `LogLevel`
      (сейчас «Сводка»), `LogTarget` (свой файл), `AutoMode` (выкл.).
- [ ] `AM_TestMode` в esp — 0 (обычный режим).
- [ ] Номер версии. Сейчас его нет нигде; выбрать (например `1.0.0`) и использовать в имени
      архива и на странице файла.
- [ ] Полная пересборка из исходников (порядок — `README.ru.md` §13): `gen_esp`, `gen_psc`,
      `gen_mcm`, компиляция `build/compile.ppj`. `Release`/`Final` — `false` (иначе
      вырезаются `Debug.Notification` и лог Papyrus).
- [ ] `python tools/plan_sim.py` — все сценарии зелёные.
- [ ] Прогон на **чистом сейве** (новая игра или сейв без мода): таблица собралась (строка
      «Таблица собрана … разрешено N» в логе), предмет выдан, MCM открывается на обоих языках.
- [ ] Прогон **без DLC** (снять DLC в `Plugins.txt`), если есть возможность: мод работает,
      в логе «пропущено (нет DLC)» > 0, ошибок Papyrus нет.

## 2. Состав архива

Архив повторяет структуру `Data\` (установка менеджером модов «как есть»):

```
SurvivalAutoMedic.esp                              <- build/SurvivalAutoMedic.esp
Scripts\AutoMedicScript.pex                        <- build/scripts/
Scripts\AutoMedicQuestScript.pex
Scripts\AutoMedicTables.pex
Scripts\AutoMedicSettings.pex
Scripts\Source\User\AutoMedic*.psc                 <- papyrus/ (по желанию, для совместимости и патчей)
MCM\Config\SurvivalAutoMedic\config.json           <- build/mcm/MCM/...
Interface\Translations\SurvivalAutoMedic_en.txt    <- build/mcm/Interface/...
Interface\Translations\SurvivalAutoMedic_ru.txt
SurvivalAutoMedic\exclusions-default.json          <- data/exclusions-default.json
```

**Не класть в архив:**
- `exclusions-user.json` — это файл игрока;
- логи;
- `build/f4se_stubs` — это заглушка для компиляции.

Список источников совпадает с тем, что раскладывает `tools/deploy.py` (`SCRIPTS`,
`mcm_files()`, `EXTRA_FILES`). Если туда добавится файл, добавить его и сюда.

Упаковка — PowerShell (в Bash-оболочке нет `zip`/`7z`). Собрать дерево во временной папке
и затем:

```powershell
Compress-Archive -Path "<папка>\*" -DestinationPath "SurvivalAutoMedic-<версия>.zip"
```

Проверить архив: открыть, убедиться, что корень — это содержимое `Data`, а не папка
`Data` и не папка проекта.

## 3. Страница мода

- **Название:** Survival AutoMedic (eat, drink, heal, cleanse, cure).
- **Категория:** Utilities (или Gameplay → Survival — выбрать при создании).
- **Описание и обложку предоставляет автор.** Из `README.ru.md` для описания пригодятся:
  - §1 — что делает мод;
  - §5–§8 — как устроены цикл, авторежим и профилактика;
  - §9 — настройки;
  - §12 — чего в моде нет.
- **Requirements** — использовать **«Mod requirements (legacy)»**: только они видны блоком
  под «About this mod».
  - Nexus: Mod Configuration Menu, Garden of Eden Papyrus Extender.
  - External resource: F4SE — f4se.silverlock.org.
  - DLC — не требуются. Есть DLC — его предметы поддерживаются, нет — молча пропускаются.
- **Совместимость для описания:**
  - SCM (Survival Configuration Menu) поддерживается;
  - компаньонов мод не лечит;
  - предметы из других модов не использует;
  - один esp с единственным мастером `Fallout4.esm`.
- **Переводы:** en и ru в комплекте. Новый язык — один файл
  `Interface\Translations\SurvivalAutoMedic_<lang>.txt` (UTF-16 LE с BOM, TAB-разделитель),
  шаблон: `python tools/gen_mcm.py --template <lang>`.
- **Permissions:** свои. Файлы полностью новые, из QuickAid ничего не наследуется.
- **Теги:** Gameplay, Survival, Utilities for Players, плюс из категории Requirements —
  F4SE, MCM.
- **Раскрытие ИИ:** если в описании будет упомянуто участие ИИ, Nexus сам добавит тег
  «AI Assisted».

## 4. Процесс загрузки (Claude in Chrome)

Подробности и ловушки сайта — в заметке памяти «Nexus mod publishing workflow»
(опыт публикации Quick Sell). Коротко:

1. **Upload** в шапке. Кнопка видна только при ширине окна ~1300 px и больше, иначе сначала
   `resize_window`. Дальше «Create draft»: имя, краткое описание (≤ 350 символов), игра,
   категория.
2. **General:** полное описание — BBCode. Правку делать в режиме исходника (`[ ]`), затем
   **переключить обратно в WYSIWYG и только потом Save**. Иначе правка молча теряется.
   После сохранения проверить перезагрузкой.
3. **Media:** баннер 1300×372 (рамку кадрирования сдвинуть вручную); первое загруженное
   изображение становится миниатюрой («Set as thumbnail» — сменить).
4. **Files:** загрузить zip, версия, тип Main.
5. **Requirements:** legacy + external F4SE (см. §3).
6. **Permissions.**
7. **Publish** — только после явного подтверждения автора.

Позже страницы редактировать через «Manage» на публичной странице мода: прямые URL `/edit/*`
ненадёжны.

## 5. Обновления после публикации

- Manage → Files → Add file → «Update existing file».
- Поднять версию; при необходимости отметить «Update mod version to match».
- `exclusions-default.json` при обновлении перезаписывается — в описании напомнить игрокам,
  что свои исключения живут в `exclusions-user.json`.
- Смена данных таблицы меняет `DATA_VERSION` — таблица сама пересоберётся на первой
  загрузке (около 6 с), игроку ничего делать не нужно.
