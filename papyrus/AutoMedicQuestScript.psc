Scriptname AutoMedicQuestScript extends Quest

; Квест-носитель Survival AutoMedic (AM_Quest, Start Game Enabled).
;
; На нём висят два скрипта: этот — жизненный цикл, лог и цикл мода,
; и AutoMedicTables — сама таблица предметов. Свойство AM_Tables указывает
; на тот же самый квест: так один скрипт получает соседа по форме.
;
; Фаза 0 (сбор состояния, §4.1), фазы 1-2 (планировщик и обрезка, §4.2-4.3),
; фаза 3 (исполнение, §4.4 — шаг 6) и фаза 4 (отчёт, §4.5). Режим «план без
; приёма» (dry-run) — консоль `set AM_TestMode to 2`.
;
; Цикл живёт здесь, а не в AutoMedicScript: у эффекта предмета нет состояния
; между нажатиями (номер цикла, кеш форм), и его экземпляр умирает вместе
; с эффектом.

Potion Property AM_Tool Auto Const Mandatory
FormList Property AM_AllConsumables Auto Const Mandatory
AutoMedicTables Property AM_Tables Auto Const Mandatory
; Шаг 7: настройки MCM — на своём квесте AM_Settings (см. AutoMedicSettings).
AutoMedicSettings Property AM_Settings Auto Const Mandatory

; §5: скорость набора радиации для Рад-X и антидребезг автоматического режима.
; PapyrusUtil / StorageUtil не установлены, поэтому это обычные GlobalVariable.
GlobalVariable Property AM_RadRateLastSample Auto Const Mandatory
GlobalVariable Property AM_RadRateLastTime Auto Const Mandatory
GlobalVariable Property AM_LastAutoRunTime Auto Const Mandatory
; Что делает нажатие. 0 — цикл с приёмом (и 60 с наблюдения на Trace),
; 1 — тест A16 шага 4 (одна вода через GardenOfEden.DrinkPotion, затем одна
; через EquipItem), 2 — план без приёма (dry-run, как на шагах 3-5).
; Переключается из консоли: set AM_TestMode to 2
GlobalVariable Property AM_TestMode Auto Const Mandatory

; =====================================================================
;  Настройки. Имена в верхнем регистре остались от констант шагов 2-6:
;  теперь это переменные, и LoadSettings() в начале каждого нажатия
;  копирует в них значения из AM_Settings (MCM). Инициализаторы ниже
;  нужны только до первого LoadSettings. Остальные AutoReadOnly —
;  внутренние константы, в MCM не выносятся.
; =====================================================================

; AM_TestMode: 2 — план без приёма (§4.5 «План без приёма»).
Int Property TEST_MODE_DRY_RUN = 2 AutoReadOnly Hidden

; §6.2: 0 Off, 1 Summary, 2 Detailed, 3 Trace.
Int LOG_LEVEL = 1
Int Property LOG_SUMMARY = 1 AutoReadOnly Hidden
Int Property LOG_DETAILED = 2 AutoReadOnly Hidden
Int Property LOG_TRACE = 3 AutoReadOnly Hidden

Int HUNGER_TRIGGER = 1      ; Peckish
Int HUNGER_TARGET = 0       ; Fed
Int THIRST_TRIGGER = 1      ; Parched
Int THIRST_TARGET = 0       ; Hydrated
Float HEAL_TRIGGER_PCT = 90.0
Float HEAL_TARGET_PCT = 100.0
Float RAD_TRIGGER_PCT = 15.0
Float RAD_TARGET_PCT = 0.0
; «Низкие ОД» (MCM ApItemsBelowPct, % от текущего максимума): только ниже
; этого порога можно тратить ОД-напитки — предметы, восполняющие больше
; AP_BIG_PCT % максимума ОД без дебафов (решение пользователя 2026-09-22:
; Ядер-Вишню пили ради лечения). 100 — всегда можно, 0 — никогда.
Float AP_TRIGGER_PCT = 30.0
; MCM ApItemsMode: 0 — никогда, 1 — только в бою (дефолт), 2 — всегда. Работает
; ВМЕСТЕ с порогом: «в бою» = в бою И ОД ниже порога.
Int AP_ITEMS_MODE = 1
Float Property AP_BIG_PCT = 10.0 AutoReadOnly Hidden
; Сколько штук Ядер-Колы (ObjectTypeNukaCola, все виды вместе) не тратить никогда.
Int COLA_RESERVE = 0
; §2.1 №4: максимум радиации (AV RadHealthMax) — 1000.
Float Property RADS_MAX = 1000.0 AutoReadOnly Hidden

; --- шаг 5: планировщик (дефолты §7 «Экономия», «Радиация», «Голод») ---
; Не трогать предметы дороже, крышек (0 — без лимита).
Float MAX_ITEM_VALUE = 150.0
; Не есть предметы с риском болезни выше, % (M14).
Int MAX_DISEASE_RISK_PCT = 7
Int RESERVE_STIMPAKS = 2
Int RESERVE_RADAWAY = 1
; Сколько rads мод готов набрать едой за цикл.
Float MAX_INGESTED_RADS = 50.0
; Решение 1 (§11): без средств вывода не переходить порог радиации.
Bool RAD_CAP_WITHOUT_CURE = true
; Аддиктивная химия и алкоголь (§7 «Прочее»).
Bool USE_CHEMS = false
Bool USE_ALCOHOL = false
; Недолеченное в пределах допуска нуждой не считается: иначе жадный подбор
; тянет ещё один предмет ради последних пары ОЗ.
Float Property HP_TOLERANCE_PCT = 2.0 AutoReadOnly Hidden
Float Property RAD_TOLERANCE = 10.0 AutoReadOnly Hidden
; Предохранитель: больше предметов в плане не бывает.
Int Property MAX_PLAN_ITEMS = 12 AutoReadOnly Hidden
; Стадия C: предел перебора наборов (офлайн, 30 видов еды: 300 узлов почти
; всегда дают оптимум, 1000 — с запасом) и «равенство» потерь в ОЗ.
Int Property HEAL_NODE_BUDGET = 1000 AutoReadOnly Hidden
Float Property HEAL_EPS = 0.5 AutoReadOnly Hidden

; --- шаг 6: исполнение (§4.4) ---
; iMaxItemsPerNeed §7: больше предметов один цикл голода (жажды) не съест.
; Не 6, как в §7: под SCM каждая еда даёт пол стадии, 8 очков (прогон
; 2026-09-21, Hardcore.1.log), а Hungry — это пул от -48 до -96: до 12 штук.
Int MAX_ITEMS_PER_NEED = 12
; Шаг 7, MCM «Что лечить» и прочие тумблеры без констант-предшественников.
Bool ENABLE_HEALTH = true
Bool ENABLE_LIMBS = true
; MCM LimbsInPowerArmor: в силовой броне штрафы покалеченных конечностей не
; действуют (игроки, 2026-09-22) — по умолчанию лечить после выхода из брони.
Bool LIMBS_IN_PA = false
Bool ENABLE_DISEASE = true
Bool ENABLE_ADDICTION = true
Bool ALLOW_STIMPAK = true
Bool ALLOW_RADAWAY = true
; 0 — без уведомлений, 1 — сводка (§4.5).
Int NOTIFY_LEVEL = 1
Bool DRY_RUN = false
; Файлы исключений (Data\SurvivalAutoMedic\exclusions-*.json).
Bool USE_EXCLUSIONS = true
; Запас еды, утоляющей голод, который не тратится на ОЗ, радиацию и излечение
; (0 — выкл.). FOOD_RESERVE_RADS: облучённая еда тоже считается запасом.
Int FOOD_RESERVE = 10
Bool FOOD_RESERVE_RADS = true
; Папка мода для GOEPE (путь от папки игры): файлы исключений и свой лог.
; Её создаёт установка мода (там лежит exclusions-default.json).
String Property MOD_DATA_PATH = ".\\Data\\SurvivalAutoMedic\\" AutoReadOnly Hidden
; Формы из файлов исключений: мод их не использует никогда.
Form[] AM_Excluded
; Стадия, которой не бывает (0..5): выключенный голод/жажда не срабатывает никогда.
Int Property STAGE_NEVER = 99 AutoReadOnly Hidden
; Так же для радиации: порога в 100 000 rad не достичь.
Float Property RAD_PCT_NEVER = 10000.0 AutoReadOnly Hidden
; Настройки, записанные в лог последними (строка SETTINGS пишется при смене).
String AM_SettingsText = ""
; Столько штук подряд без смены стадии — предметы не насыщают, цикл встаёт.
; Самая широкая полоса до Ravenous — 48 очков, при поле 8 это 6 штук.
Int Property MAX_STALLED = 7 AutoReadOnly Hidden
; Сколько ждать, пока предмет уйдёт из инвентаря после EquipItem
; (шаг 4, A16: ~200 мс).
Float Property CONSUME_WAIT = 2.0 AutoReadOnly Hidden
; Сколько ждать смены стадии голода/жажды: HC_Manager засчитывает еду
; асинхронно (очередь + CallFunctionNoWait, шаг 4). На прогоне шага 6 —
; 130-310 мс; стадия внутри полосы не меняется вовсе, и каждое такое
; ожидание — чистая потеря, поэтому запас небольшой.
Float Property STAGE_WAIT = 1.5 AutoReadOnly Hidden
; Пауза перед циклами голода и жажды, если до них что-то принято: голод от
; RadAway (M8) и жажду от стимпака HC_Manager тоже засчитывает асинхронно.
Float Property SETTLE_WAIT = 1.0 AutoReadOnly Hidden

; --- шаг 5: цена предмета cost(i), §4.2. Всё в «крышках». ---
; Каждая лишняя штука — это ещё одна анимация и ещё одна строка в сводке:
; без этой надбавки 400 ОЗ добирались бы двадцатью морковками.
Float Property COST_PER_ITEM = 5.0 AutoReadOnly Hidden
; M14: за 1 % риска болезни; немедленная проверка — вдвое.
Float Property COST_PER_RISK_PCT = 5.0 AutoReadOnly Hidden
; M8/M10: иммунодефицит. Если он уже висит (или его даст другой предмет
; плана), новый только продлевает его — это дешевле.
Float Property COST_IMMUNO = 60.0 AutoReadOnly Hidden
Float Property COST_IMMUNO_ACTIVE = 15.0 AutoReadOnly Hidden
; Последние штуки ценнее: COST_SCARCITY / сколько есть.
Float Property COST_SCARCITY = 10.0 AutoReadOnly Hidden
; Ниже этого балла (выгода на крышку) средство вывода не берётся, даже если
; нужда осталась: иначе жадный подбор тратит целый RadAway на последние 20 rad.
; Остаток уходит в UNMET как «невыгодно». RadAway (~105c) проходит порог с 53 rad.
; Для ОЗ порога больше нет: стадия C ищет минимум перелечения (PlanHealth).
Float Property MIN_SCORE_RADS = 0.5 AutoReadOnly Hidden

; Перки меняются редко, а 20+ HasPerk стоили 0.36 с на цикл (шаг 3). Кеш
; сбрасывается при смене уровня (одна GetLevel) и страховочно раз в 10 минут:
; бобблхед «Медицина» и журналы дают перк без повышения уровня. Было 30 с —
; и цикл болезней раз в ~32 с промахивался мимо кеша почти всегда (0.4 с).
Float Property PERK_REFRESH_SECONDS = 600.0 AutoReadOnly Hidden
; Сверять снимок болезней/зависимостей со старым способом (HasMagicEffect /
; HasSpell). Только на уровне Trace; время пишется в TIME отдельно.
Bool Property VERIFY_STATUS = true AutoReadOnly Hidden

; Шаг 4: сколько секунд после цикла писать изменения AV и эффектов (строки WATCH).
Int Property WATCH_SECONDS = 60 AutoReadOnly Hidden
; Длительность больше этой — постоянный эффект (у служебных зелий Survival
; fDuration приходит порядка 1e9, и R1() на ней переполняется).
; Не 1000000.0: оптимизатор PapyrusCompiler печатает его как 1E+06 и падает
; на обратном разборе («входная строка имела неверный формат»).
Float Property PERMANENT_DURATION = 999999.0 AutoReadOnly Hidden
; Цикл, занятый дольше этого, считается брошенным (см. RunCycle).
Float Property BUSY_TIMEOUT = 60.0 AutoReadOnly Hidden

; --- шаг 9: автоматический режим (§4.7) ------------------------------
; Опрос — таймер на этом же скрипте. Он идёт всегда: при выключенном
; авторежиме раз в AUTO_OFF_POLL с читается один флаг, так что включение
; в MCM подхватывается без перезагрузки.
Int Property TIMER_AUTO = 9 AutoReadOnly Hidden
; Профилактика (2026-09-22): снадобья перед сном и после рискового приёма,
; Рад-Х по скорости набора. Замер радиации — свой таймер, не авторежим:
; один GetValue раз в RADX_POLL с работает и при выключенной автоматике.
Int Property TIMER_HERBAL = 10 AutoReadOnly Hidden
Int Property TIMER_RADX = 11 AutoReadOnly Hidden
Float Property RADX_POLL = 1.0 AutoReadOnly Hidden
Float Property RADX_OFF_POLL = 10.0 AutoReadOnly Hidden
; Серия приёмов (цикл голода ест 5-10 штук подряд) — один доприём снадобий.
Float Property HERBAL_DELAY = 0.5 AutoReadOnly Hidden
Float Property AUTO_OFF_POLL = 5.0 AutoReadOnly Hidden
; Пауза после любого цикла: исполнение ждёт смены стадий, и «в полёте»
; должно успеть появиться в GetActiveEffects.
Float Property AUTO_MIN_GAP = 3.0 AutoReadOnly Hidden
; Сколько вне боя ждать конца сцены (диалога) с игроком — дальше она
; считается застрявшей и авторежиму не мешает.
Float Property AUTO_SCENE_WAIT = 30.0 AutoReadOnly Hidden
; Болезни и зависимости дёшево не прочитать (нужен GetActiveEffects) —
; полный цикл раз в столько секунд (и в бою); нужд нет — он молчит.
Float Property AUTO_STATUS_SEC = 30.0 AutoReadOnly Hidden
; «Стало хуже» — повтор раньше AutoRetrySec.
Float Property AUTO_WORSE_HP_PCT = 10.0 AutoReadOnly Hidden
Float Property AUTO_WORSE_RADS = 50.0 AutoReadOnly Hidden
; «Нечего принять» (2026-09-22): незакрытые нужды и сколько у игрока предметов
; из списка каждой (AutoMedicTables.NeedList). Пока нужды те же и средств не
; прибавилось, проверка болезней раз в 30 с останавливается на снимке эффектов,
; а пауза AutoRetrySec снимается, как только средство появилось. Страховка —
; полная проверка не реже раза в AUTO_IDLE_MAX с.
Float Property AUTO_IDLE_MAX = 300.0 AutoReadOnly Hidden
Bool AU_IdleValid = false
Float AU_IdleSince = 0.0
Int AU_IdleNeedBits = 0
Int[] AU_IdleCnt
Int AU_IdleDisease = 0
Int AU_IdleAddiction = 0
String AU_IdleSettings = ""
; GetItemCount(FormList) считает все предметы списка — проверяется на деле:
; кандидаты под нужду есть, а счёт 0 — значит, не считает, и всё это выключается.
Bool AU_ListsOK = true
String AU_NewWhat = ""
; Списки по индексу бита USE_* (0 hp ... 7 limbs), копия из AutoMedicTables.
FormList[] NL_Lists

; Реальное время (GetCurrentRealTime; в новой сессии игры идёт с нуля —
; поэтому сбрасываются на загрузке).
Float AU_LastEnd = 0.0
Float AU_LastStatus = 0.0
Float AU_RetryAt = 0.0
; Последняя записанная в лог причина, по которой опрос не запустил цикл (AutoSkip).
String AU_SkipWhy = ""
; Начало непрерывной сцены с игроком (реальное время), 0 — не в сцене.
Float AU_SceneSince = 0.0
; Состояние, при котором авто-цикл ничего не принял (для «стало хуже»).
Float AU_IdleHPPct = 0.0
Float AU_IdleRads = 0.0
Float AU_IdleHunger = 0.0
Float AU_IdleThirst = 0.0
Int AU_IdleCrippled = 0
Bool AU_IdleCombat = false
; Какие пороги сработали (биты USE_*): у запущенного цикла и у последнего
; «пустого». Новый сработавший порог — тоже «стало хуже».
Int AU_PendingBits = 0
Int AU_IdleBits = 0
; Режим текущего цикла: 0 нажатие, 1 авто, 2 авто в бою.
Int AU_Mode = 0
Int Property MODE_ITEM = 0 AutoReadOnly Hidden
Int Property MODE_AUTO = 1 AutoReadOnly Hidden
Int Property MODE_COMBAT = 2 AutoReadOnly Hidden
; Строка настроек авторежима для SETTINGS.
String AU_Text = ""

; --- назначение кандидата (биты K_Uses) -----------------------------
Int Property USE_HP = 1 AutoReadOnly Hidden
Int Property USE_RADS = 2 AutoReadOnly Hidden
Int Property USE_HUNGER = 4 AutoReadOnly Hidden
Int Property USE_THIRST = 8 AutoReadOnly Hidden
Int Property USE_DISEASE = 16 AutoReadOnly Hidden
Int Property USE_ADDICTION = 32 AutoReadOnly Hidden
Int Property USE_AP = 64 AutoReadOnly Hidden
Int Property USE_LIMBS = 128 AutoReadOnly Hidden

; --- нужда, под которую взята строка плана (P_For) -------------------
Int Property NEED_RADS = 1 AutoReadOnly Hidden
Int Property NEED_LIMBS = 2 AutoReadOnly Hidden
Int Property NEED_HP = 3 AutoReadOnly Hidden
Int Property NEED_DISEASE = 4 AutoReadOnly Hidden
Int Property NEED_ADDICTION = 5 AutoReadOnly Hidden

Bool AM_ToolGiven = false
Bool AM_LogOpen = false
Bool AM_Busy = false
Float AM_BusyStart = 0.0
Int AM_Cycle = 0
Int AM_WatchToken = 0

; Наблюдение: известные временные эффекты, ключ — адрес экземпляра эффекта.
String[] W_Keys
String[] W_Names
Float[] W_Left

; =====================================================================
;  Формы Fallout4.esm, нужные фазе 0. Собираются на каждой загрузке:
;  ~70 вызовов GetFormFromFile, это доли секунды.
; =====================================================================

ActorValue AV_Health
ActorValue AV_Rads
ActorValue AV_AP
ActorValue AV_Hunger
ActorValue AV_Thirst
ActorValue AV_Sleep
ActorValue[] AV_Limbs
String[] LimbNames

Perk[] PK_Medic
Perk[] PK_LeadBelly
Perk[] PK_Adamantium
Perk[] PK_ChemResistant
Perk[] PK_PartyBoy
Perk[] PK_PartyGirl
Perk[] PK_Aquaboy
Perk[] PK_Aquagirl
Perk PK_BobbleMedicine

MagicEffect[] ME_Disease
String[] DiseaseNames
MagicEffect[] ME_Herbal
String[] HerbalNames
MagicEffect ME_Immuno
MagicEffect ME_RadX
; RadAway «в полёте» GOEPE показывает без бобблхеда (шаг 4) — поправка ×1.1.
MagicEffect ME_RestoreRadsChem
Spell[] SP_Addiction
String[] AddictionNames
GlobalVariable GV_SurvivalSustenance
Keyword KW_SleepFurniture
; В порядке ME_Herbal / HerbalNames.
Potion[] HB_Items
Potion RX_Item
String HB_Reason
Float RX_LastRads
Float RX_LastTime = 0.0
; Сколько секунд подряд скорость набора держится выше порога.
Float RX_HotSec

; =====================================================================
;  Кеши между циклами (сбрасываются на загрузке)
; =====================================================================

; Цена предмета: GetGoldValue ждёт кадра, а за сессию цена не меняется.
Form[] VC_Forms
Int[] VC_Values
; Имя предмета для лога: GetNthItemName — тоже вызов на кадр.
Form[] NC_Forms
String[] NC_Names
; Перки: время последнего чтения (реальное) и ответы HasPerk для перков
; из вариантов таблицы (журналы Wasteland Survival, Cannibal).
Float S_PerksAt = 0.0
Int S_PerksLevel = -1
Int[] PC_Ids
Bool[] PC_Has

; =====================================================================
;  Снимок фазы 0 (перезаписывается каждым циклом)
; =====================================================================

Float S_HP
Float S_HPBase
Float S_HPPct
Float S_MaxHP
Float S_Rads
Float S_AP
Float S_APPct
; GetBaseValue: максимум ОД без дебафов (и без бафов) — для порога AP_BIG_PCT.
Float S_APBase
Float S_Hunger
Float S_Thirst
Float S_Sleep
Bool S_OverEncumbered
Bool S_Survival
Bool S_InCombat
Bool S_InPowerArmor
Int S_CrippledCount
String S_Crippled

Int S_Medic
Int S_LeadBelly
Int S_Adamantium
Int S_ChemResistant
Int S_PartyBoy
Int S_Aquaboy
Bool S_BobbleMedicine
Bool S_PerksCached

Int S_DiseaseCount
String S_Diseases
Int S_AddictionCount
String S_Addictions
Bool S_Immuno
Bool S_RadX
String S_Herbals
String S_StatusCheck

Int S_EffectsTotal
Float S_InHeal
Float S_InHealPct
Float S_InRadOut
Float S_InRadIn
Float S_InAP
Float S_InDamage
Bool S_AntiradActive

Float N_Hunger
Float N_Thirst
Float N_Rads
Float N_HP
Float N_EffMaxNow
Float N_EffMaxAfter
Float N_HPPctEff
Bool N_HPTriggered
Float N_RadTrigger
Float N_RadTarget
Int N_Limbs
Int N_Disease
Int N_Addiction
Bool N_AP
Int N_Uses

; --- кандидаты (сведены по форме) ---
Int C_Total
Int C_Unknown
Int C_Excluded
Int C_Idle
; Каким путём читался инвентарь: F4SE (GetInventoryItems) или GOEPE (ячейки).
String C_Path = ""
; Сколько занял сам вызов списка (GetInventoryItems / GetItemIndexesByFormType).
Float C_ListSec = 0.0
Int C_HPCount
Int C_RadsCount
Int C_HungerCount
; Штук еды в запасе (сумма K_Counts по K_InPool).
Int C_FoodPool
; Штук Ядер-Колы (сумма K_Counts по K_InCola) и сколько видов ОД-напитков
; заперто порогом ОД (K_APLocked).
Int C_ColaPool
Int C_APLocked
Float C_APBig
String C_APWhy
Int C_ThirstCount
Int C_DiseaseCount
Int C_AddictionCount
Int C_APCount
Int C_LimbsCount
Int C_HungerCheapest
Int C_ThirstCheapest
Bool C_HungerWillClose
; Исключённые предметы — для лога; имена читаются уже в отчёте, чтобы
; GetNthItemName не попадал в замер инвентаря.
Form[] X_Forms
Int[] X_Slots
String[] X_Why

Form[] K_Forms
Int[] K_Rows
Int[] K_Counts
Int[] K_Slots
Int[] K_Uses
Int[] K_Flags
Int[] K_Values
Int[] K_Risk
Int[] K_Avail
Float[] K_Heal
Float[] K_RadOut
Float[] K_RadIn
; M4: еда (ObjectTypeFood без HC_IgnoreAsFood), съеденная голодным, не
; действует вовсе — перк HC_SustenanceEffectsTurnOffFood обнуляет ВСЕ её
; эффекты. Такие предметы исполнение ставит после цикла по голоду.
Bool[] K_AfterFood
; Кандидат входит в запас еды (утоляет голод; облучённый — если FOOD_RESERVE_RADS).
Bool[] K_InPool
Bool[] K_InCola
Bool[] K_APLocked
; K_AfterFood, а голод закрыть нечем: лечения/вывода/излечения не даст.
Bool[] K_Dead
String[] K_Names

; --- план (одна строка = одна штука) ---
Int[] P_K
Int[] P_For
Float[] P_Gain
Float[] P_Cost
String P_Trace
String P_Trim
String P_Notes
Float T_Heal
Float T_RadOut
Float T_RadIn
Bool T_Immuno
Bool P_LimitHit
; Подходящую еду не взяли, чтобы не тронуть запас (для UNMET).
Bool P_ReserveHit
; Лучший и второй кандидат последнего BestFor (для строки PICK).
Int G_Second
Float G_SecondScore
Int G_Considered
; Была ли нужда брошена из-за MIN_SCORE_* (для UNMET).
Bool P_RadsUnprofitable

; --- стадия C: поиск набора с минимальным перелечением (HealSearch) ---
; Типы кандидатов по убыванию H_Cov: кандидат k, закрытие нужды за штуку,
; потери потолка радиацией за штуку, cost, сколько штук можно, в запасе ли еды, rads.
Int[] H_K
Float[] H_Cov
Float[] H_Pen
Float[] H_Cost
Int[] H_Left
Bool[] H_Pool
Float[] H_Rad
Int[] H_Cur
Int[] H_BestCur
Float H_Rem
Float H_Goal
Int H_Slots
Float H_RadRoom
Bool H_HasCap
Float H_RadCap
Bool H_HasPool
Int H_PoolRoom
Bool[] H_Cola
Bool H_HasCola
Int H_ColaRoom
Int H_Nodes
; Лучший набор: класс (-1 — нет, 0 — добран, 1 — недобор), потери, штук, cost.
Int H_BestCls
Float H_BestW
Int H_BestN
Float H_BestCost

; --- исполнение (фаза 3) ---
Bool E_DryRun
; Сколько штук кандидата k уже принято в этом цикле.
Int[] E_Used
; Строка плана e уже исполнена (или пропущена).
Bool[] E_Done
; Кандидат k исключён из циклов голода/жажды: не применился или не сдвинул стадию.
Bool[] E_Bad
Int E_Step
; rads, съеденные циклами голода и жажды (MAX_INGESTED_RADS общий с планом).
Float E_LoopRadIn
String E_Unmet
; Итог после исполнения (строка AFTER и сводка).
Float A_HP
Float A_MaxHP
Float A_Rads
Float A_Hunger
Float A_Thirst
Float A_InHeal
Float A_InRadOut
Int A_Crippled
; «В полёте» по ScanInFlight (исполнение).
Float F_Heal
Float F_RadOut
Float F_RadIn

Actor Function PlayerRef()
    Return Game.GetPlayer()
EndFunction

; =====================================================================
;  Лог (§6)
; =====================================================================

; Куда пишется лог (MCM «Диагностика», LogTarget): 0 никуда, 1 свой файл
; (по умолчанию), 2 лог Papyrus, 3 оба.
;
; Свой файл — Data\SurvivalAutoMedic\AutoMedic.log через GOEPE
; (WriteLinesToFile): не зависит от bEnableLogging/bEnableTrace (с включёнными
; логами Papyrus игра подтормаживает) и читается сразу, а не после выхода из
; игры, как буферизованный Logs\Script\User\AutoMedic.0.log.
; Строки копятся в L_Buffer и уходят в файл одной записью (FlushLog) — в конце
; цикла, по ходу WATCH и при заполнении буфера: каждая запись — вызов native.
Int Property LOG_TO_NONE = 0 AutoReadOnly Hidden
Int Property LOG_TO_FILE = 1 AutoReadOnly Hidden
Int Property LOG_TO_PAPYRUS = 2 AutoReadOnly Hidden
Int Property LOG_TO_BOTH = 3 AutoReadOnly Hidden
String Property LOG_FILE = "AutoMedic.log" AutoReadOnly Hidden
String Property LOG_FILE_OLD = "AutoMedic.1.log" AutoReadOnly Hidden
String Property LOG_FILE_OLDER = "AutoMedic.2.log" AutoReadOnly Hidden
; Больше этого файл уезжает в AutoMedic.1.log (а тот — в .2). Только по
; размеру, не на загрузке. Без флага перезаписи WriteLinesToFile не дописывает
; (результат False, прогон 01:32), поэтому каждая запись — «прочитать весь файл,
; добавить, перезаписать»: размер держим умеренным.
Float Property LOG_MAX_KB = 512.0 AutoReadOnly Hidden
; Papyrus-массив, растущий через Add, упирается в 128 — сброс заранее.
Int Property LOG_BUFFER_MAX = 100 AutoReadOnly Hidden

Int LOG_TARGET = 1
String[] L_Buffer
; Дописывает ли WriteLinesToFile без флага перезаписи в конец файла.
; Документация GOEPE молчит, поэтому режим определяется при открытии лога
; (LogProbeAppend); false — «прочитать файл, добавить, перезаписать».
Bool L_Append = false
; Файл в этой сессии уже начат заново и режим записи определён.
Bool L_Probed = false

; Шаг 9: авто-цикл придерживает свои строки, пока не ясно, нужно ли что-то
; (ReleaseLog / DropLog). Иначе проверка болезней раз в 30 с засыпала бы
; лог пустыми циклами.
Bool L_Hold = false
String[] L_Held

Function HoldLog()
    L_Held = new String[0]
    L_Hold = true
EndFunction

Function ReleaseLog()
    L_Hold = false
    Int i = 0
    While i < L_Held.Length
        Log(L_Held[i])
        i += 1
    EndWhile
    L_Held = new String[0]
EndFunction

Function DropLog()
    L_Hold = false
    L_Held = new String[0]
EndFunction

Function Log(String asText)
    If L_Hold
        L_Held.Add(asText)
        If L_Held.Length >= LOG_BUFFER_MAX
            ReleaseLog()
        EndIf
        Return
    EndIf
    If LOG_TARGET == LOG_TO_PAPYRUS || LOG_TARGET == LOG_TO_BOTH
        ; Если TraceUser отказал (логирование Papyrus выключено в ini), больше
        ; не пытаемся до следующей загрузки — это не ошибка.
        If AM_LogOpen
            AM_LogOpen = Debug.TraceUser("AutoMedic", asText)
        EndIf
    EndIf
    If LOG_TARGET == LOG_TO_FILE || LOG_TARGET == LOG_TO_BOTH
        If L_Buffer == None
            L_Buffer = new String[0]
        EndIf
        L_Buffer.Add(asText)
        If L_Buffer.Length >= LOG_BUFFER_MAX
            FlushLog()
        EndIf
    EndIf
EndFunction

; Для строк пустых авто-циклов: пишем не чаще раза в LOG_FLUSH_MIN_GAP с —
; без дописывания каждая запись перечитывает и переписывает весь файл, и
; делать это раз в 30 с значило бы самому давать нагрузку, которую меряем.
Float Property LOG_FLUSH_MIN_GAP = 60.0 AutoReadOnly Hidden
Float L_LastFlush = 0.0

Function FlushLogThrottled()
    Float now = Utility.GetCurrentRealTime()
    If now < L_LastFlush || now - L_LastFlush >= LOG_FLUSH_MIN_GAP
        FlushLog()
    EndIf
EndFunction

; Записать накопленное в свой файл.
Function FlushLog()
    L_LastFlush = Utility.GetCurrentRealTime()
    If L_Buffer == None || L_Buffer.Length == 0
        Return
    EndIf
    String[] lines = L_Buffer
    L_Buffer = new String[0]
    If GardenOfEden3.GetFileSizeKB(LOG_FILE, MOD_DATA_PATH) > LOG_MAX_KB
        RotateLog()
    EndIf
    If L_Append
        GardenOfEden3.WriteLinesToFile(LOG_FILE, MOD_DATA_PATH, lines, false)
    Else
        String[] old = GardenOfEden2.GetLinesFromFile(LOG_FILE, MOD_DATA_PATH)
        If old == None
            old = new String[0]
        EndIf
        GardenOfEden3.WriteLinesToFile(LOG_FILE, MOD_DATA_PATH, \
            GardenOfEden3.MergeArraysString(old, lines), true)
    EndIf
EndFunction

; Подготовить свой файл: раз за загрузку — определить режим записи и отбить
; загрузку разделителем. Файл при загрузке НЕ начинается заново: смерть и
; автозагрузка иначе вытесняли нужную сессию в .1, а следующая — совсем
; (прогон 2026-09-22 01:43). Зовётся и из LoadSettings: цель лога могли
; переключить в MCM посреди игры.
Function EnsureFileLog()
    If !L_Probed
        L_Probed = true
        If !GardenOfEden2.DoesFileExist(LOG_FILE, MOD_DATA_PATH)
            StartLogFile()
        EndIf
        LogProbeAppend()
        Log("")
        Log("=== загрузка сохранения, " + GardenOfEden2.GetCurrentDateAndTimeAsString() + " ===")
    EndIf
EndFunction

; Только по размеру: AutoMedic.1.log -> .2, AutoMedic.log -> .1, новый файл.
Function RotateLog()
    CopyLogFile(LOG_FILE_OLD, LOG_FILE_OLDER)
    CopyLogFile(LOG_FILE, LOG_FILE_OLD)
    StartLogFile()
EndFunction

Function CopyLogFile(String asFrom, String asTo)
    If GardenOfEden2.DoesFileExist(asFrom, MOD_DATA_PATH)
        String[] lines = GardenOfEden2.GetLinesFromFile(asFrom, MOD_DATA_PATH)
        If lines != None && lines.Length > 0
            GardenOfEden3.WriteLinesToFile(asTo, MOD_DATA_PATH, lines, true)
        EndIf
    EndIf
EndFunction

Function StartLogFile()
    String[] head = new String[1]
    head[0] = "=== AutoMedic log, " + GardenOfEden2.GetCurrentDateAndTimeAsString() + " ==="
    GardenOfEden3.WriteLinesToFile(LOG_FILE, MOD_DATA_PATH, head, true)
EndFunction

; Дописывает ли WriteLinesToFile(..., false) в конец существующего файла:
; записать одну строку и посмотреть, вырос ли файл.
Function LogProbeAppend()
    Int before = GardenOfEden3.GetFileSize(LOG_FILE, MOD_DATA_PATH)
    String[] probe = new String[1]
    probe[0] = "(проверка режима записи)"
    Bool ok = GardenOfEden3.WriteLinesToFile(LOG_FILE, MOD_DATA_PATH, probe, false)
    Int after = GardenOfEden3.GetFileSize(LOG_FILE, MOD_DATA_PATH)
    L_Append = after > before
    String mode = "дописывание в конец"
    If !L_Append
        mode = "перезапись файла целиком (WriteLinesToFile без флага не дописывает)"
    EndIf
    Log("Лог: " + mode + " — размер " + before + " -> " + after + " байт, результат " + ok)
EndFunction

; Результат OpenUserLog НЕ показатель. Список открытых пользовательских логов
; уезжает в сейв, и после загрузки лог уже числится открытым — OpenUserLog
; тогда возвращает false («fails if the log is already open»), хотя писать
; в него можно. Найдено 2026-09-21: из-за доверия этому false мод молчал
; всю сессию, а в сейве рядом с логами AFT лежало имя «AutoMedic».
;
; Вызывается на OnQuestInit и каждой загрузке: настройки к этому моменту ещё
; не прочитаны, поэтому цель лога берётся прямо из AM_Settings. Свой файл
; продолжается, загрузка отбивается разделителем (EnsureFileLog).
Function OpenLog()
    L_Buffer = new String[0]
    DropLog()
    L_Probed = false
    AM_LogOpen = false
    ; AM_SettingsText уезжает в сейв: без сброса строка SETTINGS после загрузки
    ; не писалась, если настройки не менялись (прогон 2026-09-22 02:02).
    AM_SettingsText = ""
    SetLogTarget(AM_Settings.LogTarget)
EndFunction

; Сменить цель лога: открыть то, что раньше не было открыто.
Function SetLogTarget(Int aiTarget)
    LOG_TARGET = aiTarget
    If (LOG_TARGET == LOG_TO_PAPYRUS || LOG_TARGET == LOG_TO_BOTH) && !AM_LogOpen
        Debug.OpenUserLog("AutoMedic")
        AM_LogOpen = true
    EndIf
    If LOG_TARGET == LOG_TO_FILE || LOG_TARGET == LOG_TO_BOTH
        EnsureFileLog()
    EndIf
EndFunction

Function LogAt(Int aiLevel, String asText)
    If LOG_LEVEL >= aiLevel
        Log(asText)
    EndIf
EndFunction

; Целое с округлением — Papyrus печатает Float как "142.000000".
String Function R0(Float afValue)
    If afValue < 0.0
        Return "-" + Math.Floor(-afValue + 0.5)
    EndIf
    Return "" + Math.Floor(afValue + 0.5)
EndFunction

; Один знак после запятой.
String Function R1(Float afValue)
    String sign = ""
    If afValue < 0.0
        sign = "-"
        afValue = -afValue
    EndIf
    Int tenths = Math.Floor(afValue * 10.0 + 0.5)
    Return sign + (tenths / 10) + "." + (tenths % 10)
EndFunction

String Function Join(String asList, String asItem)
    If asList == ""
        Return asItem
    EndIf
    Return asList + ", " + asItem
EndFunction

String Function HungerName(Float afStage)
    Int s = Math.Floor(afStage + 0.5)
    If s <= 0
        Return "Fed"
    ElseIf s == 1
        Return "Peckish"
    ElseIf s == 2
        Return "Hungry"
    ElseIf s == 3
        Return "Famished"
    ElseIf s == 4
        Return "Ravenous"
    EndIf
    Return "Starving"
EndFunction

String Function ThirstName(Float afStage)
    Int s = Math.Floor(afStage + 0.5)
    If s <= 0
        Return "Hydrated"
    ElseIf s == 1
        Return "Parched"
    ElseIf s == 2
        Return "Thirsty"
    ElseIf s == 3
        Return "MildlyDehydrated"
    ElseIf s == 4
        Return "Dehydrated"
    EndIf
    Return "SeverelyDehydrated"
EndFunction

; Шкала сна на единицу длиннее голода и жажды: 0 — Well Rested / Lover's
; Embrace, 1 — Rested. Значения — глобалы HC_SE_* в Fallout4.esm.
String Function SleepName(Float afStage)
    Int s = Math.Floor(afStage + 0.5)
    If s <= 0
        Return "WellRested"
    ElseIf s == 1
        Return "Rested"
    ElseIf s == 2
        Return "Tired"
    ElseIf s == 3
        Return "Overtired"
    ElseIf s == 4
        Return "Weary"
    ElseIf s == 5
        Return "Exhausted"
    EndIf
    Return "Incapacitated"
EndFunction

; Длительность для лога: у постоянных эффектов вместо переполненного числа — inf.
String Function Dur(Float afSeconds)
    If afSeconds > PERMANENT_DURATION
        Return "inf"
    EndIf
    Return R1(afSeconds)
EndFunction

; Число со знаком: "+12.5" / "-3.0".
String Function Signed(Float afValue)
    If afValue >= 0.0
        Return "+" + R1(afValue)
    EndIf
    Return R1(afValue)
EndFunction

String Function NeedName(Int aiNeed)
    If aiNeed == NEED_RADS
        Return "rads"
    ElseIf aiNeed == NEED_LIMBS
        Return "limbs"
    ElseIf aiNeed == NEED_HP
        Return "hp"
    ElseIf aiNeed == NEED_DISEASE
        Return "disease"
    ElseIf aiNeed == NEED_ADDICTION
        Return "addict"
    EndIf
    Return "?"
EndFunction

; =====================================================================
;  Биты без битовых операций (в ванильном Papyrus их нет)
; =====================================================================

Bool Function Has(Int aiBits, Int aiMask)
    Return AutoMedicTables.HasFlag(aiBits, aiMask)
EndFunction

Int Function WithBit(Int aiBits, Int aiMask)
    If Has(aiBits, aiMask)
        Return aiBits
    EndIf
    Return aiBits + aiMask
EndFunction

; Есть ли у двух наборов USE_* общий бит.
Bool Function Shares(Int aiA, Int aiB)
    Int mask = 1
    While mask <= USE_LIMBS
        If Has(aiA, mask) && Has(aiB, mask)
            Return true
        EndIf
        mask *= 2
    EndWhile
    Return false
EndFunction

; =====================================================================
;  Локальная копия таблицы (разбор фризов авторежима, 2026-09-22)
; =====================================================================
;
; Чтение свойства или вызов функции ДРУГОГО скрипта — внешний вызов: поток
; отпускает блокировку и может встать в очередь (Threading Notes, CK wiki).
; В цикле такие обращения к AM_Tables шли на каждый из ~107 активных эффектов
; (EffectRole + до 6 констант ROLE_*) и на каждый предмет инвентаря. Здесь всё
; это копируется к себе один раз за загрузку (Refresh), а массивы структур
; берутся по ссылке: операции с массивами внешними вызовами не считаются.
AutoMedicTables:ItemData[] TB_Items0
AutoMedicTables:ItemData[] TB_Items1
AutoMedicTables:ItemData[] TB_Items2
AutoMedicTables:EffectData[] TB_Effects
Int TB_ChunkSize = 128
Int TB_ItemCount = 0

Int TR_NONE
Int TR_HEAL_HP
Int TR_HEAL_HP_PCT
Int TR_RADS_REMOVE
Int TR_RADS_ADD
Int TR_AP_RESTORE
Int TR_DAMAGE_HP

Int TF_ADDICTIVE
Int TF_BLACKLISTED
Int TF_CAT_ALCOHOL
Int TF_CAT_FOOD
Int TF_CAT_COLA
Int TF_CAT_STIMPAK
Int TF_CAT_SYRINGER
Int TF_CURES_ADDICTION
Int TF_CURES_DISEASE
Int TF_IGNORE_AS_FOOD
Int TF_IMMEDIATE_CHECK
Int TF_IMMUNO_DEF
Int TF_SATES_HUNGER
Int TF_SATES_THIRST

; После каждой (пере)сборки таблицы: BuildTables создаёт новые массивы.
Function CacheTables()
    AutoMedicTables t = AM_Tables
    TB_Items0 = t.ItemChunk(0)
    TB_Items1 = t.ItemChunk(1)
    TB_Items2 = t.ItemChunk(2)
    TB_Effects = t.GetEffects()
    TB_ChunkSize = t.CHUNK_SIZE
    TB_ItemCount = t.ITEM_COUNT

    TR_NONE = t.ROLE_NONE
    TR_HEAL_HP = t.ROLE_HEAL_HP
    TR_HEAL_HP_PCT = t.ROLE_HEAL_HP_PCT
    TR_RADS_REMOVE = t.ROLE_RADS_REMOVE
    TR_RADS_ADD = t.ROLE_RADS_ADD
    TR_AP_RESTORE = t.ROLE_AP_RESTORE
    TR_DAMAGE_HP = t.ROLE_DAMAGE_HP

    TF_ADDICTIVE = t.FLAG_ADDICTIVE
    TF_BLACKLISTED = t.FLAG_BLACKLISTED
    TF_CAT_ALCOHOL = t.FLAG_CAT_ALCOHOL
    TF_CAT_FOOD = t.FLAG_CAT_FOOD
    TF_CAT_COLA = t.FLAG_CAT_COLA
    TF_CAT_STIMPAK = t.FLAG_CAT_STIMPAK
    TF_CAT_SYRINGER = t.FLAG_CAT_SYRINGER
    TF_CURES_ADDICTION = t.FLAG_CURES_ADDICTION
    TF_CURES_DISEASE = t.FLAG_CURES_DISEASE
    TF_IGNORE_AS_FOOD = t.FLAG_IGNORE_AS_FOOD
    TF_IMMEDIATE_CHECK = t.FLAG_IMMEDIATE_CHECK
    TF_IMMUNO_DEF = t.FLAG_IMMUNO_DEF
    TF_SATES_HUNGER = t.FLAG_SATES_HUNGER
    TF_SATES_THIRST = t.FLAG_SATES_THIRST

    NL_Lists = new FormList[8]
    Int b = 0
    Int mask = 1
    While b < 8
        NL_Lists[b] = t.NeedList(mask)
        b += 1
        mask *= 2
    EndWhile
EndFunction

AutoMedicTables:ItemData[] Function ItemChunkL(Int aiChunk)
    If aiChunk == 0
        Return TB_Items0
    ElseIf aiChunk == 1
        Return TB_Items1
    ElseIf aiChunk == 2
        Return TB_Items2
    EndIf
    Return None
EndFunction

; Как AutoMedicTables.GetItemData, но без внешнего вызова.
AutoMedicTables:ItemData Function ItemDataL(Int aiRow)
    AutoMedicTables:ItemData[] rows = None
    If aiRow >= 0 && aiRow < TB_ItemCount
        rows = ItemChunkL(aiRow / TB_ChunkSize)
    EndIf
    If rows == None
        AutoMedicTables:ItemData empty = new AutoMedicTables:ItemData
        Return empty
    EndIf
    Return rows[aiRow % TB_ChunkSize]
EndFunction

; Как AutoMedicTables.IndexOfFullId.
Int Function IndexOfFullIdL(Int aiFormId)
    If aiFormId == 0
        Return -1
    EndIf
    Int chunk = 0
    While chunk < 3
        AutoMedicTables:ItemData[] rows = ItemChunkL(chunk)
        If rows != None
            Int slot = rows.FindStruct("FullId", aiFormId, 0)
            If slot >= 0
                Return chunk * TB_ChunkSize + slot
            EndIf
        EndIf
        chunk += 1
    EndWhile
    Return -1
EndFunction

; Как AutoMedicTables.EffectRole.
Int Function EffectRoleL(MagicEffect akEffect)
    If akEffect == None || TB_Effects == None
        Return TR_NONE
    EndIf
    Int slot = TB_Effects.FindStruct("Effect", akEffect, 0)
    If slot < 0
        Return TR_NONE
    EndIf
    Return TB_Effects[slot].Role
EndFunction

; =====================================================================
;  Жизненный цикл
; =====================================================================

Event OnQuestInit()
    OpenLog()
    Log("=== AutoMedic: инициализация ===")
    RegisterForRemoteEvent(PlayerRef(), "OnPlayerLoadGame")
    Refresh(false)
EndEvent

; AM_Busy здесь НЕ сбрасывается: стек цикла, прерванного сохранением, уезжает
; в сейв и доигрывает после загрузки (цикл #4 на шаге 3 так и доработал).
; Сброс разрешал второй цикл параллельно с ним. Брошенный цикл снимает
; таймаут в RunCycle.
Event Actor.OnPlayerLoadGame(Actor akSender)
    OpenLog()
    Refresh(false)
EndEvent

; Пересобирает таблицу, если версия данных изменилась, собирает формы
; фазы 0 и следит за тем, чтобы предмет-инструмент был у игрока.
Function Refresh(Bool abForce)
    If !AM_Tables.IsBuilt() || abForce
        Float started = Utility.GetCurrentRealTime()
        AM_Tables.BuildTables(abForce)
        Float spent = Utility.GetCurrentRealTime() - started
        ; A19 из §10: замерить стоимость ~350 вызовов GetFormFromFile.
        Log("Таблица собрана за " + spent + " с: разрешено " + AM_Tables.ResolvedCount() + \
            ", пропущено (нет DLC) " + AM_Tables.SkippedCount() + \
            ", без полного FormID " + AM_Tables.NoFullIdCount() + \
            ", в списке " + AM_AllConsumables.GetSize() + ", эффектов " + AM_Tables.EffectCount())
    Else
        Log("Таблица уже собрана: " + AM_Tables.ResolvedCount() + " предметов")
    EndIf
    CacheTables()
    Float t0 = Utility.GetCurrentRealTime()
    ResolveForms()
    Log("Формы фазы 0 собраны за " + R1((Utility.GetCurrentRealTime() - t0) * 1000.0) + " мс")
    ; Кеши сессии: цены и имена могли смениться вместе с модами и языком.
    VC_Forms = new Form[0]
    VC_Values = new Int[0]
    NC_Forms = new Form[0]
    NC_Names = new String[0]
    S_PerksAt = 0.0
    LoadExclusions()
    GiveToolOnce()
    FlushLog()
    ; Шаг 9: реальное время новой сессии идёт с нуля — отметки авторежима
    ; из сейва недействительны. Таймер перезапускается (тот же id — заменяет).
    AU_LastEnd = 0.0
    AU_LastStatus = 0.0
    AU_RetryAt = 0.0
    AU_IdleValid = false
    AU_SkipWhy = ""
    AU_SceneSince = 0.0
    AU_ListsOK = true
    StartTimer(AUTO_OFF_POLL, TIMER_AUTO)
    ; Профилактика: повторная регистрация после загрузки безвредна.
    RegisterForRemoteEvent(PlayerRef(), "OnSit")
    RegisterForRemoteEvent(PlayerRef(), "OnItemEquipped")
    RegisterForMenuOpenCloseEvent("SleepWaitMenu")
    RX_LastTime = 0.0
    RX_HotSec = 0.0
    StartTimer(RADX_POLL, TIMER_RADX)
EndFunction

; Предмет выдаётся ровно один раз: если игрок его выбросил или продал,
; навязывать обратно каждую загрузку мы не будем.
Function GiveToolOnce()
    If !AM_ToolGiven
        PlayerRef().AddItem(AM_Tool, 1, true)
        AM_ToolGiven = true
        Log("Предмет AutoMedic выдан игроку")
    EndIf
EndFunction

Form Function F4(Int aiLocalId)
    Return Game.GetFormFromFile(aiLocalId, "Fallout4.esm")
EndFunction

; FormID подтверждены сканом Fallout4.esm (EDID в комментариях).
Function ResolveForms()
    AV_Health = F4(0x0002D4) as ActorValue      ; Health
    AV_Rads = F4(0x0002E1) as ActorValue        ; Rads
    AV_AP = F4(0x0002D5) as ActorValue          ; ActionPoints
    AV_Hunger = F4(0x000855) as ActorValue      ; HC_HungerEffect
    AV_Thirst = F4(0x000868) as ActorValue      ; HC_ThirstEffect
    AV_Sleep = F4(0x000828) as ActorValue       ; HC_SleepEffect

    ; 0 = покалечено, 100 = целое. Голова — PerceptionCondition (шаг 4, T7);
    ; BrainCondition оставлен в логе для полноты.
    AV_Limbs = new ActorValue[7]
    LimbNames = new String[7]
    AV_Limbs[0] = F4(0x00036C) as ActorValue    ; PerceptionCondition
    LimbNames[0] = "Head"
    AV_Limbs[1] = F4(0x00036D) as ActorValue    ; EnduranceCondition
    LimbNames[1] = "Torso"
    AV_Limbs[2] = F4(0x00036E) as ActorValue    ; LeftAttackCondition
    LimbNames[2] = "LeftArm"
    AV_Limbs[3] = F4(0x00036F) as ActorValue    ; RightAttackCondition
    LimbNames[3] = "RightArm"
    AV_Limbs[4] = F4(0x000370) as ActorValue    ; LeftMobilityCondition
    LimbNames[4] = "LeftLeg"
    AV_Limbs[5] = F4(0x000371) as ActorValue    ; RightMobilityCondition
    LimbNames[5] = "RightLeg"
    AV_Limbs[6] = F4(0x000372) as ActorValue    ; BrainCondition
    LimbNames[6] = "Brain"

    ; Ранги — отдельные записи PERK; индекс в массиве = ранг - 1.
    PK_Medic = new Perk[4]
    PK_Medic[0] = F4(0x04C926) as Perk          ; Medic01
    PK_Medic[1] = F4(0x06FA1C) as Perk          ; Medic02
    PK_Medic[2] = F4(0x06FA1D) as Perk          ; Medic03
    PK_Medic[3] = F4(0x065E35) as Perk          ; Medic04
    PK_LeadBelly = new Perk[3]
    PK_LeadBelly[0] = F4(0x04A0B9) as Perk
    PK_LeadBelly[1] = F4(0x024B00) as Perk
    PK_LeadBelly[2] = F4(0x024B01) as Perk
    PK_Adamantium = new Perk[3]
    PK_Adamantium[0] = F4(0x04C92D) as Perk
    PK_Adamantium[1] = F4(0x024AFD) as Perk
    PK_Adamantium[2] = F4(0x024AFE) as Perk
    PK_ChemResistant = new Perk[2]
    PK_ChemResistant[0] = F4(0x04A0D5) as Perk
    PK_ChemResistant[1] = F4(0x065E0C) as Perk
    PK_PartyBoy = new Perk[3]
    PK_PartyBoy[0] = F4(0x04D887) as Perk
    PK_PartyBoy[1] = F4(0x1D2473) as Perk
    PK_PartyBoy[2] = F4(0x1D2474) as Perk
    PK_PartyGirl = new Perk[3]
    PK_PartyGirl[0] = F4(0x04D888) as Perk
    PK_PartyGirl[1] = F4(0x1D2475) as Perk
    PK_PartyGirl[2] = F4(0x1D2476) as Perk
    PK_Aquaboy = new Perk[2]
    PK_Aquaboy[0] = F4(0x0E36F9) as Perk
    PK_Aquaboy[1] = F4(0x1D248D) as Perk
    PK_Aquagirl = new Perk[2]
    PK_Aquagirl[0] = F4(0x0E9453) as Perk
    PK_Aquagirl[1] = F4(0x1D248E) as Perk
    PK_BobbleMedicine = F4(0x061681) as Perk    ; PerkBobbleheadMedicine

    ME_Disease = new MagicEffect[6]
    DiseaseNames = new String[6]
    ME_Disease[0] = F4(0x0008A1) as MagicEffect
    DiseaseNames[0] = "Fatigue"
    ME_Disease[1] = F4(0x0008A9) as MagicEffect ; HC_Disease_Infection_DamagePlayerEffect
    DiseaseNames[1] = "Infection"
    ME_Disease[2] = F4(0x00089F) as MagicEffect
    DiseaseNames[2] = "Insomnia"
    ME_Disease[3] = F4(0x0008B3) as MagicEffect
    DiseaseNames[3] = "Lethargy"
    ME_Disease[4] = F4(0x0008A2) as MagicEffect
    DiseaseNames[4] = "Parasites"
    ME_Disease[5] = F4(0x0008A5) as MagicEffect
    DiseaseNames[5] = "Weakness"

    ME_Herbal = new MagicEffect[3]
    HerbalNames = new String[3]
    ME_Herbal[0] = F4(0x249F9A) as MagicEffect  ; HC_Herbal_Antimicrobial_Effect
    HerbalNames[0] = "Antimicrobial"
    ME_Herbal[1] = F4(0x249F9B) as MagicEffect  ; HC_Herbal_Stimulant_Effect
    HerbalNames[1] = "Stimulant"
    ME_Herbal[2] = F4(0x249F9C) as MagicEffect  ; HC_Herbal_Anodyne_Effect
    HerbalNames[2] = "Anodyne"
    ME_Immuno = F4(0x249F2E) as MagicEffect     ; HC_Immunodeficiency
    ME_RadX = F4(0x246B11) as MagicEffect       ; FortifyResistRadsRadX
    ME_RestoreRadsChem = F4(0x023738) as MagicEffect
    GV_SurvivalSustenance = F4(0x000854) as GlobalVariable  ; HC_Rule_SustenanceEffects
    ; IsSleepFurniture: стоит на всех кроватях и спальниках игрока (скан FURN
    ; Fallout4.esm: нет только у трёх больничных NPC-кроватей).
    KW_SleepFurniture = F4(0x021B18) as Keyword
    HB_Items = new Potion[3]
    HB_Items[0] = F4(0x249F8F) as Potion  ; HC_Herbal_Antimicrobial
    HB_Items[1] = F4(0x249F8D) as Potion  ; HC_Herbal_Stimulant
    HB_Items[2] = F4(0x249F8E) as Potion  ; HC_Herbal_Anodyne
    RX_Item = F4(0x024057) as Potion      ; RadX

    ; Спеллы зависимостей Fallout4.esm (AbAddiction*). В DLC своих нет — проверено сканом.
    SP_Addiction = new Spell[25]
    AddictionNames = new String[25]
    SetAddiction(0, 0x03E061, "Alcohol")
    SetAddiction(1, 0x04BAE0, "Buffout")
    SetAddiction(2, 0x04BAE1, "Jet")
    SetAddiction(3, 0x04BAE2, "Mentats")
    SetAddiction(4, 0x04BAE3, "Psycho")
    SetAddiction(5, 0x04BAE4, "Med-X")
    SetAddiction(6, 0x04BAE5, "Nuka-Quantum")
    SetAddiction(7, 0x156D0A, "Fury")
    SetAddiction(8, 0x156D0C, "Calmex")
    SetAddiction(9, 0x156D0D, "X-Cell")
    SetAddiction(10, 0x156D0E, "Daddy-O")
    SetAddiction(11, 0x156D0F, "Day Tripper")
    SetAddiction(12, 0x156D10, "Overdrive")
    SetAddiction(13, 0x17E5C2, "Buffjet")
    SetAddiction(14, 0x17E668, "Bufftats")
    SetAddiction(15, 0x17E6B0, "Berry Mentats")
    SetAddiction(16, 0x17E6C2, "Grape Mentats")
    SetAddiction(17, 0x17E6C3, "Orange Mentats")
    SetAddiction(18, 0x17E6C4, "Jet Fuel")
    SetAddiction(19, 0x17E6C5, "Ultra Jet")
    SetAddiction(20, 0x17E6C6, "Psychojet")
    SetAddiction(21, 0x17E6C7, "Psychotats")
    SetAddiction(22, 0x17E6C9, "Psychobuff")
    SetAddiction(23, 0x19A7F5, "Lorenzo Serum")
    SetAddiction(24, 0x24615A, "Buzz Bites")
EndFunction

Function SetAddiction(Int aiSlot, Int aiLocalId, String asName)
    SP_Addiction[aiSlot] = F4(aiLocalId) as Spell
    AddictionNames[aiSlot] = asName
EndFunction

; =====================================================================
;  Вход: предмет применён
; =====================================================================

; Вызывается из AutoMedicScript. Сам цикл уходит в CallFunctionNoWait, чтобы
; эффект предмета закончился сразу, а не висел, пока идёт сбор состояния.
Function OnToolUsed(Actor akUser)
    ; Любое нажатие обрывает наблюдение от предыдущего.
    AM_WatchToken += 1
    Int mode = AM_TestMode.GetValueInt()
    If mode == 1
        LoadSettings()
        CallFunctionNoWait("RunConsumeTest", new Var[0])
        Return
    EndIf
    ; Настройки читает сам RunCycle, уже заняв цикл: иначе нажатие во время
    ; авто-цикла подменило бы ему пороги на ручные посреди исполнения.
    Var[] args = new Var[3]
    args[0] = "item"
    args[1] = mode == TEST_MODE_DRY_RUN
    args[2] = MODE_ITEM
    CallFunctionNoWait("RunCycle", args)
EndFunction

; =====================================================================
;  Шаг 7: настройки MCM
; =====================================================================

; Копия AM_Settings в переменные этого скрипта. Раз за нажатие, а не при
; каждом обращении: планировщик читает пороги и резервы на каждом кандидате,
; а каждое чтение свойства чужого скрипта — это вызов в другой объект.
; Строка SETTINGS пишется в лог при первом нажатии сессии и при любой смене.
Function LoadSettings()
    AutoMedicSettings m = AM_Settings
    If m.LogTarget != LOG_TARGET
        SetLogTarget(m.LogTarget)
    EndIf
    LOG_LEVEL = m.LogLevel
    NOTIFY_LEVEL = m.NotifyLevel
    DRY_RUN = m.DryRun
    ENABLE_HEALTH = m.EnableHealth
    ENABLE_LIMBS = m.EnableLimbs
    LIMBS_IN_PA = m.LimbsInPowerArmor
    ENABLE_DISEASE = m.EnableDisease
    ENABLE_ADDICTION = m.EnableAddiction
    ALLOW_STIMPAK = m.AllowStimpak
    ALLOW_RADAWAY = m.AllowRadAway

    ; В MCM «начинать с» — стадии 1..5 (свойство — индекс в списке, стадия =
    ; индекс + 1), «до» — стадии 0..4. Свойства названы *From, а не *Trigger:
    ; в первой сборке шага 7 *Trigger хранили саму стадию (список 0..5), и
    ; старое значение из сейва сдвинулось бы на стадию. Цель опускается ниже «начинать с»:
    ; «начинать с Лёгкого голода, есть до Голоден» иначе не делало бы ничего.
    HUNGER_TRIGGER = ClampInt(m.HungerFrom + 1, 1, 5)
    HUNGER_TARGET = ClampInt(m.HungerTarget, 0, HUNGER_TRIGGER - 1)
    THIRST_TRIGGER = ClampInt(m.ThirstFrom + 1, 1, 5)
    THIRST_TARGET = ClampInt(m.ThirstTarget, 0, THIRST_TRIGGER - 1)
    ; Для строки SETTINGS — пока выключенный голод не стал STAGE_NEVER.
    String hunger = HUNGER_TRIGGER + "->" + HUNGER_TARGET
    String thirst = THIRST_TRIGGER + "->" + THIRST_TARGET
    If !m.EnableHunger
        HUNGER_TRIGGER = STAGE_NEVER
    EndIf
    If !m.EnableThirst
        THIRST_TRIGGER = STAGE_NEVER
    EndIf

    HEAL_TRIGGER_PCT = m.HealTriggerPct as Float
    HEAL_TARGET_PCT = m.HealTargetPct as Float
    If HEAL_TARGET_PCT < HEAL_TRIGGER_PCT
        HEAL_TARGET_PCT = HEAL_TRIGGER_PCT
    EndIf
    RAD_TRIGGER_PCT = m.RadTriggerPct as Float
    RAD_TARGET_PCT = m.RadTargetPct as Float
    If RAD_TARGET_PCT > RAD_TRIGGER_PCT
        RAD_TARGET_PCT = RAD_TRIGGER_PCT
    EndIf
    If !m.EnableRads
        RAD_TRIGGER_PCT = RAD_PCT_NEVER
    EndIf

    MAX_ITEM_VALUE = m.MaxItemValue as Float
    MAX_DISEASE_RISK_PCT = m.MaxDiseaseRiskPct
    RESERVE_STIMPAKS = m.ReserveStimpaks
    RESERVE_RADAWAY = m.ReserveRadAway
    MAX_INGESTED_RADS = m.MaxIngestedRads as Float
    RAD_CAP_WITHOUT_CURE = m.RadCapWithoutCure
    USE_CHEMS = m.UseChems
    USE_ALCOHOL = m.UseAlcohol
    MAX_ITEMS_PER_NEED = ClampInt(m.MaxItemsPerNeed, 1, 12)
    USE_EXCLUSIONS = m.UseExclusions
    FOOD_RESERVE = m.FoodReserve
    FOOD_RESERVE_RADS = m.FoodReserveCountRad
    AP_TRIGGER_PCT = m.ApItemsBelowPct as Float
    AP_ITEMS_MODE = m.ApItemsMode
    COLA_RESERVE = m.ColaReserve

    String text = "лечить " + OnOff(ENABLE_HEALTH, "hp") + OnOff(ENABLE_LIMBS, "limbs") + \
        OnOff(LIMBS_IN_PA, "limbsPA") + \
        OnOff(m.EnableRads, "rads") + OnOff(m.EnableHunger, "hunger") + \
        OnOff(m.EnableThirst, "thirst") + OnOff(ENABLE_DISEASE, "disease") + \
        OnOff(ENABLE_ADDICTION, "addiction") + \
        "| hp " + R0(HEAL_TRIGGER_PCT) + "->" + R0(HEAL_TARGET_PCT) + "%, stimpak " + \
        OnOff(ALLOW_STIMPAK, "") + "резерв " + RESERVE_STIMPAKS + \
        " | голод " + hunger + ", жажда " + thirst + ", до " + MAX_ITEMS_PER_NEED + \
        " шт., риск <= " + MAX_DISEASE_RISK_PCT + "%, запас еды " + FOOD_RESERVE + \
        " (облуч. " + OnOff(FOOD_RESERVE_RADS, "") + ")" + \
        " | rads " + m.RadTriggerPct + "->" + m.RadTargetPct + "%, radaway " + \
        OnOff(ALLOW_RADAWAY, "") + "резерв " + RESERVE_RADAWAY + ", набор <= " + \
        R0(MAX_INGESTED_RADS) + ", без вывода " + OnOff(RAD_CAP_WITHOUT_CURE, "cap") + \
        "| цена <= " + R0(MAX_ITEM_VALUE) + ", химия " + OnOff(USE_CHEMS, "") + \
        "алкоголь " + OnOff(USE_ALCOHOL, "") + "ОД-напитки " + ApModeName(AP_ITEMS_MODE) + \
        " при ОД < " + R0(AP_TRIGGER_PCT) + \
        "%, запас колы " + COLA_RESERVE + ", исключения " + OnOff(USE_EXCLUSIONS, "") + \
        "(" + AM_Excluded.Length + ") | сводка " + NOTIFY_LEVEL + \
        ", лог " + LOG_LEVEL + " -> " + LogTargetName() + ", план без приёма " + OnOff(DRY_RUN, "") +         " | авто " + OnOff(m.AutoMode, "") + "hp " + m.AutoHealTriggerPct + "->" + m.AutoHealTargetPct +         "%, rads " + m.AutoRadTriggerPct + "->" + m.AutoRadTargetPct + "%, бой " + OnOff(m.AutoInCombat, "") +         "прочее " + OnOff(m.AutoOther, "") + "опрос " + m.AutoPollSec + " с, повтор " + m.AutoRetrySec + " с"
    If text != AM_SettingsText
        AM_SettingsText = text
        LogAt(LOG_SUMMARY, "SETTINGS " + text)
    EndIf
EndFunction

String Function LogTargetName()
    If LOG_TARGET == LOG_TO_FILE
        If L_Append
            Return "файл (дописывание)"
        EndIf
        Return "файл (перезапись)"
    ElseIf LOG_TARGET == LOG_TO_PAPYRUS
        Return "Papyrus"
    ElseIf LOG_TARGET == LOG_TO_BOTH
        Return "файл + Papyrus"
    EndIf
    Return "никуда"
EndFunction

Int Function ClampInt(Int aiValue, Int aiMin, Int aiMax)
    If aiValue < aiMin
        Return aiMin
    ElseIf aiValue > aiMax
        Return aiMax
    EndIf
    Return aiValue
EndFunction

; "hp+ " / "hp- "; без имени — "on " / "off ".
String Function OnOff(Bool abOn, String asName)
    If asName == ""
        If abOn
            Return "on "
        EndIf
        Return "off "
    EndIf
    If abOn
        Return asName + "+ "
    EndIf
    Return asName + "- "
EndFunction

; Кнопка MCM «Записать снимок состояния» (§6.4): план без приёма, лог не ниже
; Detailed. НЕ ПЕРЕИМЕНОВЫВАТЬ: вызывается из config.json по имени.
Function McmSnapshot()
    ; Уровень лога поднимает RunCycle (trigger "snapshot").
    Var[] args = new Var[3]
    args[0] = "snapshot"
    args[1] = true
    args[2] = MODE_ITEM
    CallFunctionNoWait("RunCycle", args)
    Debug.Notification("AutoMedic: snapshot -> AutoMedic.log")
EndFunction

; Кнопка MCM «Выдать предмет AutoMedic». НЕ ПЕРЕИМЕНОВЫВАТЬ.
Function McmGiveTool()
    PlayerRef().AddItem(AM_Tool, 1, false)
    AM_ToolGiven = true
    Log("Предмет AutoMedic выдан из MCM")
    FlushLog()
EndFunction

; Кнопка MCM «Перечитать файлы исключений». НЕ ПЕРЕИМЕНОВЫВАТЬ.
Function McmReloadExclusions()
    LoadExclusions()
    FlushLog()
    Debug.Notification("AutoMedic: " + AM_Excluded.Length + " excluded / исключено")
EndFunction

; =====================================================================
;  Профилактика: травяные снадобья и Рад-Х (2026-09-22)
; =====================================================================

; Снадобья должны действовать В МОМЕНТ броска болезни (docs/verified.md, M13):
; бросок — при каждом засыпании и через ~2 игровые минуты после рискового
; события. OnPlayerSleepStart гоняется с обработчиком HC_Manager (A20) —
; поэтому не он. OnSit на кровати в игре НЕ пришёл ни разу (лог 2026-09-24:
; сон прошёл, строки «перед сном» нет). Надёжный момент — открытие меню сна:
; игрок уже лежит, до засыпания ещё выбор часов. Меню то же и для ожидания на
; стуле — кровать отличает CurrentFurnitureHasKeyword (GOEPE).
Event OnMenuOpenCloseEvent(String asMenuName, Bool abOpening)
    If !abOpening || asMenuName != "SleepWaitMenu"
        Return
    EndIf
    ; Меню сна открывается ДО того, как игрок ложится: занятая мебель в этот
    ; момент не кровать (прогон 2026-09-24 12:42: «кровать False» перед сном).
    ; Кровать — это то, что только что активировали (объект в прицеле).
    Actor player = PlayerRef()
    ObjectReference target = GardenOfEden2.GetLastActivateTargetRef()
    Bool inBed = KW_SleepFurniture != None && GardenOfEden3.CurrentFurnitureHasKeyword(player, KW_SleepFurniture)
    Bool atBed = KW_SleepFurniture != None && target != None && target.HasKeyword(KW_SleepFurniture)
    Bool bed = inBed || atBed
    LogAt(LOG_TRACE, "[" + GardenOfEden2.GetCurrentDateAndTimeAsString() + "] меню сна/ожидания: кровать " + bed + \
        " (занятая мебель " + inBed + ", активирован " + target + " " + atBed + ", сидит " + player.GetSitState() + ")")
    If bed && AM_Settings.HerbalsBeforeSleep
        TopUpHerbals("перед сном")
    Else
        FlushLog()
    EndIf
EndEvent

; Только для лога: приходит ли OnSit вообще (на кровать — не пришёл).
Event Actor.OnSit(Actor akSender, ObjectReference akFurniture)
    Bool bed = akFurniture != None && KW_SleepFurniture != None && akFurniture.HasKeyword(KW_SleepFurniture)
    LogAt(LOG_TRACE, "[" + GardenOfEden2.GetCurrentDateAndTimeAsString() + "] OnSit " + akFurniture + ", кровать " + bed)
EndEvent

; HC_Manager узнаёт о съеденном тем же событием. Ловится и приём самим модом.
Event Actor.OnItemEquipped(Actor akSender, Form akBaseObject, ObjectReference akReference)
    Potion p = akBaseObject as Potion
    If p == None || HB_Items == None || HB_Items.Find(p) >= 0
        Return
    EndIf
    Int row = IndexOfFullIdL(p.GetFormID())
    If row < 0
        Return
    EndIf
    Int risk = ItemDataL(row).DiseaseRiskPct
    If risk <= 0 || !AM_Settings.HerbalsAfterRisk
        Return
    EndIf
    HB_Reason = "после " + p + " (риск " + risk + "%)"
    StartTimer(HERBAL_DELAY, TIMER_HERBAL)
EndEvent

; Выпить снадобья, чей эффект сейчас не действует. Только в Survival и если
; болезни включены в MCM; «Только план» — записать, не пить.
Function TopUpHerbals(String asWhy)
    If GV_SurvivalSustenance == None || GV_SurvivalSustenance.GetValue() != 1.0 || HB_Items == None
        Return
    EndIf
    AutoMedicSettings m = AM_Settings
    If !m.EnableDisease
        Return
    EndIf
    Actor player = PlayerRef()
    If player.IsDead()
        Return
    EndIf
    String took = ""
    String missing = ""
    Int i = 0
    While i < HB_Items.Length
        If HB_Items[i] != None && ME_Herbal[i] != None && !player.HasMagicEffect(ME_Herbal[i])
            If player.GetItemCount(HB_Items[i]) <= 0
                missing = Join(missing, HerbalNames[i])
            ElseIf m.DryRun
                took = Join(took, HerbalNames[i] + " (только план)")
            Else
                player.EquipItem(HB_Items[i], false, true)
                took = Join(took, HerbalNames[i])
            EndIf
        EndIf
        i += 1
    EndWhile
    ; Нечего пить и нечем — не повод писать на каждый кусок сырого мяса.
    Int level = LOG_TRACE
    If took != ""
        level = LOG_SUMMARY
    EndIf
    If took != "" || missing != ""
        String line = "HERBALS " + asWhy + ": выпито [" + took + "]"
        If missing != ""
            line += ", нет в инвентаре [" + missing + "]"
        EndIf
        LogAt(level, "[" + GardenOfEden2.GetCurrentDateAndTimeAsString() + "] " + line)
        If took != "" && NOTIFY_LEVEL > 0
            Debug.Notification("AutoMedic: " + took)
        EndIf
        FlushLog()
    EndIf
EndFunction

; M12: Рад-Х — профилактика по СКОРОСТИ набора. Скорость должна держаться
; не ниже MCM RadXRatePerSec не меньше RadXSeconds секунд подряд (опрос раз
; в RADX_POLL с): разовая облучённая еда (+15 rad за раз) даёт одну «горячую»
; секунду и не считается. Пока идёт цикл мода (AM_Busy), скорость не
; оценивается — он сам ест облучённое; в меню время не идёт — счёт с нуля.
Function RadXPoll()
    AutoMedicSettings m = AM_Settings
    If !m.UseRadX || !m.EnableRads || RX_Item == None
        RX_LastTime = 0.0
        StartTimer(RADX_OFF_POLL, TIMER_RADX)
        Return
    EndIf
    StartTimer(RADX_POLL, TIMER_RADX)
    Actor player = PlayerRef()
    Float now = Utility.GetCurrentRealTime()
    Float rads = player.GetValue(AV_Rads)
    Float dt = now - RX_LastTime
    Float was = RX_LastRads
    Bool fresh = RX_LastTime <= 0.0 || dt <= 0.0 || dt > RADX_OFF_POLL
    RX_LastTime = now
    RX_LastRads = rads
    If fresh || BusyAlive() || Utility.IsInMenuMode()
        RX_HotSec = 0.0
        Return
    EndIf
    Float rate = (rads - was) / dt
    If rate < m.RadXRatePerSec
        RX_HotSec = 0.0
        Return
    EndIf
    RX_HotSec += dt
    ; Допуск 0.1 с: таймер может прийти чуть раньше, и 8 интервалов по ~1 с
    ; иначе иногда давали 7.98 с.
    If RX_HotSec < (m.RadXSeconds as Float) - 0.1
        Return
    EndIf
    Float held = RX_HotSec
    RX_HotSec = 0.0
    If player.IsDead() || (ME_RadX != None && player.HasMagicEffect(ME_RadX))
        Return
    EndIf
    String line = "RADX скорость " + R1(rate) + " rad/с " + R1(held) + " с (порог " + R1(m.RadXRatePerSec) + \
        " rad/с " + m.RadXSeconds + " с), rads " + R0(rads)
    Int have = player.GetItemCount(RX_Item)
    If have <= 0
        LogAt(LOG_TRACE, "[" + GardenOfEden2.GetCurrentDateAndTimeAsString() + "] " + line + " — Рад-Х нет")
        Return
    EndIf
    If m.DryRun
        line += " — выпил бы Рад-Х (только план)"
    Else
        player.EquipItem(RX_Item, false, true)
        line += " — выпит Рад-Х, осталось " + (have - 1)
        If NOTIFY_LEVEL > 0
            Debug.Notification("AutoMedic: Rad-X")
        EndIf
    EndIf
    LogAt(LOG_SUMMARY, "[" + GardenOfEden2.GetCurrentDateAndTimeAsString() + "] " + line)
    FlushLog()
EndFunction

; =====================================================================
;  Шаг 9: автоматический режим (§4.7)
; =====================================================================

; Опрос. Таймер перезапускается ПЕРВЫМ делом: ошибка ниже не должна рвать цепочку.
Event OnTimer(Int aiTimerID)
    If aiTimerID == TIMER_RADX
        RadXPoll()
        Return
    ElseIf aiTimerID == TIMER_HERBAL
        TopUpHerbals(HB_Reason)
        Return
    ElseIf aiTimerID != TIMER_AUTO
        Return
    EndIf
    AutoMedicSettings m = AM_Settings
    If !m.AutoMode
        StartTimer(AUTO_OFF_POLL, TIMER_AUTO)
        AutoSkip("авторежим выкл.")
        Return
    EndIf
    StartTimer(ClampInt(m.AutoPollSec, 1, 30) as Float, TIMER_AUTO)
    AutoPoll(m)
EndEvent

; Почему опрос авторежима не запустил цикл — в лог одной строкой, только при
; смене причины (запуск цикла причину не сбрасывает). Иначе молчаливый выход не отличить от
; остановившегося таймера (авторежим встал 2026-09-23 01:54 без следа в логе).
Function AutoSkip(String asWhy)
    If asWhy == AU_SkipWhy
        Return
    EndIf
    AU_SkipWhy = asWhy
    If asWhy != ""
        ; Сразу в файл: причина меняется редко, а отложенная строка при
        ; «застрявшей» причине не ушла бы в файл никогда.
        LogAt(LOG_TRACE, "[" + GardenOfEden2.GetCurrentDateAndTimeAsString() + "] авто-опрос: пропуск — " + asWhy)
        FlushLog()
    EndIf
EndFunction

; Дешёвая проверка: несколько GetValue и ни одного обращения к инвентарю.
; Сработал порог — полный цикл (он и решает, что именно принять, с учётом
; «в полёте»). Пороги здесь — те же, что применит ApplyAutoMode.
Function AutoPoll(AutoMedicSettings m)
    ; «Только план» — автоматике показывать некому, а цикл повторялся бы вечно.
    ; BusyAlive, а не AM_Busy: брошенный цикл (флаг остался в сейве) иначе
    ; навсегда глушил авторежим — снимал его только ручной приём (TryBusy).
    If BusyAlive()
        AutoSkip("идёт цикл")
        Return
    ElseIf m.DryRun
        AutoSkip("план без приёма")
        Return
    ElseIf Utility.IsInMenuMode()
        ; Без AutoSkip: каждое открытие Pip-Boy — две строки и две перезаписи лога.
        Return
    EndIf
    Float now = Utility.GetCurrentRealTime()
    If now < AU_LastEnd
        AU_LastEnd = 0.0
        AU_LastStatus = 0.0
        AU_RetryAt = 0.0
    EndIf
    If now - AU_LastEnd < AUTO_MIN_GAP
        Return
    EndIf
    Actor player = PlayerRef()
    If player.IsDead()
        AutoSkip("мёртв")
        Return
    ElseIf player.IsBleedingOut()
        AutoSkip("истекает кровью")
        Return
    EndIf
    Bool combat = player.IsInCombat()
    If combat && !m.AutoInCombat
        AutoSkip("бой (авто в бою выкл.)")
        Return
    EndIf
    ; Сцена — ради диалога: не есть посреди разговора. Но сцена с игроком
    ; может «застрять» и уехать в сейв — тогда IsInScene навсегда глушил
    ; авторежим (2026-09-23 01:54 .. 09-24, Nuka-World). Поэтому в бою сцена
    ; не мешает, а вне боя ждём её конца не дольше AUTO_SCENE_WAIT.
    If player.IsInScene()
        If AU_SceneSince <= 0.0 || now < AU_SceneSince
            AU_SceneSince = now
        EndIf
        If !combat && now - AU_SceneSince < AUTO_SCENE_WAIT
            AutoSkip("в сцене")
            Return
        EndIf
    Else
        AU_SceneSince = 0.0
    EndIf

    Float pct = player.GetValuePercentage(AV_Health) * 100.0
    Float rads = player.GetValue(AV_Rads)
    ; В бою — всё то же, что и вне боя (решение пользователя 2026-09-22).
    Bool radsOn = m.EnableRads
    Float radTrigger = RADS_MAX * m.AutoRadTriggerPct / 100.0
    ; Порог ОЗ — от максимума после вывода радиации, как в BuildNeeds.
    Float radsAfter = rads
    If radsOn && rads >= radTrigger
        radsAfter = RADS_MAX * m.AutoRadTargetPct / 100.0
        If radsAfter > rads
            radsAfter = rads
        EndIf
    EndIf
    Float pctEff = pct
    If radsAfter < RADS_MAX
        pctEff = pct / (1.0 - radsAfter / RADS_MAX)
    EndIf

    String why = ""
    Int bits = 0
    If m.EnableHealth && pctEff <= m.AutoHealTriggerPct
        why = Join(why, "hp " + R0(pctEff) + "%")
        bits = WithBit(bits, USE_HP)
    EndIf
    Float hunger = 0.0
    Float thirst = 0.0
    Int crippled = 0
    If radsOn && rads >= radTrigger
        why = Join(why, "rads " + R0(rads))
        bits = WithBit(bits, USE_RADS)
    EndIf
    If m.AutoOther
        hunger = player.GetValue(AV_Hunger)
        thirst = player.GetValue(AV_Thirst)
        If m.EnableHunger && hunger >= m.HungerFrom + 1
            why = Join(why, "hunger " + R0(hunger))
            bits = WithBit(bits, USE_HUNGER)
        EndIf
        If m.EnableThirst && thirst >= m.ThirstFrom + 1
            why = Join(why, "thirst " + R0(thirst))
            bits = WithBit(bits, USE_THIRST)
        EndIf
        If m.EnableLimbs && (m.LimbsInPowerArmor || !player.IsInPowerArmor())
            Int i = 0
            While i < AV_Limbs.Length
                If player.GetValue(AV_Limbs[i]) <= 0.0
                    crippled += 1
                EndIf
                i += 1
            EndWhile
            If crippled > 0
                why = Join(why, "limbs " + crippled)
                bits = WithBit(bits, USE_LIMBS)
            EndIf
        EndIf
        If (m.EnableDisease || m.EnableAddiction) && now - AU_LastStatus >= AUTO_STATUS_SEC
            AU_LastStatus = now
            why = Join(why, "status")
        EndIf
    EndIf
    ; Незакрытая нужда без сработавшего порога (болезнь без лекарства, пауза
    ; прошла): появилось средство — не ждать проверки болезней раз в 30 с.
    Bool gotNew = false
    If why == "" && NewItems()
        why = "новое: " + AU_NewWhat
        gotNew = true
    EndIf
    If why == ""
        AutoSkip("пороги не достигнуты")
        Return
    EndIf
    ; Прошлый авто-цикл ничего не принял — ждём AutoRetrySec, если не стало хуже.
    If now < AU_RetryAt
        Bool worse = NewBits(bits, AU_IdleBits) || combat != AU_IdleCombat || pct <= AU_IdleHPPct - AUTO_WORSE_HP_PCT || \
            rads >= AU_IdleRads + AUTO_WORSE_RADS || crippled > AU_IdleCrippled
        If m.AutoOther
            worse = worse || hunger > AU_IdleHunger || thirst > AU_IdleThirst
        EndIf
        If worse
            why += " (хуже)"
        ElseIf gotNew
            ; уже в why
        ElseIf NewItems()
            why += " (новое: " + AU_NewWhat + ")"
        Else
            AutoSkip("пауза повтора после пустого цикла")
            Return
        EndIf
    EndIf
    ; Причина после цикла НЕ сбрасывается: иначе проверка болезней раз в 30 с
    ; каждый раз заново писала бы «пороги не достигнуты» (и переписывала файл).

    Var[] args = new Var[3]
    Int mode = MODE_AUTO
    If combat
        mode = MODE_COMBAT
        args[0] = "auto, бой: " + why
    Else
        args[0] = "auto: " + why
    EndIf
    If AU_SceneSince > 0.0
        args[0] = args[0] as String + " (в сцене " + R0(now - AU_SceneSince) + " с)"
    EndIf
    args[1] = false
    args[2] = mode
    ; Отметка сразу: следующий тик не должен запустить второй цикл, пока
    ; этот ещё не занял AM_Busy.
    AU_LastEnd = now
    AU_PendingBits = bits
    CallFunctionNoWait("RunCycle", args)
EndFunction

; Есть ли в aiBits бит, которого нет в aiOld.
Bool Function NewBits(Int aiBits, Int aiOld)
    Int mask = 1
    While mask <= USE_LIMBS
        If Has(aiBits, mask) && !Has(aiOld, mask)
            Return true
        EndIf
        mask *= 2
    EndWhile
    Return false
EndFunction

; Пороги и нужды авто-цикла поверх уже прочитанных LoadSettings (ручных).
; В бою — всё то же, что и вне боя (решение пользователя 2026-09-22;
; прежнее «в бою только ОЗ» из §4.7 отменено). abCombat — только для лога.
Function ApplyAutoMode(Bool abCombat)
    AutoMedicSettings m = AM_Settings
    HEAL_TRIGGER_PCT = m.AutoHealTriggerPct as Float
    HEAL_TARGET_PCT = m.AutoHealTargetPct as Float
    If HEAL_TARGET_PCT < HEAL_TRIGGER_PCT
        HEAL_TARGET_PCT = HEAL_TRIGGER_PCT
    EndIf
    String rads = "rads-"
    If m.EnableRads
        RAD_TRIGGER_PCT = m.AutoRadTriggerPct as Float
        RAD_TARGET_PCT = m.AutoRadTargetPct as Float
        If RAD_TARGET_PCT > RAD_TRIGGER_PCT
            RAD_TARGET_PCT = RAD_TRIGGER_PCT
        EndIf
        rads = "rads " + R0(RAD_TRIGGER_PCT) + "->" + R0(RAD_TARGET_PCT) + "%"
    Else
        RAD_TRIGGER_PCT = RAD_PCT_NEVER
    EndIf
    String rest = "прочее+"
    If !m.AutoOther
        HUNGER_TRIGGER = STAGE_NEVER
        THIRST_TRIGGER = STAGE_NEVER
        ENABLE_LIMBS = false
        ENABLE_DISEASE = false
        ENABLE_ADDICTION = false
        rest = "прочее-"
    EndIf
    String mode = "авто"
    If abCombat
        mode = "авто в бою"
    EndIf
    AU_Text = mode + ": hp " + R0(HEAL_TRIGGER_PCT) + "->" + R0(HEAL_TARGET_PCT) + "%, " + rads + ", " + rest
EndFunction

; Конец авто-цикла. Ничего не принято — следующая попытка не раньше
; AutoRetrySec, если состояние не ухудшится (AutoPoll). Запоминается
; состояние ДО цикла: с ним и сравнивается.
Function AutoFinish(Bool abTook)
    Float now = Utility.GetCurrentRealTime()
    AU_LastEnd = now
    If abTook
        AU_RetryAt = 0.0
        AU_IdleValid = false
        Return
    EndIf
    Int retry = AM_Settings.AutoRetrySec
    AU_RetryAt = now + retry
    RecordIdle(now)
    AU_IdleHPPct = S_HPPct * 100.0
    AU_IdleRads = S_Rads
    AU_IdleHunger = S_Hunger
    AU_IdleThirst = S_Thirst
    AU_IdleCrippled = S_CrippledCount
    AU_IdleCombat = AU_Mode == MODE_COMBAT
    AU_IdleBits = AU_PendingBits
    If N_Uses != 0
        LogAt(LOG_SUMMARY, "  AUTO   принять нечего - повтор через " + retry + " с или раньше, если станет хуже")
    EndIf
EndFunction

; Незакрытые нужды цикла (биты USE_*) — без вспомогательных битов BuildNeeds
; (еда под запас, питьё после стимпака и т. п.).
Int Function PrimaryBits()
    Int bits = 0
    If N_HP > 0.0
        bits = WithBit(bits, USE_HP)
    EndIf
    If N_Rads > 0.0
        bits = WithBit(bits, USE_RADS)
    EndIf
    If N_Hunger > 0.0
        bits = WithBit(bits, USE_HUNGER)
    EndIf
    If N_Thirst > 0.0
        bits = WithBit(bits, USE_THIRST)
    EndIf
    If N_Disease > 0
        bits = WithBit(bits, USE_DISEASE)
    EndIf
    If N_Addiction > 0
        bits = WithBit(bits, USE_ADDICTION)
    EndIf
    If N_Limbs > 0
        bits = WithBit(bits, USE_LIMBS)
    EndIf
    Return bits
EndFunction

; Все биты aiA есть в aiB.
Bool Function SubsetBits(Int aiA, Int aiB)
    Return !NewBits(aiA, aiB)
EndFunction

; Сколько у игрока предметов из списка нужды aiBit (индекс бита 0..7); -1 — списка нет.
Int Function ListCount(Int aiBit)
    If NL_Lists == None || NL_Lists[aiBit] == None
        Return -1
    EndIf
    Return PlayerRef().GetItemCount(NL_Lists[aiBit])
EndFunction

String Function BitName(Int aiBit)
    If aiBit == 0
        Return "hp"
    ElseIf aiBit == 1
        Return "rads"
    ElseIf aiBit == 2
        Return "hunger"
    ElseIf aiBit == 3
        Return "thirst"
    ElseIf aiBit == 4
        Return "disease"
    ElseIf aiBit == 5
        Return "addiction"
    ElseIf aiBit == 7
        Return "limbs"
    EndIf
    Return "?"
EndFunction

; После «нечего принять»: запомнить незакрытые нужды и счёт средств под каждую.
; Заодно проверка, что GetItemCount(FormList) действительно считает список:
; кандидаты под нужду в инвентаре есть (C_*Count), а счёт 0 — не считает.
Function RecordIdle(Float afNow)
    AU_IdleValid = false
    If N_Uses == 0 || !AU_ListsOK
        Return
    EndIf
    AU_IdleNeedBits = PrimaryBits()
    AU_IdleCnt = new Int[8]
    AU_IdleDisease = S_DiseaseCount
    AU_IdleAddiction = S_AddictionCount
    AU_IdleSettings = AM_SettingsText
    AU_IdleSince = afNow
    String text = ""
    Int b = 0
    Int mask = 1
    While b < 8
        AU_IdleCnt[b] = -1
        If Has(AU_IdleNeedBits, mask)
            AU_IdleCnt[b] = ListCount(b)
            text = Join(text, BitName(b) + " " + AU_IdleCnt[b])
            Int have = 0
            If mask == USE_HP
                have = C_HPCount
            ElseIf mask == USE_RADS
                have = C_RadsCount
            ElseIf mask == USE_HUNGER
                have = C_HungerCount
            ElseIf mask == USE_THIRST
                have = C_ThirstCount
            ElseIf mask == USE_LIMBS
                have = C_LimbsCount
            EndIf
            If have > 0 && AU_IdleCnt[b] <= 0
                AU_ListsOK = false
                LogAt(LOG_SUMMARY, "  AUTO   ВНИМАНИЕ: GetItemCount(список " + BitName(b) + ") = " + AU_IdleCnt[b] + \
                    ", а кандидатов " + have + " — счёт по спискам выключен до загрузки")
                Return
            EndIf
        EndIf
        b += 1
        mask *= 2
    EndWhile
    AU_IdleValid = true
    LogAt(LOG_DETAILED, "  AUTO   жду новых средств (штук в инвентаре): " + text)
EndFunction

; Прибавились ли средства хоть под одну незакрытую нужду -> AU_NewWhat.
Bool Function NewItems()
    AU_NewWhat = ""
    If !AU_IdleValid || !AU_ListsOK
        Return false
    EndIf
    Int b = 0
    Int mask = 1
    While b < 8
        If Has(AU_IdleNeedBits, mask) && AU_IdleCnt[b] >= 0
            Int now = ListCount(b)
            If now > AU_IdleCnt[b]
                AU_NewWhat = Join(AU_NewWhat, BitName(b) + " " + AU_IdleCnt[b] + "->" + now)
            EndIf
        EndIf
        b += 1
        mask *= 2
    EndWhile
    Return AU_NewWhat != ""
EndFunction

; Проверка болезней раз в 30 с (без других порогов): то же «нечего принять»?
; Нужды — не шире прежних, болезней и зависимостей не больше, настройки те же,
; средств не прибавилось, страховка AUTO_IDLE_MAX не истекла.
Bool Function SameIdle(Float afNow)
    If !AU_IdleValid || !AU_ListsOK || AU_PendingBits != 0
        Return false
    EndIf
    If afNow < AU_IdleSince || afNow - AU_IdleSince >= AUTO_IDLE_MAX
        Return false
    EndIf
    If !SubsetBits(PrimaryBits(), AU_IdleNeedBits)
        Return false
    EndIf
    If S_DiseaseCount > AU_IdleDisease || S_AddictionCount > AU_IdleAddiction
        Return false
    EndIf
    If AM_SettingsText != AU_IdleSettings
        Return false
    EndIf
    Return !NewItems()
EndFunction

; =====================================================================
;  Шаг 7: файлы исключений
; =====================================================================

; exclusions-default.json идёт с модом (обновление его перезаписывает),
; exclusions-user.json — необязательный, игрока. Формат — как у LootMan:
; JSON, в котором значимы только строки с "Плагин.esm|ЛокальныйHexID".
; Разбор построчный, одна запись на строку: строки с _comment и без «|»
; пропускаются, у остальных срезаются кавычки, запятые и пробелы, и остаток
; «Плагин|ID» делится по «|». Плагина нет в сборке (DLC) — запись молча
; пропускается.
;
; ВНИМАНИЕ: GardenOfEden.StrFind возвращает ЧИСЛО ВХОЖДЕНИЙ, а не позицию
; (документация GOEPE: «returns the occurrence count»). Первая версия считала
; его позицией и не разобрала ни одной записи (прогон 2026-09-22 01:32:
; «добавлено 0, нет плагина 21»). Здесь StrFind — только «есть / нет».
Function LoadExclusions()
    AM_Excluded = new Form[0]
    String a = ReadExclusionFile("exclusions-default.json")
    String b = ReadExclusionFile("exclusions-user.json")
    Log("Исключения: " + AM_Excluded.Length + " форм (default: " + a + "; user: " + b + ")")
EndFunction

; Добавляет формы файла в AM_Excluded; возвращает сводку для лога.
String Function ReadExclusionFile(String asName)
    If !GardenOfEden2.DoesFileExist(asName, MOD_DATA_PATH)
        Return "нет файла"
    EndIf
    String[] lines = GardenOfEden2.GetLinesFromFile(asName, MOD_DATA_PATH)
    Int added = 0
    Int missing = 0
    Int broken = 0
    Int i = 0
    While i < lines.Length
        String line = lines[i]
        If GardenOfEden.StrFind(line, "|") > 0 && GardenOfEden.StrFind(line, "_comment") == 0
            String token = RemoveAll(RemoveAll(RemoveAll(RemoveAll(line, "\""), ","), " "), "\t")
            String[] parts = GardenOfEden2.GetCommaDelimitedStringAsArray(RemoveAll(token, "|", ","))
            Int id = 0
            String plugin = ""
            If parts != None && parts.Length == 2
                plugin = parts[0]
                id = GardenOfEden2.HexFormIDToInt(parts[1])
            EndIf
            If id <= 0 || plugin == ""
                broken += 1
                Log("  исключения " + asName + ": не разобрана строка " + (i + 1) + ": " + token)
            Else
                Form f = Game.GetFormFromFile(id, plugin)
                If f == None
                    missing += 1
                ElseIf AM_Excluded.Find(f) < 0
                    If AM_Excluded.Length < 128
                        AM_Excluded.Add(f)
                        added += 1
                    Else
                        broken += 1
                        Log("  исключения: больше 128 форм, " + token + " пропущен")
                    EndIf
                EndIf
            EndIf
        EndIf
        i += 1
    EndWhile
    Return lines.Length + " строк, добавлено " + added + ", нет плагина " + missing + ", ошибок " + broken
EndFunction

; Заменить ВСЕ вхождения asWhat. Документация ReplaceStr не говорит, все ли
; вхождения она меняет, поэтому повторяем, пока StrFind (число вхождений) > 0.
String Function RemoveAll(String asText, String asWhat, String asWith = "")
    Int guard = 0
    While GardenOfEden.StrFind(asText, asWhat) > 0 && guard < 64
        asText = GardenOfEden.ReplaceStr(asText, asWhat, asWith)
        guard += 1
    EndWhile
    Return asText
EndFunction

; Занять мод. Цикл, который висит дольше BUSY_TIMEOUT, считается брошенным
; (стек потерян при обновлении скрипта), и его место можно занять. Реальное
; время в новой сессии игры начинается с нуля — это тоже «брошенный».
; Идёт ли цикл на самом деле: AM_Busy, не ставший брошенным.
Bool Function BusyAlive()
    Float now = Utility.GetCurrentRealTime()
    Return AM_Busy && now >= AM_BusyStart && now - AM_BusyStart < BUSY_TIMEOUT
EndFunction

Bool Function TryBusy(Bool abLoud = true)
    Float now = Utility.GetCurrentRealTime()
    If BusyAlive()
        If abLoud
            Debug.Notification("AutoMedic: предыдущий цикл ещё не закончен")
        EndIf
        Return false
    EndIf
    If AM_Busy
        Log("  (предыдущий цикл брошен " + R0(now - AM_BusyStart) + " с назад — занимаю)")
    EndIf
    AM_Busy = true
    AM_BusyStart = now
    Return true
EndFunction

; НЕ ПЕРЕИМЕНОВЫВАТЬ: вызывается по имени через CallFunctionNoWait.
;
; Здесь НЕ должно быть прохода по всей таблице. На приёмке шага 2 такой проход
; (352 итерации, `FormList.GetAt` + `Actor.GetItemCount` на каждой) занял от 18
; до 82 секунд и выстроил нажатия в очередь. Инвентарь перечисляется через
; GOEPE: один вызов отдаёт индексы только ALCH, дальше — только по ним (§4.1).
; aiMode — MODE_ITEM (нажатие, кнопка снимка), MODE_AUTO, MODE_COMBAT (шаг 9).
Function RunCycle(String asTrigger, Bool abDryRun, Int aiMode)
    If !TryBusy(aiMode == MODE_ITEM)
        Return
    EndIf
    ; Начало и конец каждого цикла — в лог, и пустых авто-циклов тоже (разбор
    ; фризов авторежима, 2026-09-22): их время сверяется с моментами сохранений.
    String startStamp = GardenOfEden2.GetCurrentDateAndTimeAsString()
    Float tStart = Utility.GetCurrentRealTime()
    LoadSettings()
    Float tSettings = Utility.GetCurrentRealTime()
    AU_Mode = aiMode
    If AU_Mode != MODE_ITEM
        ApplyAutoMode(AU_Mode == MODE_COMBAT)
        HoldLog()
    ElseIf asTrigger == "snapshot" && LOG_LEVEL < LOG_DETAILED
        LOG_LEVEL = LOG_DETAILED
    EndIf
    AM_Cycle += 1
    E_DryRun = abDryRun || DRY_RUN
    Int token = AM_WatchToken
    ; Заголовок — первым: снимок EFFECT ниже иначе читается как хвост
    ; предыдущего цикла (так и случилось при разборе шага 3).
    LogHeader(asTrigger)

    Actor player = PlayerRef()
    Float t0 = Utility.GetCurrentRealTime()
    ReadValues(player)
    Float t1 = Utility.GetCurrentRealTime()
    ReadPerks(player)
    Float t2 = Utility.GetCurrentRealTime()
    ReadActiveEffects(player)
    Float t3 = Utility.GetCurrentRealTime()
    BuildNeeds()
    If AU_Mode != MODE_ITEM && N_Uses != 0 && SameIdle(tStart)
        ; Проверка болезней, а всё то же «нечего принять» — в инвентарь не идём.
        ; Пауза и запомненное состояние остаются как были.
        DropLog()
        AM_Cycle -= 1
        AU_LastEnd = Utility.GetCurrentRealTime()
        AM_Busy = false
        LogAt(LOG_SUMMARY, "[" + startStamp + "] проверка пропущена (" + asTrigger + "): нужды те же, новых средств нет, " + \
            Ms(tStart, Utility.GetCurrentRealTime()) + " (эффекты " + Ms(t2, t3) + ")")
        FlushLogThrottled()
        Return
    EndIf
    If AU_Mode != MODE_ITEM
        If N_Uses == 0
            ; Лечить нечего (или всё уже «в полёте») — цикла как бы не было:
            ; вместо отчёта одна строка со временем.
            DropLog()
            AM_Cycle -= 1
            AutoFinish(false)
            AM_Busy = false
            Float tEnd = Utility.GetCurrentRealTime()
            LogAt(LOG_SUMMARY, "[" + startStamp + " -> " + GardenOfEden2.GetCurrentDateAndTimeAsString() + \
                "] пустой авто-цикл (" + asTrigger + "): " + Ms(tStart, tEnd) + " = настройки " + \
                Ms(tStart, tSettings) + ", AV " + Ms(t0, t1) + ", перки " + Ms(t1, t2) + PerkCacheNote() + \
                ", эффекты " + Ms(t2, t3) + " (" + S_EffectsTotal + "), нужды " + Ms(t3, tEnd))
            FlushLogThrottled()
            Return
        EndIf
        ReleaseLog()
        LogAt(LOG_DETAILED, "  MODE   " + AU_Text)
    EndIf
    CollectCandidates(player, 0)
    Float t4 = Utility.GetCurrentRealTime()
    EvalCandidates()
    Plan()
    InitExecution()
    Float t5 = Utility.GetCurrentRealTime()
    ; Всё ниже — только отчёт и сверка; в «стоимость цикла» не входит.
    If LOG_LEVEL >= LOG_TRACE && VERIFY_STATUS
        VerifyStatus(player)
    EndIf
    Float t6 = Utility.GetCurrentRealTime()
    WriteReport(player)
    Float t7 = Utility.GetCurrentRealTime()
    If !E_DryRun
        Execute(player)
    EndIf
    Float t8 = Utility.GetCurrentRealTime()
    WriteOutcome(player)
    LogAt(LOG_TRACE, "  TIME   AV " + Ms(t0, t1) + ", перки " + Ms(t1, t2) + PerkCacheNote() + \
        ", GetActiveEffects " + Ms(t2, t3) + ", инвентарь " + Ms(t3, t4) + " (" + C_Total + \
        " ALCH, " + PerItem(t3, t4, C_Total) + " мс/шт), план " + Ms(t4, t5) + \
        " | ЦИКЛ " + Ms(t0, t5) + " | сверка статуса " + Ms(t5, t6) + ", отчёт " + Ms(t6, t7) + \
        " | исполнение " + Ms(t7, t8))
    If AU_Mode != MODE_ITEM
        AutoFinish(SpentText(false) != "")
    EndIf
    LogAt(LOG_SUMMARY, "  END    [" + startStamp + " -> " + GardenOfEden2.GetCurrentDateAndTimeAsString() + \
        "] " + Ms(tStart, Utility.GetCurrentRealTime()) + " = настройки " + Ms(tStart, tSettings) + \
        ", AV " + Ms(t0, t1) + ", перки " + Ms(t1, t2) + PerkCacheNote() + ", эффекты " + Ms(t2, t3) + \
        ", инвентарь " + Ms(t3, t4) + " (" + C_Total + " ALCH, " + C_Path + " список " + Ms(0.0, C_ListSec) + ", кандидатов " + K_Forms.Length + \
        "), план " + Ms(t4, t5) + \
        ", отчёт " + Ms(t6, t7) + ", приём " + Ms(t7, t8))
    Notify()
    AM_Busy = false
    FlushLog()
    If AU_Mode == MODE_ITEM
        Watch(token)
    EndIf
EndFunction

String Function Ms(Float afFrom, Float afTo)
    Return R0((afTo - afFrom) * 1000.0) + " мс"
EndFunction

String Function PerItem(Float afFrom, Float afTo, Int aiCount)
    If aiCount <= 0
        Return "-"
    EndIf
    Return R1((afTo - afFrom) * 1000.0 / aiCount)
EndFunction

String Function PerkCacheNote()
    If S_PerksCached
        Return " (кеш)"
    EndIf
    Return ""
EndFunction

; =====================================================================
;  Фаза 0.1 — Actor Values
; =====================================================================

Function ReadValues(Actor akPlayer)
    S_HP = akPlayer.GetValue(AV_Health)
    S_HPBase = akPlayer.GetBaseValue(AV_Health)
    S_HPPct = akPlayer.GetValuePercentage(AV_Health)
    ; Максимум ОЗ: текущее / доля. Доля считается от ПОЛНОГО максимума, а
    ; текущее упирается в урезанный радиацией (M1, подтверждено на шаге 3).
    If S_HPPct > 0.0
        S_MaxHP = S_HP / S_HPPct
    Else
        S_MaxHP = S_HPBase
    EndIf
    S_Rads = akPlayer.GetValue(AV_Rads)
    S_AP = akPlayer.GetValue(AV_AP)
    S_APPct = akPlayer.GetValuePercentage(AV_AP)
    S_APBase = akPlayer.GetBaseValue(AV_AP)
    S_Hunger = akPlayer.GetValue(AV_Hunger)
    S_Thirst = akPlayer.GetValue(AV_Thirst)
    S_Sleep = akPlayer.GetValue(AV_Sleep)
    S_OverEncumbered = akPlayer.IsOverEncumbered()
    S_InCombat = akPlayer.IsInCombat()
    S_InPowerArmor = akPlayer.IsInPowerArmor()
    S_Survival = GV_SurvivalSustenance != None && GV_SurvivalSustenance.GetValue() == 1.0

    S_CrippledCount = 0
    S_Crippled = ""
    Int i = 0
    While i < AV_Limbs.Length
        Float cond = akPlayer.GetValue(AV_Limbs[i])
        If cond <= 0.0
            S_CrippledCount += 1
            S_Crippled = Join(S_Crippled, LimbNames[i] + "=" + R0(cond))
        EndIf
        i += 1
    EndWhile
EndFunction

; =====================================================================
;  Фаза 0.1 — перки
; =====================================================================

Int Function PerkRank(Actor akPlayer, Perk[] akRanks)
    Int i = akRanks.Length
    While i > 0
        i -= 1
        If akRanks[i] != None && akPlayer.HasPerk(akRanks[i])
            Return i + 1
        EndIf
    EndWhile
    Return 0
EndFunction

; Перки перечитываются при смене уровня и не реже раза в PERK_REFRESH_SECONDS:
; 20+ HasPerk стоили 0.36-0.7 с на цикл (по кадру на вызов).
Function ReadPerks(Actor akPlayer)
    Float now = Utility.GetCurrentRealTime()
    Int level = akPlayer.GetLevel()
    S_PerksCached = S_PerksAt > 0.0 && now >= S_PerksAt && now - S_PerksAt < PERK_REFRESH_SECONDS && \
        level == S_PerksLevel
    If S_PerksCached
        Return
    EndIf
    S_PerksAt = now
    S_PerksLevel = level
    PC_Ids = new Int[0]
    PC_Has = new Bool[0]
    S_Medic = PerkRank(akPlayer, PK_Medic)
    S_LeadBelly = PerkRank(akPlayer, PK_LeadBelly)
    S_Adamantium = PerkRank(akPlayer, PK_Adamantium)
    S_ChemResistant = PerkRank(akPlayer, PK_ChemResistant)
    S_PartyBoy = PerkRank(akPlayer, PK_PartyBoy)
    If S_PartyBoy == 0
        S_PartyBoy = PerkRank(akPlayer, PK_PartyGirl)
    EndIf
    S_Aquaboy = PerkRank(akPlayer, PK_Aquaboy)
    If S_Aquaboy == 0
        S_Aquaboy = PerkRank(akPlayer, PK_Aquagirl)
    EndIf
    S_BobbleMedicine = PK_BobbleMedicine != None && akPlayer.HasPerk(PK_BobbleMedicine)
EndFunction

; Есть ли у игрока перк Fallout4.esm по локальному FormID (варианты таблицы).
; Ответ кешируется до следующего чтения перков.
Bool Function HasPerkLocal(Int aiLocalId)
    If aiLocalId == 0
        Return false
    EndIf
    Int i = PC_Ids.Find(aiLocalId)
    If i >= 0
        Return PC_Has[i]
    EndIf
    Perk p = F4(aiLocalId) as Perk
    Bool has = p != None && PlayerRef().HasPerk(p)
    If PC_Ids.Length < 128
        PC_Ids.Add(aiLocalId)
        PC_Has.Add(has)
    EndIf
    Return has
EndFunction

; =====================================================================
;  Фаза 0.2 — снимок GetActiveEffects (§5): «в полёте» и статусы
; =====================================================================

; Остаток эффекта = fMagnitude * (fDuration - fElapsedTime); у мгновенных
; остаток 0 — они уже видны в текущем AV.
;
; Магнитуда в GOEPE — уже итоговая, в абсолютных единицах AV в секунду, в том
; числе у стимпака: 8.5 ОЗ/с x 50 с = 425 = 88 % от 482 при Medic 3 и бобблхеде
; (замер шага 3). Поэтому роль heal_hp_pct «в полёте» складывается в ОЗ.
; Исключение — RadAway: GOEPE отдаёт его магнитуду БЕЗ бобблхеда (шаг 4:
; 16.0 в снимке, 17.5 рад/с на деле), отсюда поправка ×1.1.
;
; Шаг 5: из того же снимка берутся болезни, зависимости, иммунодефицит, Рад-X
; и снадобья — вместо 6 HasMagicEffect + 25 HasSpell (0.63 с на шаге 3).
; Болезни сверены с HasMagicEffect в игре (VerifyStatus: совпало).
; Зависимости HasSpell не видит вовсе — см. комментарий у их разбора ниже.
;
; Постоянные эффекты (fDuration > PERMANENT_DURATION) в «полёт» не идут.
Function ReadActiveEffects(Actor akPlayer)
    S_InHeal = 0.0
    S_InHealPct = 0.0
    S_InRadOut = 0.0
    S_InRadIn = 0.0
    S_InAP = 0.0
    S_InDamage = 0.0
    S_AntiradActive = false
    S_DiseaseCount = 0
    S_Diseases = ""
    S_AddictionCount = 0
    S_Addictions = ""
    S_Immuno = false
    S_RadX = false
    S_Herbals = ""
    Bool[] diseaseSeen = new Bool[6]
    Bool[] addictionSeen = new Bool[25]
    Bool[] herbalSeen = new Bool[3]

    GardenOfEden3:ActiveEffectData[] effects = GardenOfEden3.GetActiveEffects(akPlayer)
    ; Снимок для WATCH нужен только на Trace (Watch без него и не запускается):
    ; иначе каждый цикл строил ~100 строк "эффект src=предмет" впустую, и каждая
    ; новая строка навсегда оседает в таблице строк движка.
    If LOG_LEVEL >= LOG_TRACE
        WatchSeed(effects)
    EndIf
    If effects == None
        S_EffectsTotal = 0
        LogAt(LOG_TRACE, "  EFFECTS GetActiveEffects вернул None")
        Return
    EndIf
    S_EffectsTotal = effects.Length
    Form[] hItem = new Form[0]
    MagicEffect[] hBase = new MagicEffect[0]
    Float[] hElapsed = new Float[0]
    Float[] hMag = new Float[0]
    Float[] hRest = new Float[0]

    Int shown = 0
    Int i = 0
    While i < effects.Length
        GardenOfEden3:ActiveEffectData ae = effects[i]
        If ae != None
            MagicEffect base = ae.BaseEffect
            ; --- статусы ---
            If base != None
                Int d = ME_Disease.Find(base)
                If d >= 0 && !diseaseSeen[d]
                    diseaseSeen[d] = true
                    S_DiseaseCount += 1
                    S_Diseases = Join(S_Diseases, DiseaseNames[d])
                EndIf
                Int h = ME_Herbal.Find(base)
                If h >= 0 && !herbalSeen[h]
                    herbalSeen[h] = true
                    S_Herbals = Join(S_Herbals, HerbalNames[h])
                EndIf
                If base == ME_Immuno
                    S_Immuno = true
                ElseIf base == ME_RadX
                    S_RadX = true
                EndIf
            EndIf
            ; Зависимость — эффект со спеллом AbAddiction* в MagicItem. Проверено
            ; в игре 2026-09-21: настоящую зависимость (X-Cell, выпитый 5 раз)
            ; снимок видит, а HasSpell — НЕТ: движок накладывает её как эффект,
            ; не занося в список спеллов. Консольный `player.addspell 4BAE1`
            ; наоборот: HasSpell = true, но эффекты не активны и Pip-Boy
            ; зависимости не показывает — это не зависимость, лечить нечего.
            Spell sp = ae.MagicItem as Spell
            If sp != None
                Int a = SP_Addiction.Find(sp)
                If a >= 0 && !addictionSeen[a]
                    addictionSeen[a] = true
                    S_AddictionCount += 1
                    S_Addictions = Join(S_Addictions, AddictionNames[a])
                EndIf
            EndIf

            ; --- «в полёте» ---
            Int role = EffectRoleL(base)
            Float left = ae.fDuration - ae.fElapsedTime
            If left < 0.0 || ae.fDuration > PERMANENT_DURATION
                left = 0.0
            EndIf
            Float rest = ae.fMagnitude * left
            If role == TR_HEAL_HP
                ; В сумму — после цикла, за вычетом вариантов по перку (HealVariants).
                hItem.Add(ae.MagicItem)
                hBase.Add(base)
                hElapsed.Add(ae.fElapsedTime)
                hMag.Add(ae.fMagnitude)
                hRest.Add(rest)
            ElseIf role == TR_HEAL_HP_PCT
                S_InHeal += rest
                S_InHealPct += rest
            ElseIf role == TR_RADS_REMOVE
                ; GOEPE отдаёт магнитуду RestoreRadsChem со знаком минус
                ; (RadAway: mag=-16.0), шаг 4. Без Abs нужда по радиации росла
                ; вместо того чтобы падать: 400 rad + «в полёте» -740 = 1140.
                rest = Math.Abs(rest)
                If base == ME_RestoreRadsChem && S_BobbleMedicine
                    rest *= 1.1
                EndIf
                S_InRadOut += rest
                If left > 0.0
                    S_AntiradActive = true
                EndIf
            ElseIf role == TR_RADS_ADD
                S_InRadIn += rest
            ElseIf role == TR_AP_RESTORE
                S_InAP += rest
            ElseIf role == TR_DAMAGE_HP
                S_InDamage += rest
            EndIf
            If LOG_LEVEL >= LOG_TRACE && (role != TR_NONE || ae.fDuration > 0.0)
                shown += 1
                Log("  EFFECT " + base + " role=" + role + " type=" + ae.sType + \
                    " src=" + ae.MagicItem + " mag=" + R1(ae.fMagnitude) + \
                    " dur=" + Dur(ae.fDuration) + " elapsed=" + Dur(ae.fElapsedTime) + \
                    " rest=" + R1(rest))
            EndIf
        EndIf
        i += 1
    EndWhile
    HealVariants(hItem, hBase, hElapsed, hMag, hRest)
    LogAt(LOG_TRACE, "  EFFECTS всего " + S_EffectsTotal + ", показано " + shown + \
        " (временные и наши роли)")
EndFunction

; Лечение «в полёте» без двойного счёта. У предмета с вариантом по перку
; (Ядер-Вишня: 5×10 без журнала PerkMagWastelandSurvival03 и 7.5×10 с ним,
; всего таких ~100 строк таблицы) GOEPE отдаёт ОБА эффекта: условие движок
; проверяет, но признака «неактивен» в ActiveEffectData нет (прогон
; 2026-09-22 14:40: одна бутылка -> rest 47.4 + 71.1). Вариант узнаётся так:
; тот же MagicItem и MagicEffect, то же время приёма, другая сила. Из группы
; остаётся сила, подходящая по перку (есть — большая, нет — меньшая); штуки
; одинаковой силы (несколько доз за раз) складываются как раньше.
Function HealVariants(Form[] akItem, MagicEffect[] akBase, Float[] afElapsed, Float[] afMag, Float[] afRest)
    Int n = akItem.Length
    Float dropped = 0.0
    Int j = 0
    While j < n
        Bool keep = true
        Int e = 0
        While e < n && keep
            If e != j && akItem[e] == akItem[j] && akBase[e] == akBase[j] && afMag[e] != afMag[j]
                Float dt = afElapsed[e] - afElapsed[j]
                ; |dt| < 0.05. Не «dt > -0.05»: отрицательный литерал валит оптимизатор
                ; компилятора в русской локали («входная строка имела неверный формат»).
                If dt * dt < 0.0025
                    If HealPerkOwned(akItem[j])
                        keep = afMag[j] > afMag[e]
                    Else
                        keep = afMag[j] < afMag[e]
                    EndIf
                EndIf
            EndIf
            e += 1
        EndWhile
        If keep
            S_InHeal += afRest[j]
        Else
            dropped += afRest[j]
        EndIf
        j += 1
    EndWhile
    If dropped > 0.0
        LogAt(LOG_TRACE, "  EFFECTS вариант по перку не в счёт: -" + R1(dropped) + " ОЗ «в полёте»")
    EndIf
EndFunction

; Есть ли у игрока перк, усиливающий лечение этого предмета (строка таблицы -> PerkVariant).
Bool Function HealPerkOwned(Form akItem)
    If akItem == None
        Return false
    EndIf
    Int row = IndexOfFullIdL(akItem.GetFormID())
    If row < 0
        Return false
    EndIf
    Return HealWithPerks(row, 0.0) > 0.0
EndFunction

; Сверка болезней, иммунодефицита, Рад-X и снадобий со старым способом шага 3
; (HasMagicEffect). Зависимости не сверяются: HasSpell их не видит (G8).
Function VerifyStatus(Actor akPlayer)
    String diseases = ""
    Int i = 0
    While i < ME_Disease.Length
        If ME_Disease[i] != None && akPlayer.HasMagicEffect(ME_Disease[i])
            diseases = Join(diseases, DiseaseNames[i])
        EndIf
        i += 1
    EndWhile
    Bool immuno = ME_Immuno != None && akPlayer.HasMagicEffect(ME_Immuno)
    Bool radx = ME_RadX != None && akPlayer.HasMagicEffect(ME_RadX)
    String herbals = ""
    i = 0
    While i < ME_Herbal.Length
        If ME_Herbal[i] != None && akPlayer.HasMagicEffect(ME_Herbal[i])
            herbals = Join(herbals, HerbalNames[i])
        EndIf
        i += 1
    EndWhile
    If diseases == S_Diseases && immuno == S_Immuno && radx == S_RadX && herbals == S_Herbals
        S_StatusCheck = "совпало"
    Else
        S_StatusCheck = "РАСХОЖДЕНИЕ: HasMagicEffect дают disease [" + diseases + \
            "] immuno " + immuno + " radx " + radx + " herbals [" + herbals + "]"
    EndIf
EndFunction

; =====================================================================
;  Фаза 0.3 — вектор нужд (§4.1)
; =====================================================================

Function BuildNeeds()
    N_Hunger = 0.0
    If S_Hunger >= HUNGER_TRIGGER
        N_Hunger = S_Hunger - HUNGER_TARGET
    EndIf
    N_Thirst = 0.0
    If S_Thirst >= THIRST_TRIGGER
        N_Thirst = S_Thirst - THIRST_TARGET
    EndIf

    N_RadTrigger = RADS_MAX * RAD_TRIGGER_PCT / 100.0
    N_RadTarget = RADS_MAX * RAD_TARGET_PCT / 100.0
    N_Rads = NeedRads(0.0)

    ; M1: радиация срезает максимум ОЗ. Порог лечения проверяется от максимума
    ; после ПОЛНОГО вывода: при 500 rad и ОЗ «под потолок» лечить всё равно
    ; надо — потолок поднимется. Сколько именно — считает планировщик
    ; (NeedHPGiven) по тому, что реально удалось набрать на вывод.
    N_EffMaxNow = S_MaxHP * (1.0 - S_Rads / RADS_MAX)
    N_EffMaxAfter = EffMax(N_Rads, 0.0)
    N_HPPctEff = 0.0
    If N_EffMaxAfter > 0.0
        N_HPPctEff = S_HP * 100.0 / N_EffMaxAfter
    EndIf
    N_HPTriggered = ENABLE_HEALTH && N_HPPctEff <= HEAL_TRIGGER_PCT
    N_HP = NeedHPGiven(N_Rads, 0.0)

    ; M16: Adamantium Skeleton 3 — конечности не калечатся, ветка выключена.
    ; В силовой броне — только если так задано в MCM (LimbsInPowerArmor).
    N_Limbs = 0
    If S_Adamantium < 3 && ENABLE_LIMBS && (LIMBS_IN_PA || !S_InPowerArmor)
        N_Limbs = S_CrippledCount
    EndIf
    N_Disease = 0
    If ENABLE_DISEASE
        N_Disease = S_DiseaseCount
    EndIf
    N_Addiction = 0
    If ENABLE_ADDICTION
        N_Addiction = S_AddictionCount
    EndIf
    N_AP = S_APPct * 100.0 < AP_TRIGGER_PCT

    ; Какие предметы вообще стоит искать в инвентаре. Лечащая еда может
    ; принести радиацию (M2) — поэтому при нужде в ОЗ ищутся и средства
    ; вывода (правило RAD_CAP_WITHOUT_CURE), и еда на голод (M4).
    N_Uses = 0
    If N_HP > 0.0
        N_Uses = WithBit(N_Uses, USE_HP)
        N_Uses = WithBit(N_Uses, USE_RADS)
    EndIf
    If N_Rads > 0.0
        N_Uses = WithBit(N_Uses, USE_RADS)
    EndIf
    If N_Hunger > 0.0
        N_Uses = WithBit(N_Uses, USE_HUNGER)
    EndIf
    If N_Thirst > 0.0
        N_Uses = WithBit(N_Uses, USE_THIRST)
    EndIf
    If N_Limbs > 0
        N_Uses = WithBit(N_Uses, USE_LIMBS)
    EndIf
    If N_Disease > 0
        N_Uses = WithBit(N_Uses, USE_DISEASE)
    EndIf
    If N_Addiction > 0
        N_Uses = WithBit(N_Uses, USE_ADDICTION)
    EndIf
    If N_AP
        N_Uses = WithBit(N_Uses, USE_AP)
    EndIf
    ; Шаг 6: RadAway вызывает голод (M8), стимпак — жажду. Циклы исполнения
    ; смотрят на живую стадию, поэтому еда и вода нужны им и тогда, когда
    ; сейчас игрок сыт и напоен. На план это не влияет (C_HungerWillClose
    ; при сытом игроке и так true).
    If N_Rads > 0.0
        N_Uses = WithBit(N_Uses, USE_HUNGER)
    EndIf
    If N_Limbs > 0 || N_HP > 0.0
        N_Uses = WithBit(N_Uses, USE_THIRST)
    EndIf
    ; Запас еды считается по ВСЕЙ еде в инвентаре, а не только по лечащей.
    If FOOD_RESERVE > 0 && (N_HP > 0.0 || N_Disease > 0 || N_Addiction > 0)
        N_Uses = WithBit(N_Uses, USE_HUNGER)
    EndIf
EndFunction

; Радиация, которую надо вывести, если план добавит afRadIn едой (M2).
; Порог (M11) проверяется по сырому AV: ниже порога радиация не трогается.
Float Function NeedRads(Float afRadIn)
    If S_Rads + afRadIn < N_RadTrigger
        Return 0.0
    EndIf
    Float need = S_Rads - S_InRadOut + afRadIn - N_RadTarget
    If need < 0.0
        Return 0.0
    EndIf
    Return need
EndFunction

; Потолок ОЗ после того, как план выведет afRadOut и добавит afRadIn (M1).
Float Function EffMax(Float afRadOut, Float afRadIn)
    Float radsAfter = S_Rads - S_InRadOut - afRadOut + afRadIn
    If radsAfter < 0.0
        radsAfter = 0.0
    EndIf
    Return S_MaxHP * (1.0 - radsAfter / RADS_MAX)
EndFunction

; Сколько ОЗ надо долечить при таком выводе/наборе радиации — с учётом
; лечения «в полёте» и урона «в полёте».
Float Function NeedHPGiven(Float afRadOut, Float afRadIn)
    If !N_HPTriggered
        Return 0.0
    EndIf
    Float need = EffMax(afRadOut, afRadIn) * HEAL_TARGET_PCT / 100.0 - S_HP - (S_InHeal - S_InDamage)
    If need < 0.0
        Return 0.0
    EndIf
    Return need
EndFunction

Float Function HPTolerance()
    Return N_EffMaxNow * HP_TOLERANCE_PCT / 100.0
EndFunction

; =====================================================================
;  Фаза 0.4 — кандидаты: пересечение инвентаря и таблицы
; =====================================================================

; Шаг 5: на предмет — два вызова, ждущих кадра (GetNthItemFormID и
; GetNthItemCount), вместо ~7 на шаге 3 (76 мс на предмет). Строка таблицы
; ищется по полному FormID (FindStruct, без кадра), цена — из кеша сессии,
; имя — только для лога. Нужд нет — инвентарь не читается вовсе.
;
; aiForceUses — искать и эти назначения, даже если нужды нет (тест A16).
Function CollectCandidates(Actor akPlayer, Int aiForceUses)
    C_Total = 0
    C_Unknown = 0
    C_Excluded = 0
    C_Idle = 0
    C_Path = "-"
    X_Forms = new Form[0]
    X_Slots = new Int[0]
    X_Why = new String[0]
    K_Forms = new Form[0]
    K_Rows = new Int[0]
    K_Counts = new Int[0]
    K_Slots = new Int[0]
    K_Uses = new Int[0]
    K_Flags = new Int[0]
    K_Values = new Int[0]
    K_Risk = new Int[0]

    Int wanted = N_Uses
    Int mask = 1
    While mask <= USE_LIMBS
        If Has(aiForceUses, mask)
            wanted = WithBit(wanted, mask)
        EndIf
        mask *= 2
    EndWhile
    If wanted == 0
        Return
    EndIf
    If CollectFromForms(akPlayer, wanted)
        C_Path = "F4SE"
        Return
    EndIf
    C_Path = "GOEPE"

    ; Запасной путь (F4SE GetInventoryItems не ответил): по ячейкам GOEPE.
    Int[] slots = GardenOfEden3.GetItemIndexesByFormType(akPlayer, "ALCH")
    If slots == None
        LogAt(LOG_DETAILED, "  CANDS  GetItemIndexesByFormType вернул None")
        Return
    EndIf
    C_Total = slots.Length

    ; Строки, уже отброшенные в этом цикле: у формы бывает несколько стопок
    ; (сыворотка x4 и x1 на прогоне шага 3), каждая приходит своим слотом.
    Int[] skipped = new Int[0]
    Int i = 0
    While i < slots.Length
        Int row = IndexOfFullIdL(GardenOfEden.GetNthItemFormID(akPlayer, slots[i]))
        If row < 0
            C_Unknown += 1
        Else
            Int k = K_Rows.Find(row)
            If k >= 0
                K_Counts[k] = K_Counts[k] + GardenOfEden.GetNthItemCount(akPlayer, slots[i])
            ElseIf skipped.Find(row) < 0
                AutoMedicTables:ItemData data = ItemDataL(row)
                Int uses = UsesOf(data)
                String why = ExcludeReason(data)
                If why == "" && !Shares(uses, wanted)
                    C_Idle += 1
                    skipped.Add(row)
                ElseIf why == "" && K_Rows.Length < 128
                    Int value = CachedValue(data.Item)
                    If MAX_ITEM_VALUE > 0.0 && value > MAX_ITEM_VALUE
                        why = "дороже " + R0(MAX_ITEM_VALUE) + "c"
                    Else
                        K_Forms.Add(data.Item)
                        K_Rows.Add(row)
                        K_Counts.Add(GardenOfEden.GetNthItemCount(akPlayer, slots[i]))
                        K_Slots.Add(slots[i])
                        K_Uses.Add(uses)
                        K_Flags.Add(data.Flags)
                        K_Values.Add(value)
                        K_Risk.Add(data.DiseaseRiskPct)
                    EndIf
                EndIf
                If why != ""
                    C_Excluded += 1
                    skipped.Add(row)
                    If X_Forms.Length < 128
                        X_Forms.Add(data.Item)
                        X_Slots.Add(slots[i])
                        X_Why.Add(why)
                    EndIf
                EndIf
            EndIf
        EndIf
        i += 1
    EndWhile
EndFunction

; Основной путь (2026-09-22): F4SE ObjectReference.GetInventoryItems() отдаёт
; все базовые формы инвентаря ОДНИМ вызовом. Путь по ячейкам GOEPE стоил два
; ожидающих кадра вызова на ячейку (GetNthItemFormID + GetNthItemCount):
; 1.4 с на 50 ячеек ALCH. Здесь отбор идёт без внешних вызовов (приведение к
; Potion и FindStruct по локальной копии таблицы), а кадр ждут только
; GetItemCount у прошедших отбор. Ячеек больше нет: имя для лога ищется по
; форме (CheckedSlot с -1). false — F4SE не ответил, нужен запасной путь.
Bool Function CollectFromForms(Actor akPlayer, Int aiWanted)
    Float t = Utility.GetCurrentRealTime()
    Form[] forms = akPlayer.GetInventoryItems()
    C_ListSec = Utility.GetCurrentRealTime() - t
    If forms == None
        LogAt(LOG_DETAILED, "  CANDS  GetInventoryItems вернул None - запасной путь через GOEPE")
        Return false
    EndIf
    Int i = 0
    While i < forms.Length
        Potion item = forms[i] as Potion
        If item != None
            C_Total += 1
            Int row = IndexOfFormL(item)
            If row < 0
                C_Unknown += 1
            ElseIf K_Rows.Find(row) < 0
                AutoMedicTables:ItemData data = ItemDataL(row)
                Int uses = UsesOf(data)
                String why = ExcludeReason(data)
                If why == "" && !Shares(uses, aiWanted)
                    C_Idle += 1
                ElseIf why == "" && K_Rows.Length < 128
                    Int value = CachedValue(data.Item)
                    If MAX_ITEM_VALUE > 0.0 && value > MAX_ITEM_VALUE
                        why = "дороже " + R0(MAX_ITEM_VALUE) + "c"
                    Else
                        Int count = akPlayer.GetItemCount(item)
                        If count > 0
                            K_Forms.Add(data.Item)
                            K_Rows.Add(row)
                            K_Counts.Add(count)
                            K_Slots.Add(-1)
                            K_Uses.Add(uses)
                            K_Flags.Add(data.Flags)
                            K_Values.Add(value)
                            K_Risk.Add(data.DiseaseRiskPct)
                        EndIf
                    EndIf
                EndIf
                If why != ""
                    C_Excluded += 1
                    If X_Forms.Length < 128
                        X_Forms.Add(data.Item)
                        X_Slots.Add(-1)
                        X_Why.Add(why)
                    EndIf
                EndIf
            EndIf
        EndIf
        i += 1
    EndWhile
    Return true
EndFunction

; Как AutoMedicTables.IndexOf(Form), но по локальной копии таблицы.
Int Function IndexOfFormL(Form akItem)
    Int chunk = 0
    While chunk < 3
        AutoMedicTables:ItemData[] rows = ItemChunkL(chunk)
        If rows != None
            Int slot = rows.FindStruct("Item", akItem, 0)
            If slot >= 0
                Return chunk * TB_ChunkSize + slot
            EndIf
        EndIf
        chunk += 1
    EndWhile
    Return -1
EndFunction

; Под какие нужды предмет годится вообще (без учёта M4 и резервов).
Int Function UsesOf(AutoMedicTables:ItemData akData)
    Int flags = akData.Flags
    Int uses = 0
    If akData.HealHP > 0.0 || akData.HealPctOfMax > 0.0
        uses = WithBit(uses, USE_HP)
    EndIf
    ; Конечности лечит только стимпак (A6): ObjectTypeStimpak и лечение в
    ; процентах. У Curie's Healthpak ключевое слово есть, но лечит он в ОЗ.
    If Has(flags, TF_CAT_STIMPAK) && akData.HealPctOfMax > 0.0
        uses = WithBit(uses, USE_LIMBS)
    EndIf
    If akData.RadsRemove > 0.0
        uses = WithBit(uses, USE_RADS)
    EndIf
    If Has(flags, TF_SATES_HUNGER)
        uses = WithBit(uses, USE_HUNGER)
    EndIf
    If Has(flags, TF_SATES_THIRST)
        uses = WithBit(uses, USE_THIRST)
    EndIf
    If Has(flags, TF_CURES_DISEASE)
        uses = WithBit(uses, USE_DISEASE)
    EndIf
    If Has(flags, TF_CURES_ADDICTION)
        uses = WithBit(uses, USE_ADDICTION)
    EndIf
    If akData.ApRestore > 0.0
        uses = WithBit(uses, USE_AP)
    EndIf
    Return uses
EndFunction

; "" — предмет годится; иначе причина, по которой мод его не тронет никогда.
String Function ExcludeReason(AutoMedicTables:ItemData akData)
    Int flags = akData.Flags
    If Has(flags, TF_BLACKLISTED)
        Return "чёрный список"
    ElseIf USE_EXCLUSIONS && AM_Excluded.Find(akData.Item) >= 0
        Return "файл исключений"
    ElseIf Has(flags, TF_CAT_SYRINGER)
        Return "шприцемёт"
    ElseIf !ALLOW_STIMPAK && Has(flags, TF_CAT_STIMPAK)
        Return "стимпаки выключены"
    ElseIf !ALLOW_RADAWAY && akData.MedicRadMag > 0.0 && akData.MedicRadDur > 0.0
        Return "антирадин выключен"
    ElseIf !USE_CHEMS && Has(flags, TF_ADDICTIVE)
        Return "аддиктивная химия"
    ElseIf !USE_ALCOHOL && Has(flags, TF_CAT_ALCOHOL)
        Return "алкоголь"
    ElseIf akData.DiseaseRiskPct > MAX_DISEASE_RISK_PCT
        Return "риск болезни " + akData.DiseaseRiskPct + "%"
    EndIf
    Return ""
EndFunction

Int Function CachedValue(Form akItem)
    Int i = VC_Forms.Find(akItem)
    If i >= 0
        Return VC_Values[i]
    EndIf
    Int value = akItem.GetGoldValue()
    If VC_Forms.Length < 128
        VC_Forms.Add(akItem)
        VC_Values.Add(value)
    EndIf
    Return value
EndFunction

; Имя предмета для лога: из кеша сессии, иначе GetNthItemName по слоту.
String Function SlotName(Actor akPlayer, Form akItem, Int aiSlot)
    Int i = NC_Forms.Find(akItem)
    If i >= 0
        Return NC_Names[i]
    EndIf
    If aiSlot < 0
        ; Предмета уже нет — в кеш сессии ничего не кладём.
        Return "?"
    EndIf
    String name = GardenOfEden.GetNthItemName(akPlayer, aiSlot)
    If NC_Forms.Length < 128
        NC_Forms.Add(akItem)
        NC_Names.Add(name)
    EndIf
    Return name
EndFunction

String Function CandName(Int k)
    If K_Names[k] == ""
        K_Names[k] = SlotName(PlayerRef(), K_Forms[k], CheckedSlot(PlayerRef(), K_Forms[k], K_Slots[k]))
    EndIf
    Return K_Names[k]
EndFunction

; Ячейка инвентаря, в которой сейчас лежит akItem. Номера ячеек сдвигаются,
; когда что-то съедено до последней штуки, — а имя GOEPE отдаёт только по
; ячейке (функции «имя формы» в GOEPE нет). Сверка — один вызов; ячейка
; уехала — ищем заново. -1: предмета в инвентаре нет.
Int Function CheckedSlot(Actor akPlayer, Form akItem, Int aiSlot)
    Int id = akItem.GetFormID()
    If aiSlot >= 0 && GardenOfEden.GetNthItemFormID(akPlayer, aiSlot) == id
        Return aiSlot
    EndIf
    Int[] found = GardenOfEden.GetItemIndexesByFormID(akPlayer, id)
    If found != None && found.Length > 0
        Return found[0]
    EndIf
    Return -1
EndFunction

; =====================================================================
;  Фаза 0.5 — оценка кандидатов для этого игрока (M4, M7, Lead Belly)
; =====================================================================

; Итог эффекта, который усиливают Medic и бобблхед (M7). По esm (шаг 5):
; Medic ПРИБАВЛЯЕТ к магнитуде эффектов с ChemTypeStimpack / ChemTypeRadaway —
; стимпак +2 / +6 / +10 / +27.34 %/с, RadAway +20 / +60 / +100 / +273.34 рад/с,
; ранг 4 ещё и -2 с длительности. Отсюда 30/40/60/80/100 % и
; 300/400/600/800/1000 rad из §2.3. Бобблхед — ×1.1 (замерено на стимпаке
; на шаге 3 и на RadAway на шаге 4). У X-111 длительность 0: прибавка
; ложится прямо на итог (600 -> 700 при Medic 3, отсюда «-700» на вики).
Float Function MedicTotal(Float afMag, Float afDur, Bool abRads)
    Float add = 0.0
    If S_Medic == 1
        add = 2.0
    ElseIf S_Medic == 2
        add = 6.0
    ElseIf S_Medic == 3
        add = 10.0
    ElseIf S_Medic >= 4
        add = 27.34
    EndIf
    If abRads
        add *= 10.0
    EndIf
    Float bob = 1.0
    If S_BobbleMedicine
        bob = 1.1
    EndIf
    If afDur > 0.0
        Float dur = afDur
        If S_Medic >= 4
            dur = afDur - 2.0
        EndIf
        Return (afMag + add) * dur * bob
    EndIf
    Return (afMag + add) * bob
EndFunction

; Вклад того же эффекта без перков — ровно то, что лежит в итоге таблицы.
Float Function PlainTotal(Float afMag, Float afDur)
    If afDur > 0.0
        Return afMag * afDur
    EndIf
    Return afMag
EndFunction

; A9 (шаг 4): грязная вода 7 rad -> Lead Belly 1: 3.1, 2: 2.4, 3: 0.
Float Function LeadBellyFactor()
    If S_LeadBelly == 1
        Return 0.45
    ElseIf S_LeadBelly == 2
        Return 0.35
    ElseIf S_LeadBelly >= 3
        Return 0.0
    EndIf
    Return 1.0
EndFunction

; Лечение едой с перком (журналы Wasteland Survival, Cannibal) — вариант из
; таблицы ЗАМЕНЯЕТ базовое лечение. Из нескольких сработавших — наибольший.
Float Function HealWithPerks(Int aiRow, Float afBase)
    Float best = afBase
    AutoMedicTables:PerkVariant[] variants = AM_Tables.GetPerkVariants(aiRow)
    Int i = 0
    While i < variants.Length
        AutoMedicTables:PerkVariant v = variants[i]
        If v.Role == TR_HEAL_HP && v.Amount > best
            If HasPerkLocal(v.Perk1) || HasPerkLocal(v.Perk2) || HasPerkLocal(v.Perk3)
                best = v.Amount
            EndIf
        EndIf
        i += 1
    EndWhile
    Return best
EndFunction

Function EvalCandidates()
    Int n = K_Forms.Length
    K_Avail = new Int[n]
    K_Heal = new Float[n]
    K_RadOut = new Float[n]
    K_RadIn = new Float[n]
    K_AfterFood = new Bool[n]
    K_InPool = new Bool[n]
    K_InCola = new Bool[n]
    K_APLocked = new Bool[n]
    C_FoodPool = 0
    C_ColaPool = 0
    C_APLocked = 0
    K_Dead = new Bool[n]
    K_Names = new String[n]
    C_HPCount = 0
    C_RadsCount = 0
    C_HungerCount = 0
    C_ThirstCount = 0
    C_DiseaseCount = 0
    C_AddictionCount = 0
    C_APCount = 0
    C_LimbsCount = 0
    C_HungerCheapest = -1
    C_ThirstCheapest = -1

    ; ОД-напитки при ОД выше порога заперты для ВСЕХ нужд (и для циклов голода/жажды).
    ; Максимум ОД без дебафов — большее из базы и текущего максимума (бафы Ловкости).
    Float apMax = S_APBase
    If S_APPct > 0.0 && S_AP / S_APPct > apMax
        apMax = S_AP / S_APPct
    EndIf
    C_APBig = apMax * AP_BIG_PCT / 100.0
    Bool apLow = AP_TRIGGER_PCT >= 100.0 || S_APPct * 100.0 < AP_TRIGGER_PCT
    C_APWhy = "ОД " + R0(S_APPct * 100.0) + "% не ниже " + R0(AP_TRIGGER_PCT) + "%"
    If AP_ITEMS_MODE == 0
        apLow = false
        C_APWhy = "режим «никогда»"
    ElseIf AP_ITEMS_MODE == 1 && !S_InCombat
        apLow = false
        C_APWhy = "не в бою (режим «только в бою»)"
    EndIf
    Int k = 0
    While k < n
        K_APLocked[k] = !apLow && ItemDataL(K_Rows[k]).ApRestore > C_APBig
        If K_APLocked[k]
            C_APLocked += 1
        EndIf
        k += 1
    EndWhile

    ; Сначала — закроется ли голод: от этого зависит, подействует ли еда (M4).
    k = 0
    While k < n
        K_Names[k] = ""
        If K_APLocked[k]
            ; не в счёт: ни голод, ни жажду этим закрывать не будем
        ElseIf Has(K_Uses[k], USE_HUNGER)
            C_HungerCount += 1
            If C_HungerCheapest < 0 || K_Values[k] < K_Values[C_HungerCheapest]
                C_HungerCheapest = k
            EndIf
        EndIf
        If !K_APLocked[k] && Has(K_Uses[k], USE_THIRST)
            C_ThirstCount += 1
            If C_ThirstCheapest < 0 || K_Values[k] < K_Values[C_ThirstCheapest]
                C_ThirstCheapest = k
            EndIf
        EndIf
        k += 1
    EndWhile
    ; Цикл шага 6 доводит голод до HUNGER_TARGET. Еда лечит только при Fed —
    ; значит, рассчитывать на неё можно, лишь если цель Fed и есть чем её достичь.
    C_HungerWillClose = S_Hunger < 0.5 || (N_Hunger > 0.0 && HUNGER_TARGET == 0 && C_HungerCount > 0)

    Float lead = LeadBellyFactor()
    k = 0
    While k < n
        AutoMedicTables:ItemData d = ItemDataL(K_Rows[k])
        Int flags = K_Flags[k]
        K_AfterFood[k] = Has(flags, TF_CAT_FOOD) && !Has(flags, TF_IGNORE_AS_FOOD)
        K_Dead[k] = K_AfterFood[k] && !C_HungerWillClose

        Float heal = 0.0
        Float pct = d.HealPctOfMax
        If d.MedicHealMag > 0.0
            pct = pct - PlainTotal(d.MedicHealMag, d.MedicHealDur) + MedicTotal(d.MedicHealMag, d.MedicHealDur, false)
        EndIf
        If d.HealHP > 0.0
            heal = HealWithPerks(K_Rows[k], d.HealHP)
        EndIf
        heal += pct * S_MaxHP / 100.0
        Float radOut = d.RadsRemove
        If d.MedicRadMag > 0.0
            radOut = radOut - PlainTotal(d.MedicRadMag, d.MedicRadDur) + MedicTotal(d.MedicRadMag, d.MedicRadDur, true)
        EndIf
        If K_Dead[k]
            heal = 0.0
            radOut = 0.0
        EndIf
        K_Heal[k] = heal
        K_RadOut[k] = radOut
        K_RadIn[k] = d.RadsAdd * lead
        K_InPool[k] = Has(K_Uses[k], USE_HUNGER) && (FOOD_RESERVE_RADS || d.RadsAdd <= 0.0)
        If K_InPool[k]
            C_FoodPool += K_Counts[k]
        EndIf
        K_InCola[k] = Has(flags, TF_CAT_COLA)
        If K_InCola[k]
            C_ColaPool += K_Counts[k]
        EndIf
        ; Запертый ОД-напиток: ни на что (LoopPick/CheapestUsable/PlanLimbs смотрят K_Uses).
        If K_APLocked[k]
            K_Uses[k] = 0
            heal = 0.0
            radOut = 0.0
            K_Heal[k] = 0.0
            K_RadOut[k] = 0.0
        EndIf

        ; Резервы §7 «Экономия»: стимпаки и RadAway (RadAway — единственный
        ; предмет с растянутым RestoreRadsChem).
        Int reserve = 0
        If Has(K_Uses[k], USE_LIMBS)
            reserve = RESERVE_STIMPAKS
        ElseIf d.MedicRadMag > 0.0 && d.MedicRadDur > 0.0
            reserve = RESERVE_RADAWAY
        EndIf
        K_Avail[k] = K_Counts[k] - reserve
        If K_Avail[k] < 0 || K_APLocked[k]
            K_Avail[k] = 0
        EndIf

        If heal > 0.0
            C_HPCount += 1
        EndIf
        If radOut > 0.0
            C_RadsCount += 1
        EndIf
        If Has(K_Uses[k], USE_LIMBS)
            C_LimbsCount += 1
        EndIf
        If Has(K_Uses[k], USE_DISEASE) && !K_Dead[k]
            C_DiseaseCount += 1
        EndIf
        If Has(K_Uses[k], USE_ADDICTION) && !K_Dead[k]
            C_AddictionCount += 1
        EndIf
        If Has(K_Uses[k], USE_AP)
            C_APCount += 1
        EndIf
        k += 1
    EndWhile
EndFunction

; =====================================================================
;  Фазы 1-2 — планировщик и обрезка (§4.2, §4.3)
; =====================================================================

; Стадии идут в порядке §4.2: A — радиация (она поднимает потолок ОЗ, M1),
; B — конечности (один стимпак лечит все, его ОЗ вычитаются из нужды),
; D — болезни и зависимости (омлет лечит заодно и ОЗ), C — здоровье,
; и A' — добор вывода под радиацию, которую принесёт лечащая еда (M2):
; тогда один антирад подметает и старую, и новую.
;
; Голод и жажда НЕ планируются: их закрывает замкнутый цикл шага 6 (§1.1).
; Планировщику от них нужно одно — закроется ли голод (M4, C_HungerWillClose).
Function Plan()
    P_K = new Int[0]
    P_For = new Int[0]
    P_Gain = new Float[0]
    P_Cost = new Float[0]
    P_Trace = ""
    P_Trim = ""
    P_Notes = ""
    P_LimitHit = false
    P_ReserveHit = false
    P_RadsUnprofitable = false
    If C_APLocked > 0
        P_Notes = Join(P_Notes, "ОД-напитки (> " + R0(C_APBig) + " ОД) не трогаю: " + C_APWhy + \
            " (" + C_APLocked + " видов)")
    EndIf

    PlanRads("A")
    PlanLimbs()
    PlanCures()
    PlanHealth("C")
    Totals(-1)
    If RadShortfall(-1) > RAD_TOLERANCE && C_RadsCount > 0 && !P_RadsUnprofitable
        PlanRads("A'")
        PlanHealth("C'")
    EndIf
    Trim()
    Totals(-1)
EndFunction

; Суммы по плану без строки aiExcept (-1 — по всему плану) -> T_*.
Function Totals(Int aiExcept)
    T_Heal = 0.0
    T_RadOut = 0.0
    T_RadIn = 0.0
    T_Immuno = false
    Int e = 0
    While e < P_K.Length
        If e != aiExcept
            Int k = P_K[e]
            T_Heal += K_Heal[k]
            T_RadOut += K_RadOut[k]
            T_RadIn += K_RadIn[k]
            If Has(K_Flags[k], TF_IMMUNO_DEF)
                T_Immuno = true
            EndIf
        EndIf
        e += 1
    EndWhile
EndFunction

Float Function RadShortfall(Int aiExcept)
    Totals(aiExcept)
    Float s = NeedRads(T_RadIn) - T_RadOut
    If s < 0.0
        Return 0.0
    EndIf
    Return s
EndFunction

Float Function HPShortfall(Int aiExcept)
    Totals(aiExcept)
    Float s = NeedHPGiven(T_RadOut, T_RadIn) - T_Heal
    If s < 0.0
        Return 0.0
    EndIf
    Return s
EndFunction

Int Function Planned(Int k)
    Int n = 0
    ; Не Find(k, e + 1): на последнем элементе стартовый индекс выходит за
    ; массив, и Papyrus пишет «Array start index out of range» (прогон 21:59).
    Int e = 0
    While e < P_K.Length
        If P_K[e] == k
            n += 1
        EndIf
        e += 1
    EndWhile
    Return n
EndFunction

Int Function LeftOf(Int k)
    Return K_Avail[k] - Planned(k)
EndFunction

; Запас еды (MCM «Голод и жажда»): ещё одна штука k на ОЗ, радиацию или
; излечение опустила бы запас ниже FOOD_RESERVE. Циклы голода запас есть
; могут — в план (P_K) они не входят, поэтому здесь считаются только строки плана.
Bool Function ReserveBlocks(Int k)
    If ColaReserveBlocks(k)
        Return true
    EndIf
    If FOOD_RESERVE <= 0 || !K_InPool[k]
        Return false
    EndIf
    Int taken = 0
    Int e = 0
    While e < P_K.Length
        If K_InPool[P_K[e]]
            taken += 1
        EndIf
        e += 1
    EndWhile
    If C_FoodPool - taken - 1 < FOOD_RESERVE
        P_ReserveHit = true
        Return true
    EndIf
    Return false
EndFunction

; Запас Ядер-Колы (MCM ColaReserve): как запас еды, но для всех видов колы
; вместе и без поблажки циклам голода/жажды — кола не тратится ниже N никем.
Bool Function ColaReserveBlocks(Int k)
    If COLA_RESERVE <= 0 || !K_InCola[k]
        Return false
    EndIf
    If C_ColaPool - ColaPlanned() - 1 < COLA_RESERVE
        P_ReserveHit = true
        Return true
    EndIf
    Return false
EndFunction

; Сколько штук колы уже в плане.
Int Function ColaPlanned()
    Int taken = 0
    Int e = 0
    While e < P_K.Length
        If K_InCola[P_K[e]]
            taken += 1
        EndIf
        e += 1
    EndWhile
    Return taken
EndFunction

; Сколько колы осталось при исполнении (минус уже принятое в этом цикле).
Int Function ColaPoolLeft()
    Int left = C_ColaPool
    Int k = 0
    While k < E_Used.Length
        If K_InCola[k]
            left -= E_Used[k]
        EndIf
        k += 1
    EndWhile
    Return left
EndFunction

; То же при исполнении, по живому остатку: цикл голода мог съесть часть запаса.
Int Function FoodPoolLeft()
    Int left = C_FoodPool
    Int k = 0
    While k < E_Used.Length
        If K_InPool[k]
            left -= E_Used[k]
        EndIf
        k += 1
    EndWhile
    Return left
EndFunction

; cost(i) из §4.2, в крышках. Радиация от предмета учитывается не здесь,
; а вычитается из выгоды (Gain) — в тех же единицах, что и сама выгода.
Float Function CostOf(Int k)
    Float c = K_Values[k] + COST_PER_ITEM
    Float risk = K_Risk[k] * COST_PER_RISK_PCT
    If Has(K_Flags[k], TF_IMMEDIATE_CHECK)
        risk *= 2.0
    EndIf
    c += risk
    If Has(K_Flags[k], TF_IMMUNO_DEF)
        Totals(-1)
        If S_Immuno || T_Immuno
            c += COST_IMMUNO_ACTIVE
        Else
            c += COST_IMMUNO
        EndIf
    EndIf
    Int have = K_Counts[k] - Planned(k)
    If have < 1
        have = 1
    EndIf
    c += COST_SCARCITY / have
    Return c
EndFunction

; Можно ли добавить ещё rads едой: iMaxIngestedRads и, если вывести нечем,
; решение 1 — не переходить порог радиации.
Bool Function RadsAllowed(Int k)
    If K_RadIn[k] <= 0.0
        Return true
    EndIf
    Totals(-1)
    If T_RadIn + K_RadIn[k] > MAX_INGESTED_RADS
        Return false
    EndIf
    If RAD_CAP_WITHOUT_CURE && C_RadsCount == 0 && S_Rads + T_RadIn + K_RadIn[k] >= N_RadTrigger
        Return false
    EndIf
    Return true
EndFunction

; Выгода предмета для нужды при остатке afRem. min() отсекает перерасход:
; за избыток сверх нужды предмет баллов не получает (§4.2).
Float Function Gain(Int k, Int aiNeed, Float afRem)
    Float hpPerRad = S_MaxHP / RADS_MAX
    If aiNeed == NEED_RADS
        Return Math.Min(K_RadOut[k], afRem) - K_RadIn[k]
    ElseIf aiNeed == NEED_HP
        ; Радиация: вывод в пределах оставшейся нужды — в плюс, набор — в
        ; минус, оба в ОЗ потолка (M1): «съесть грязное ради лечения» честно.
        Float g = Math.Min(K_Heal[k], afRem) - K_RadIn[k] * hpPerRad
        Float radRem = RadShortfall(-1)
        If radRem > 0.0
            g += Math.Min(K_RadOut[k], radRem) * hpPerRad
        EndIf
        Return g
    EndIf
    Return 0.0
EndFunction

; Лучший кандидат для нужды по gain / cost или -1. Заодно запоминает
; второго (для строки PICK в логе).
Int Function BestFor(Int aiNeed, Float afRem)
    Int best = -1
    Float bestScore = 0.0
    G_Second = -1
    G_SecondScore = 0.0
    G_Considered = 0
    Int k = 0
    While k < K_Forms.Length
        Bool fits = false
        If aiNeed == NEED_RADS
            fits = K_RadOut[k] > 0.0
        ElseIf aiNeed == NEED_HP
            fits = K_Heal[k] > 0.0
        EndIf
        If fits && LeftOf(k) > 0 && RadsAllowed(k) && !ReserveBlocks(k)
            Float gain = Gain(k, aiNeed, afRem)
            If gain > 0.0
                G_Considered += 1
                Float score = gain / CostOf(k)
                If score > bestScore
                    G_Second = best
                    G_SecondScore = bestScore
                    best = k
                    bestScore = score
                ElseIf score > G_SecondScore
                    G_Second = k
                    G_SecondScore = score
                EndIf
            EndIf
        EndIf
        k += 1
    EndWhile
    If best < 0
        Return -1
    EndIf
    ; Для ОЗ BestFor больше не зовётся (стадия C — PlanHealth), порог — только rads.
    Float minScore = MIN_SCORE_RADS
    Bool rejected = bestScore < minScore
    If LOG_LEVEL >= LOG_TRACE
        String second = "-"
        If G_Second >= 0
            second = CandName(G_Second) + " " + R1(G_SecondScore)
        EndIf
        String verdict = ""
        If rejected
            verdict = "  -> НЕ БЕРУ: балл ниже " + R1(minScore)
        EndIf
        P_Trace = P_Trace + "\n         PICK   " + NeedName(aiNeed) + " rem " + R0(afRem) + ": " + \
            CandName(best) + " gain " + R0(Gain(best, aiNeed, afRem)) + " / cost " + R1(CostOf(best)) + \
            " = " + R1(bestScore) + "  (из " + G_Considered + ", второй: " + second + ")" + verdict
    EndIf
    If rejected
        P_RadsUnprofitable = true
        Return -1
    EndIf
    Return best
EndFunction

Bool Function AddEntry(Int k, Int aiNeed, Float afGain)
    If P_K.Length >= MAX_PLAN_ITEMS
        P_LimitHit = true
        Return false
    EndIf
    Float cost = CostOf(k)
    P_K.Add(k)
    P_For.Add(aiNeed)
    P_Gain.Add(afGain)
    P_Cost.Add(cost)
    Return true
EndFunction

; A: минимальный набор под радиацию. Порядок предпочтения §4.2 (дешёвые
; рад-продукты -> X-111 -> RadAway) получается из cost сам: у RadAway
; к цене добавлен иммунодефицит (M10).
Function PlanRads(String asStage)
    Float rem = RadShortfall(-1)
    If rem <= RAD_TOLERANCE
        Return
    EndIf
    If S_AntiradActive
        P_Notes = Join(P_Notes, "rads: антирад уже действует, в полёте -" + R0(S_InRadOut) + \
            " — добираю только недостающее (A7: вторая доза ускоряет вывод)")
    EndIf
    While rem > RAD_TOLERANCE
        Int k = BestFor(NEED_RADS, rem)
        If k < 0 || !AddEntry(k, NEED_RADS, Gain(k, NEED_RADS, rem))
            Return
        EndIf
        rem = RadShortfall(-1)
    EndWhile
EndFunction

; B: один стимпак на все конечности (A6).
Function PlanLimbs()
    If N_Limbs <= 0
        Return
    EndIf
    ; Стимпак уже капает — он долечит и конечности; второй сожжёт пачку (M6).
    If S_InHealPct > 0.0
        P_Notes = Join(P_Notes, "limbs: стимпак уже действует, второй не нужен")
        Return
    EndIf
    Int best = -1
    Int k = 0
    While k < K_Forms.Length
        If Has(K_Uses[k], USE_LIMBS) && LeftOf(k) > 0
            If best < 0 || CostOf(k) < CostOf(best)
                best = k
            EndIf
        EndIf
        k += 1
    EndWhile
    If best >= 0
        AddEntry(best, NEED_LIMBS, K_Heal[best])
    EndIf
EndFunction

; D: по одному предмету на болезни и на зависимости — самый дешёвый по cost
; (омлет из яиц радскорпиона против Аддиктола). Лечение этого предмета
; идёт в зачёт ОЗ на стадии C.
Function PlanCures()
    If N_Disease > 0
        Int k = CheapestUsable(USE_DISEASE)
        If k >= 0
            AddEntry(k, NEED_DISEASE, 0.0)
        EndIf
    EndIf
    If N_Addiction > 0
        Int k = CheapestUsable(USE_ADDICTION)
        If k >= 0
            AddEntry(k, NEED_ADDICTION, 0.0)
        EndIf
    EndIf
EndFunction

Int Function CheapestUsable(Int aiUse)
    Int best = -1
    Float bestCost = 0.0
    Int k = 0
    While k < K_Forms.Length
        If Has(K_Uses[k], aiUse) && !K_Dead[k] && LeftOf(k) > 0 && RadsAllowed(k) && !ReserveBlocks(k)
            ; Лечение попутно — скидка: этот предмет закроет часть нужды в ОЗ.
            Float cost = CostOf(k) - Math.Min(K_Heal[k], HPShortfall(-1)) * 0.1
            If best < 0 || cost < bestCost
                best = k
                bestCost = cost
            EndIf
        EndIf
        k += 1
    EndWhile
    Return best
EndFunction

; C: здоровье — набор с МИНИМАЛЬНЫМ ПЕРЕЛЕЧЕНИЕМ (решение пользователя
; 2026-09-22: цена в крышках решает только голод; «осталось 80 — лучше 40 + 50,
; чем одна на 110»). Наборы сравниваются по (добран ли, потери ОЗ, штук, cost):
; потери — перелечение (недобор, если не добрать) плюс потолок, съеденный
; радиацией еды; cost — только последний тай-брейк. Дубликаты разрешены —
; шаг 4 опроверг M9/A5. Зеркало — plan_sim.plan_health.
Function PlanHealth(String asStage)
    Float tol = HPTolerance()
    Float rem = HPShortfall(-1)
    If rem <= tol
        Return
    EndIf
    H_Slots = MAX_PLAN_ITEMS - P_K.Length
    If H_Slots <= 0
        P_LimitHit = true
        Return
    EndIf
    Float hpr = S_MaxHP / RADS_MAX
    Float tgt = HEAL_TARGET_PCT / 100.0
    Totals(-1)
    Float radsNow = S_Rads - S_InRadOut - T_RadOut + T_RadIn
    If radsNow < 0.0
        radsNow = 0.0
    EndIf
    ; Те же ограничения, что RadsAllowed и ReserveBlocks, но на весь набор.
    H_RadRoom = MAX_INGESTED_RADS - T_RadIn
    H_HasCap = RAD_CAP_WITHOUT_CURE && C_RadsCount == 0
    H_RadCap = N_RadTrigger - S_Rads - T_RadIn
    H_HasPool = FOOD_RESERVE > 0
    H_PoolRoom = 0
    If H_HasPool
        Int taken = 0
        Int e = 0
        While e < P_K.Length
            If K_InPool[P_K[e]]
                taken += 1
            EndIf
            e += 1
        EndWhile
        H_PoolRoom = C_FoodPool - taken - FOOD_RESERVE
    EndIf
    H_HasCola = COLA_RESERVE > 0
    H_ColaRoom = C_ColaPool - ColaPlanned() - COLA_RESERVE

    ; Кандидаты: закрытие нужды за штуку. Радиация еды опускает потолок —
    ; нужда меньше; вывод поднимает — нужда больше.
    Int n = K_Forms.Length
    Float[] cov = new Float[n]
    Int m = 0
    Int k = 0
    While k < n
        cov[k] = 0.0
        ; Грязная вода и т. п.: риск с немедленной проверкой ради пары десятков
        ; ОЗ не берём (раньше это отсекал балл выгоды на крышку).
        If K_Heal[k] > 0.0 && LeftOf(k) > 0 && !(K_Risk[k] > 0 && Has(K_Flags[k], TF_IMMEDIATE_CHECK))
            Float out = K_RadOut[k]
            If out > radsNow
                out = radsNow
            EndIf
            cov[k] = K_Heal[k] + (K_RadIn[k] - out) * hpr * tgt
            If cov[k] > 0.0
                m += 1
            EndIf
        EndIf
        k += 1
    EndWhile
    If m == 0
        Return
    EndIf
    H_K = new Int[m]
    H_Cov = new Float[m]
    H_Pen = new Float[m]
    H_Cost = new Float[m]
    H_Left = new Int[m]
    H_Pool = new Bool[m]
    H_Cola = new Bool[m]
    H_Rad = new Float[m]
    H_Cur = new Int[m]
    H_BestCur = new Int[m]
    ; Вставками — по убыванию cov, при равенстве дешевле раньше.
    Int filled = 0
    k = 0
    While k < n
        If cov[k] > 0.0
            Float cst = CostOf(k)
            Int j = filled
            While j > 0 && (H_Cov[j - 1] < cov[k] || (H_Cov[j - 1] == cov[k] && H_Cost[j - 1] > cst))
                H_K[j] = H_K[j - 1]
                H_Cov[j] = H_Cov[j - 1]
                H_Pen[j] = H_Pen[j - 1]
                H_Cost[j] = H_Cost[j - 1]
                H_Left[j] = H_Left[j - 1]
                H_Pool[j] = H_Pool[j - 1]
                H_Cola[j] = H_Cola[j - 1]
                H_Rad[j] = H_Rad[j - 1]
                j -= 1
            EndWhile
            H_K[j] = k
            H_Cov[j] = cov[k]
            H_Pen[j] = K_RadIn[k] * hpr
            H_Cost[j] = cst
            H_Left[j] = LeftOf(k)
            H_Pool[j] = H_HasPool && K_InPool[k]
            H_Cola[j] = H_HasCola && K_InCola[k]
            H_Rad[j] = K_RadIn[k]
            filled += 1
        EndIf
        k += 1
    EndWhile

    H_Rem = rem
    H_Goal = rem - tol
    H_BestCls = -1
    H_Nodes = 0
    Float t0 = Utility.GetCurrentRealTime()
    HealSearch(0, 0.0, 0.0, 0, 0.0, 0, 0, 0.0)
    Float ms = (Utility.GetCurrentRealTime() - t0) * 1000.0
    If H_BestCls < 0
        Return
    EndIf

    Int i = 0
    If LOG_LEVEL >= LOG_TRACE
        String picked = ""
        While i < m
            If H_BestCur[i] > 0
                picked = Join(picked, CandName(H_K[i]) + " x" + H_BestCur[i])
            EndIf
            i += 1
        EndWhile
        String cls = "добран"
        If H_BestCls == 1
            cls = "НЕДОБОР"
        EndIf
        P_Trace = P_Trace + "\n         HEAL   " + asStage + " rem " + R0(rem) + ": " + picked + \
            "  (" + cls + ", потери " + R1(H_BestW) + " ОЗ; из " + m + " видов, " + H_Nodes + \
            " узлов, " + R0(ms) + " мс)"
    EndIf
    i = 0
    While i < m
        Int c = 0
        While c < H_BestCur[i]
            If !AddEntry(H_K[i], NEED_HP, Gain(H_K[i], NEED_HP, HPShortfall(-1)))
                Return
            EndIf
            c += 1
        EndWhile
        i += 1
    EndWhile
    ; Недобор: объяснить в UNMET, чем он упёрся.
    If H_BestCls == 1
        If H_BestN >= H_Slots
            P_LimitHit = true
        EndIf
        If H_HasPool || H_HasCola
            i = 0
            While i < m
                If H_Pool[i] || H_Cola[i]
                    P_ReserveHit = true
                EndIf
                i += 1
            EndWhile
        EndIf
    EndIf
EndFunction

String Function ApModeName(Int aiMode)
    If aiMode == 0
        Return "никогда"
    ElseIf aiMode == 2
        Return "всегда"
    EndIf
    Return "в бою"
EndFunction

; Положительное x вверх до целого (Math.Ceiling — нативный вызов, а это
; внутренний цикл перебора).
Int Function CeilPos(Float afX)
    Int r = afX as Int
    If (r as Float) < afX
        r += 1
    EndIf
    Return r
EndFunction

Bool Function HealBetter(Int aiCls, Float afW, Int aiN, Float afCost)
    If H_BestCls < 0
        Return true
    EndIf
    If aiCls != H_BestCls
        Return aiCls < H_BestCls
    EndIf
    If afW > H_BestW + HEAL_EPS
        Return false
    EndIf
    If afW < H_BestW - HEAL_EPS
        Return true
    EndIf
    If aiN != H_BestN
        Return aiN < H_BestN
    EndIf
    Return afCost < H_BestCost - 0.01
EndFunction

Function HealOffer(Float afTotal, Float afPen, Int aiN, Float afCost)
    If aiN == 0
        Return
    EndIf
    Int cls = 1
    Float w = H_Rem - afTotal + afPen
    If afTotal >= H_Goal
        cls = 0
        w = afPen
        If afTotal > H_Rem
            w += afTotal - H_Rem
        EndIf
    EndIf
    If HealBetter(cls, w, aiN, afCost)
        H_BestCls = cls
        H_BestW = w
        H_BestN = aiN
        H_BestCost = afCost
        Int i = 0
        While i < H_Cur.Length
            H_BestCur[i] = H_Cur[i]
            i += 1
        EndWhile
    EndIf
EndFunction

; Перебор с отсечениями: тип i берётся 0..top штук, где top — сколько нужно,
; чтобы добрать (больше — только лишнее перелечение). Первым проходится
; «крупными штуками», так что даже при исчерпании бюджета набор есть.
Function HealSearch(Int i, Float afTotal, Float afPen, Int aiN, Float afCost, Int aiPool, Int aiCola, Float afRads)
    H_Nodes += 1
    If i >= H_K.Length || aiN >= H_Slots || H_Nodes > HEAL_NODE_BUDGET
        HealOffer(afTotal, afPen, aiN, afCost)
        Return
    EndIf
    Float c = H_Cov[i]
    If H_BestCls == 0
        ; Добранный набор уже есть: ветка, которая не может его обойти, не нужна.
        Float lb = afPen
        If afTotal > H_Rem
            lb += afTotal - H_Rem
        EndIf
        If lb > H_BestW + HEAL_EPS
            Return
        EndIf
        ; Типы идут по убыванию cov: добрать — не меньше more штук.
        Int more = 1
        If afTotal < H_Goal
            more = CeilPos((H_Goal - afTotal) / c)
        EndIf
        If aiN + more > H_Slots
            Return
        EndIf
        If lb >= H_BestW - HEAL_EPS && aiN + more > H_BestN
            Return
        EndIf
    EndIf
    Int mx = H_Left[i]
    If mx > H_Slots - aiN
        mx = H_Slots - aiN
    EndIf
    If H_Pool[i] && mx > H_PoolRoom - aiPool
        mx = H_PoolRoom - aiPool
    EndIf
    If H_Cola[i] && mx > H_ColaRoom - aiCola
        mx = H_ColaRoom - aiCola
    EndIf
    Float r = H_Rad[i]
    If r > 0.0
        Float room = H_RadRoom - afRads
        If H_HasCap && H_RadCap - afRads - 0.001 < room
            room = H_RadCap - afRads - 0.001
        EndIf
        Int byRad = 0
        If room > 0.0
            byRad = (room / r) as Int
        EndIf
        If mx > byRad
            mx = byRad
        EndIf
    EndIf
    If mx < 0
        mx = 0
    EndIf
    Int top = 0
    If afTotal < H_Goal
        top = CeilPos((H_Goal - afTotal) / c)
    EndIf
    If top > mx
        top = mx
    EndIf
    Int k = top
    While k >= 0
        H_Cur[i] = k
        Float kf = k as Float
        Float tot = afTotal + kf * c
        If k > 0 && tot >= H_Goal
            H_Nodes += 1
            HealOffer(tot, afPen + kf * H_Pen[i], aiN + k, afCost + kf * H_Cost[i])
        Else
            Int pl = aiPool
            If H_Pool[i]
                pl += k
            EndIf
            Int cl = aiCola
            If H_Cola[i]
                cl += k
            EndIf
            HealSearch(i + 1, tot, afPen + kf * H_Pen[i], aiN + k, afCost + kf * H_Cost[i], pl, cl, afRads + kf * r)
        EndIf
        k -= 1
    EndWhile
    H_Cur[i] = 0
EndFunction

; §4.3: по одной выбрасываем строку плана, без которой ни одна нужда не
; становится хуже (в пределах допуска). Из таких — самую дорогую; повторяем,
; пока есть что выбросить. Строки под конечности, болезни и зависимости не
; трогаются: их нужда — не число, а факт.
Function Trim()
    Float tolHP = HPTolerance()
    Bool removed = true
    While removed
        removed = false
        Float baseHP = Math.Max(HPShortfall(-1), tolHP)
        Float baseRad = Math.Max(RadShortfall(-1), RAD_TOLERANCE)
        Int drop = -1
        Float dropCost = 0.0
        Int e = 0
        While e < P_K.Length
            If P_For[e] == NEED_HP || P_For[e] == NEED_RADS
                If HPShortfall(e) <= baseHP + 0.01 && RadShortfall(e) <= baseRad + 0.01
                    If drop < 0 || P_Cost[e] > dropCost
                        drop = e
                        dropCost = P_Cost[e]
                    EndIf
                EndIf
            EndIf
            e += 1
        EndWhile
        If drop >= 0
            P_Trim = Join(P_Trim, CandName(P_K[drop]) + " x1 [" + NeedName(P_For[drop]) + \
                "] (избыточен: нужды покрыты остальными, cost " + R1(dropCost) + ")")
            P_K.Remove(drop)
            P_For.Remove(drop)
            P_Gain.Remove(drop)
            P_Cost.Remove(drop)
            removed = true
        EndIf
    EndWhile
EndFunction

; Фаза исполнения строки плана по таблице §4.4 (для строки ORDER).
; Еда (M4) идёт после цикла по голоду — иначе она не подействует.
Int Function PhaseOf(Int e)
    Int need = P_For[e]
    If need == NEED_LIMBS
        Return 1
    ElseIf need == NEED_RADS && !K_AfterFood[P_K[e]]
        Return 2
    ElseIf need == NEED_DISEASE || need == NEED_ADDICTION
        Return 6
    EndIf
    Return 5
EndFunction

; =====================================================================
;  Фаза 4 — отчёт (§4.5, формат §6.3)
; =====================================================================

Function LogHeader(String asTrigger)
    String mode = ""
    If E_DryRun
        mode = ", dry-run"
    EndIf
    LogAt(LOG_SUMMARY, "[" + GardenOfEden2.GetCurrentDateAndTimeAsString() + "] === AutoMedic cycle #" + \
        AM_Cycle + " (trigger: " + asTrigger + mode + \
        ", game day " + R1(Utility.GetCurrentGameTime()) + ") ===")
EndFunction

Function WriteReport(Actor akPlayer)
    If LOG_LEVEL < LOG_SUMMARY
        Return
    EndIf

    String limbs = "OK"
    If S_CrippledCount > 0
        limbs = S_Crippled
    EndIf
    String diseases = "none"
    If S_DiseaseCount > 0
        diseases = S_Diseases
    EndIf
    String addictions = "none"
    If S_AddictionCount > 0
        addictions = S_Addictions
    EndIf

    Log("  STATE  HP " + R0(S_HP) + "/" + R0(S_MaxHP) + " (" + R0(S_HPPct * 100.0) + \
        "% raw, base " + R0(S_HPBase) + ", effMax " + R0(N_EffMaxNow) + " at " + R0(S_Rads) + \
        " rad)  Rads " + R1(S_Rads) + "  Hunger " + R1(S_Hunger) + "/" + HungerName(S_Hunger) + \
        "  Thirst " + R1(S_Thirst) + "/" + ThirstName(S_Thirst))
    Log("         AP " + R0(S_AP) + " (" + R0(S_APPct * 100.0) + "%)  Sleep " + R1(S_Sleep) + \
        "/" + SleepName(S_Sleep) + "  OverEncumbered " + S_OverEncumbered + "  PowerArmor " + S_InPowerArmor + \
        "  Survival " + S_Survival)
    Log("         Limbs: " + limbs + "  Disease: " + diseases + "  Addict: " + addictions)
    Log("         Immunodef " + S_Immuno + "  RadX " + S_RadX + "  Antirad active " + \
        S_AntiradActive + "  Herbals: " + S_Herbals)
    If LOG_LEVEL >= LOG_TRACE && VERIFY_STATUS
        Log("         Status check (HasMagicEffect/HasSpell): " + S_StatusCheck)
    EndIf
    Log("         InFlight: heal " + R1(S_InHeal) + " HP (stimpak " + R1(S_InHealPct) + "), " + \
        "damage " + R1(S_InDamage) + ", rad out " + R1(S_InRadOut) + ", rad in " + \
        R1(S_InRadIn) + ", AP " + R1(S_InAP) + "  (effects " + S_EffectsTotal + ")")
    Log("         Perks: Medic " + S_Medic + ", LeadBelly " + S_LeadBelly + \
        ", Adamantium " + S_Adamantium + ", ChemResistant " + S_ChemResistant + \
        ", PartyBoy " + S_PartyBoy + ", Aquaboy " + S_Aquaboy + \
        ", Bobblehead Medicine " + S_BobbleMedicine)

    Log("  NEED   hp=" + R0(N_HP) + " (" + R0(N_HPPctEff) + "% of effMax after rads " + \
        R0(N_EffMaxAfter) + ")  rads=" + R0(N_Rads) + "  hunger=" + R1(N_Hunger) + \
        "  thirst=" + R1(N_Thirst) + "  limbs=" + N_Limbs + "  disease=" + N_Disease + \
        "  addiction=" + N_Addiction + "  ap=" + N_AP)

    If LOG_LEVEL >= LOG_DETAILED
        WriteCandidates(akPlayer)
        WritePlan()
    EndIf

EndFunction

Function WriteCandidates(Actor akPlayer)
    If N_Uses == 0
        Log("  CANDS  нужд нет — инвентарь не читался")
        Return
    EndIf
    Log("  CANDS  ALCH в инвентаре " + C_Total + ": кандидатов " + K_Forms.Length + \
        ", не нужны сейчас " + C_Idle + ", исключено " + C_Excluded + \
        ", вне таблицы " + C_Unknown + " (вкл. сам AutoMedic)  |  hp " + C_HPCount + \
        ", rads " + C_RadsCount + ", limbs " + C_LimbsCount + ", hunger " + C_HungerCount + \
        ", thirst " + C_ThirstCount + ", disease " + C_DiseaseCount + ", addict " + \
        C_AddictionCount + ", ap " + C_APCount)
    If !C_HungerWillClose
        Log("         M4: голод закрыть нечем — еда не подействует, в план не берётся")
    EndIf
    If LOG_LEVEL < LOG_TRACE
        Return
    EndIf
    Int k = 0
    While k < K_Forms.Length
        String line = "         " + CandName(k) + " x" + K_Counts[k] + " (" + K_Values[k] + "c"
        If K_Avail[k] < K_Counts[k]
            line += ", свободно " + K_Avail[k]
        EndIf
        If K_Heal[k] > 0.0
            line += ", +" + R0(K_Heal[k]) + " HP"
        EndIf
        If K_RadOut[k] > 0.0
            line += ", -" + R0(K_RadOut[k]) + " rad"
        EndIf
        If K_RadIn[k] > 0.0
            line += ", +" + R1(K_RadIn[k]) + " rad"
        EndIf
        If K_Risk[k] > 0
            line += ", risk " + K_Risk[k] + "%"
        EndIf
        If K_Dead[k]
            line += ", M4: не подействует"
        ElseIf K_AfterFood[k]
            line += ", после голода"
        EndIf
        Log(line + ", cost " + R1(CostOf(k)) + ")")
        k += 1
    EndWhile
    If X_Forms.Length > 0
        String excluded = ""
        Int x = 0
        While x < X_Forms.Length
            excluded = Join(excluded, SlotName(akPlayer, X_Forms[x], CheckedSlot(akPlayer, X_Forms[x], X_Slots[x])) + " (" + X_Why[x] + ")")
            x += 1
        EndWhile
        Log("         исключены: " + excluded)
    EndIf
EndFunction

; Строки плана одной нужды, сведённые по предмету: "Stimpak x2 (+850 HP)".
String Function PlanLines(Int aiNeed)
    String out = ""
    Int[] seen = new Int[0]
    Int e = 0
    While e < P_K.Length
        If P_For[e] == aiNeed && seen.Find(P_K[e]) < 0
            Int k = P_K[e]
            seen.Add(k)
            Int qty = 0
            Int j = e
            While j < P_K.Length
                If P_K[j] == k && P_For[j] == aiNeed
                    qty += 1
                EndIf
                j += 1
            EndWhile
            String what = ""
            If K_RadOut[k] > 0.0
                what = Join(what, "-" + R0(K_RadOut[k] * qty) + " rad")
            EndIf
            If K_Heal[k] > 0.0
                what = Join(what, "+" + R0(K_Heal[k] * qty) + " HP")
            EndIf
            If K_RadIn[k] > 0.0
                what = Join(what, "+" + R1(K_RadIn[k] * qty) + " rad")
            EndIf
            If K_Risk[k] > 0
                what = Join(what, "risk " + K_Risk[k] + "%")
            EndIf
            ; Цена на момент выбора: пересчёт после плана дал бы скидку за
            ; иммунодефицит от самого же этого предмета (RadAway 145 -> 100).
            what = Join(what, "cost " + R1(P_Cost[e]))
            out = Join(out, CandName(k) + " x" + qty + " (" + what + ")")
        EndIf
        e += 1
    EndWhile
    Return out
EndFunction

Function WritePlanNeed(String asLabel, Int aiNeed, Bool abWanted)
    If !abWanted
        Return
    EndIf
    String lines = PlanLines(aiNeed)
    If lines == ""
        lines = "-"
    EndIf
    Log("         " + asLabel + " <- " + lines)
EndFunction

Function WritePlan()
    Log("  PLAN   (" + P_K.Length + " шт.; голод и жажда — циклы исполнения)" + P_Trace)
    WritePlanNeed("rads  ", NEED_RADS, N_Rads > 0.0 || PlanLines(NEED_RADS) != "")
    WritePlanNeed("limbs ", NEED_LIMBS, N_Limbs > 0)
    WritePlanNeed("disease", NEED_DISEASE, N_Disease > 0)
    WritePlanNeed("addict", NEED_ADDICTION, N_Addiction > 0)
    WritePlanNeed("hp    ", NEED_HP, N_HP > 0.0 || PlanLines(NEED_HP) != "")
    If N_Hunger > 0.0
        String h = "нечем"
        If C_HungerCheapest >= 0
            h = C_HungerCount + " кандидатов, дешевле всего " + CandName(C_HungerCheapest) + \
                " (" + K_Values[C_HungerCheapest] + "c)"
        EndIf
        Log("         hunger <- цикл: " + h)
    EndIf
    If N_Thirst > 0.0
        String t = "нечем"
        If C_ThirstCheapest >= 0
            t = C_ThirstCount + " кандидатов, дешевле всего " + CandName(C_ThirstCheapest) + \
                " (" + K_Values[C_ThirstCheapest] + "c)"
        EndIf
        Log("         thirst <- цикл: " + t)
    EndIf
    If P_Notes != ""
        Log("         note: " + P_Notes)
    EndIf
    If P_Trim != ""
        Log("  TRIM   dropped: " + P_Trim)
    Else
        Log("  TRIM   ничего")
    EndIf
    Totals(-1)
    Float hpNeed = NeedHPGiven(T_RadOut, T_RadIn)
    Float radNeed = NeedRads(T_RadIn)
    Log("  COVER  hp " + R0(Math.Min(T_Heal, hpNeed)) + "/" + R0(hpNeed) + " (потолок после плана " + \
        R0(EffMax(T_RadOut, T_RadIn)) + ", лечение плана " + R0(T_Heal) + ")  rads " + \
        R0(Math.Min(T_RadOut, radNeed)) + "/" + R0(radNeed) + " (вывод плана " + R0(T_RadOut) + \
        ", съедено +" + R1(T_RadIn) + ")")
    Log("  ORDER  " + OrderText())
EndFunction

; Порядок приёма по §4.4: 1 конечности, 2 вывод радиации, 3-4 циклы голода
; и жажды, 5 добор ОЗ (и всё, что M4 велит есть сытым), 6 болезни и зависимости.
String Function OrderText()
    String out = ""
    Int step = 0
    Int phase = 1
    While phase <= 6
        If phase == 3
            If N_Hunger > 0.0
                step += 1
                out = Join(out, step + ". голод (цикл)")
            EndIf
        ElseIf phase == 4
            If N_Thirst > 0.0
                step += 1
                out = Join(out, step + ". жажда (цикл)")
            EndIf
        Else
            Int e = 0
            While e < P_K.Length
                If PhaseOf(e) == phase
                    step += 1
                    out = Join(out, step + ". " + CandName(P_K[e]) + " [" + NeedName(P_For[e]) + "]")
                EndIf
                e += 1
            EndWhile
        EndIf
        phase += 1
    EndWhile
    If out == ""
        Return "ничего"
    EndIf
    Return out
EndFunction

; §6.3 / решение 7: только факт — какая нужда осталась и почему её нечем закрыть.
String Function UnmetText()
    String out = ""
    Totals(-1)
    Float hpLeft = HPShortfall(-1)
    If hpLeft > HPTolerance()
        String why = "нечем лечить"
        If P_LimitHit
            why = "лимит " + MAX_PLAN_ITEMS + " предметов"
        ElseIf P_ReserveHit
            why = "осталось только в запасе (еда " + FOOD_RESERVE + ", кола " + COLA_RESERVE + ")"
        ElseIf C_HPCount > 0
            why = "лечения в инвентаре не хватило"
        EndIf
        out = Join(out, "hp (" + R0(hpLeft) + " осталось): " + why)
    EndIf
    If N_Limbs > 0 && S_InHealPct <= 0.0 && P_For.Find(NEED_LIMBS) < 0
        String why = "нет стимпака"
        If !ALLOW_STIMPAK
            why = "стимпаки выключены в MCM"
        ElseIf C_LimbsCount > 0
            why = "стимпаки в резерве (" + RESERVE_STIMPAKS + ")"
        EndIf
        out = Join(out, "limbs (" + N_Limbs + "): " + why)
    EndIf
    Float radLeft = RadShortfall(-1)
    If radLeft > RAD_TOLERANCE
        String why = "нет средств вывода радиации"
        If P_LimitHit
            why = "лимит " + MAX_PLAN_ITEMS + " предметов"
        ElseIf P_RadsUnprofitable
            why = "остальное невыгодно (балл ниже " + R1(MIN_SCORE_RADS) + ")"
        ElseIf P_ReserveHit && C_RadsCount > 0
            why = "рад-еда осталась только в запасе (" + FOOD_RESERVE + " шт.)"
        ElseIf C_RadsCount > 0
            why = "средств вывода не хватило"
        EndIf
        out = Join(out, "rads (" + R0(radLeft) + " осталось): " + why)
    EndIf
    ; При исполнении голод и жажду оценивают сами циклы (E_Unmet ниже).
    If E_DryRun && N_Hunger > 0.0 && C_HungerCount == 0
        out = Join(out, "hunger: нет еды")
    EndIf
    If E_DryRun && N_Thirst > 0.0 && C_ThirstCount == 0
        out = Join(out, "thirst: нет питья")
    EndIf
    If N_Disease > 0 && P_For.Find(NEED_DISEASE) < 0
        out = Join(out, "disease: нет антибиотиков")
    EndIf
    If N_Addiction > 0 && P_For.Find(NEED_ADDICTION) < 0
        out = Join(out, "addiction: нет средств от зависимости")
    EndIf
    If !E_DryRun && E_Unmet != ""
        out = Join(out, E_Unmet)
    EndIf
    If out == ""
        Return "none"
    EndIf
    Return out
EndFunction

; Экранная сводка — одна строка вместо ливня уведомлений (§4.5).
; Исполнение: что принято и что вышло. Dry-run: что мод собирался принять.
Function Notify()
    If NOTIFY_LEVEL <= 0
        Return
    ElseIf E_DryRun
        NotifyPlan()
        Return
    EndIf
    String spent = SpentText(false)
    If AU_Mode != MODE_ITEM
        ; Авто молчит, если ничего не принял: иначе «нечего принять» каждую минуту.
        If spent != ""
            Debug.Notification("AutoMedic (авто): " + spent + " | " + AfterText())
        EndIf
        Return
    EndIf
    If spent == "" && N_Uses == 0
        Debug.Notification("AutoMedic: ничего не нужно")
        Return
    ElseIf spent == ""
        spent = "нечего принять"
    EndIf
    Debug.Notification("AutoMedic: " + spent + " | " + AfterText())
EndFunction

Function NotifyPlan()
    String items = ""
    Int[] seen = new Int[0]
    Int e = 0
    While e < P_K.Length
        Int k = P_K[e]
        If seen.Find(k) < 0
            seen.Add(k)
            Int qty = Planned(k)
            String name = CandName(k)
            If qty > 1
                name += " x" + qty
            EndIf
            items = Join(items, name)
        EndIf
        e += 1
    EndWhile
    String loops = ""
    If N_Hunger > 0.0
        loops = Join(loops, "голод " + R0(S_Hunger))
    EndIf
    If N_Thirst > 0.0
        loops = Join(loops, "жажда " + R0(S_Thirst))
    EndIf
    String text = items
    If loops != ""
        text = Join(text, loops)
    EndIf
    If text == ""
        text = "ничего не нужно"
    EndIf
    Debug.Notification("AutoMedic [план]: " + text)
EndFunction

; Принятое за цикл, по предмету: "-2 Tato, -1 Stimpak".
String Function SpentText(Bool abWithCaps)
    String out = ""
    Int caps = 0
    Int k = 0
    While k < E_Used.Length
        If E_Used[k] > 0
            out = Join(out, "-" + E_Used[k] + " " + CandName(k))
            caps += E_Used[k] * K_Values[k]
        EndIf
        k += 1
    EndWhile
    If abWithCaps && out != ""
        out += "  (" + caps + " крышек)"
    EndIf
    Return out
EndFunction

Function WriteOutcome(Actor akPlayer)
    If E_DryRun
        LogAt(LOG_SUMMARY, "  SPENT  ничего (dry-run)")
        LogAt(LOG_SUMMARY, "  UNMET  " + UnmetText())
        Return
    EndIf
    ReadAfter(akPlayer)
    If LOG_LEVEL >= LOG_SUMMARY
        Log("  AFTER  " + AfterText())
        String spent = SpentText(true)
        If spent == ""
            spent = "ничего"
        EndIf
        Log("  SPENT  " + spent)
        Log("  UNMET  " + UnmetText())
    EndIf
EndFunction

; Состояние после исполнения. Ничего не принято — это снимок фазы 0.
Function ReadAfter(Actor akPlayer)
    If E_Step == 0
        A_HP = S_HP
        A_Rads = S_Rads
        A_Hunger = S_Hunger
        A_Thirst = S_Thirst
        A_InHeal = S_InHeal - S_InDamage
        A_InRadOut = S_InRadOut
        A_Crippled = S_CrippledCount
        A_MaxHP = S_MaxHP
        Return
    EndIf
    ScanInFlight(akPlayer)
    A_HP = akPlayer.GetValue(AV_Health)
    A_Rads = akPlayer.GetValue(AV_Rads)
    A_Hunger = akPlayer.GetValue(AV_Hunger)
    A_Thirst = akPlayer.GetValue(AV_Thirst)
    A_InHeal = F_Heal
    A_InRadOut = F_RadOut
    A_MaxHP = CurrentMaxHP(akPlayer)
    A_Crippled = 0
    Int i = 0
    While i < AV_Limbs.Length
        If akPlayer.GetValue(AV_Limbs[i]) <= 0.0
            A_Crippled += 1
        EndIf
        i += 1
    EndWhile
EndFunction

; "HP 300/420 (+120 в полёте), Rads 40 (-200 в полёте), Fed, Hydrated".
; Потолок — максимум ОЗ при текущей радиации (M1).
String Function AfterText()
    Float effMax = A_MaxHP * (1.0 - A_Rads / RADS_MAX)
    String out = "HP " + R0(A_HP) + "/" + R0(effMax)
    If A_InHeal > 0.5
        out += " (+" + R0(A_InHeal) + " в полёте)"
    EndIf
    out += ", Rads " + R0(A_Rads)
    If A_InRadOut > 0.5
        out += " (-" + R0(A_InRadOut) + " в полёте)"
    EndIf
    out += ", " + HungerName(A_Hunger) + ", " + ThirstName(A_Thirst)
    If A_Crippled > 0
        out += ", покалечено: " + A_Crippled
    EndIf
    Return out
EndFunction

; =====================================================================
;  Фаза 3 — исполнение (§4.4)
; =====================================================================

; Порядок §4.4 отличается от порядка планирования:
;   1 стимпак на конечности и 2 вывод радиации (не еда) — первыми: стимпак
;     вызывает жажду, RadAway — голод (M8), их снимут циклы 3-4;
;   3 цикл по голоду, 4 цикл по жажде — замкнутые (§1.1): принял -> дождался
;     смены стадии -> решил, нужно ли ещё. Величины насыщения не нужны;
;   5 добор ОЗ и всё, что M4 велит есть сытым, — с перепроверкой нужды;
;   6 болезни и зависимости.
; Применение — только EquipItem(item, false, true): GardenOfEden.DrinkPotion
; накладывает эффект, но не тратит предмет, и Survival его не засчитывает
; (шаг 4, A16).
Function Execute(Actor akPlayer)
    ExecutePhase(akPlayer, 1, 0)
    ExecutePhase(akPlayer, 2, 0)
    If E_Step > 0
        ; Голод от RadAway и жажду от стимпака HC_Manager засчитывает
        ; асинхронно — циклы должны увидеть уже новую стадию.
        Utility.WaitMenuMode(SETTLE_WAIT)
    EndIf
    RunLoop(akPlayer, USE_HUNGER, AV_Hunger, HUNGER_TRIGGER, HUNGER_TARGET, "hunger")
    RunLoop(akPlayer, USE_THIRST, AV_Thirst, THIRST_TRIGGER, THIRST_TARGET, "thirst")
    ; Рад-еда (M4 — только сытым) ещё и лечит: её — до перепроверки ОЗ.
    ExecutePhase(akPlayer, 5, NEED_RADS)
    ExecuteHealth(akPlayer)
    ExecutePhase(akPlayer, 6, 0)
EndFunction

Function InitExecution()
    Int n = K_Forms.Length
    E_Used = new Int[n]
    E_Bad = new Bool[n]
    E_Done = new Bool[P_K.Length]
    E_Step = 0
    E_LoopRadIn = 0.0
    E_Unmet = ""
EndFunction

Function UseLine(String asText)
    E_Step += 1
    LogAt(LOG_DETAILED, "  USE    " + E_Step + ". " + asText)
EndFunction

Function SkipLine(String asText)
    LogAt(LOG_DETAILED, "  SKIP   " + asText)
EndFunction

; Строка плана не исполнена — это и в UNMET.
Function Skip(Int e, String asWhy)
    Int k = P_K[e]
    SkipLine(CandName(k) + " [" + NeedName(P_For[e]) + "]: " + asWhy)
    E_Unmet = Join(E_Unmet, NeedName(P_For[e]) + ": " + CandName(k) + " не принят — " + asWhy)
EndFunction

; Строки плана фазы aiPhase (и нужды aiNeed, если не 0).
Function ExecutePhase(Actor akPlayer, Int aiPhase, Int aiNeed)
    Int e = 0
    While e < P_K.Length
        If !E_Done[e] && PhaseOf(e) == aiPhase && (aiNeed == 0 || P_For[e] == aiNeed)
            ApplyEntry(akPlayer, e)
        EndIf
        e += 1
    EndWhile
EndFunction

Bool Function ApplyEntry(Actor akPlayer, Int e)
    E_Done[e] = true
    Int k = P_K[e]
    ; M4: еда, съеденная голодным, не даёт ничего — ни лечения, ни вывода
    ; радиации, ни излечения зависимости. Цикл голода мог не довести до Fed.
    If K_AfterFood[k] && akPlayer.GetValue(AV_Hunger) >= 0.5
        Skip(e, "M4: голод не закрыт, еда не подействует")
        Return false
    EndIf
    If FOOD_RESERVE > 0 && K_InPool[k] && FoodPoolLeft() - 1 < FOOD_RESERVE
        Skip(e, "запас еды: осталось " + FoodPoolLeft() + ", держим " + FOOD_RESERVE)
        Return false
    EndIf
    If COLA_RESERVE > 0 && K_InCola[k] && ColaPoolLeft() - 1 < COLA_RESERVE
        Skip(e, "запас колы: осталось " + ColaPoolLeft() + ", держим " + COLA_RESERVE)
        Return false
    EndIf
    If !Consume(akPlayer, k)
        Skip(e, "не применился (нет в инвентаре или EquipItem отказал)")
        Return false
    EndIf
    String what = ""
    If K_Heal[k] > 0.0
        what = Join(what, "+" + R0(K_Heal[k]) + " HP")
    EndIf
    If K_RadOut[k] > 0.0
        what = Join(what, "-" + R0(K_RadOut[k]) + " rad")
    EndIf
    If K_RadIn[k] > 0.0
        what = Join(what, "+" + R1(K_RadIn[k]) + " rad")
    EndIf
    String label = NeedName(P_For[e])
    If P_For[e] == NEED_LIMBS && K_Heal[k] > 0.0
        label = "limbs+hp"
    EndIf
    If what != ""
        what = "  [" + what + "]"
    EndIf
    UseLine(CandName(k) + " -> " + label + what)
    Return true
EndFunction

; Принять одну штуку кандидата k и дождаться, пока она уйдёт из инвентаря.
; Заодно продлевает занятость мода: исполнение с циклами длится десятки
; секунд, а BUSY_TIMEOUT отсчитывается от последнего признака жизни.
Bool Function Consume(Actor akPlayer, Int k)
    Form item = K_Forms[k]
    Int before = akPlayer.GetItemCount(item)
    If before <= 0
        Return false
    EndIf
    ; Имя — ДО приёма: после последней штуки предмета в инвентаре нет, и по
    ; его ячейке лежит уже другой (прогон 2026-09-22 01:55: последние антибиотики
    ; записались в лог и сводку как «AutoMedic»).
    CandName(k)
    AM_BusyStart = Utility.GetCurrentRealTime()
    akPlayer.EquipItem(item, false, true)
    ; WaitMenuMode, а не Wait: нажатие из Pip-Boy не должно висеть до
    ; закрытия меню (HC_Manager тоже работает через WaitMenuMode).
    Float waited = 0.0
    While waited < CONSUME_WAIT
        If akPlayer.GetItemCount(item) < before
            E_Used[k] = E_Used[k] + 1
            Return true
        EndIf
        Utility.WaitMenuMode(0.1)
        waited += 0.1
    EndWhile
    Return false
EndFunction

String Function StageName(Int aiUse, Float afStage)
    If aiUse == USE_HUNGER
        Return HungerName(afStage)
    EndIf
    Return ThirstName(afStage)
EndFunction

; Замкнутый цикл §1.1 по голоду или жажде: самое дешёвое -> принять ->
; дождаться смены стадии -> повторить, пока стадия выше цели.
;
; Стадия — целое 0..5 (A1), а насыщение копится в скрытом пуле HC_Manager:
; предмет сдвигает пул, а стадия меняется, только когда пул перейдёт порог
; (-24/-48/-96/... у еды). «Стадия не сдвинулась» — это норма, а не признак
; плохого предмета. Прогон 2026-09-21 под SCM: вес любой еды читается как 0,
; и КАЖДЫЙ предмет даёт ровно пол стадии — еда 8, вода 18 (Hardcore.1.log).
; Первая версия исключала предмет, не сдвинувший стадию, — и в итоге пила
; грязную воду (риск 7 %) при 13 очищенных и бросала Hungry недоеденным.
; Теперь цикл встаёт, только если MAX_STALLED штук подряд не сдвинули стадию.
;
; Сначала берутся штуки, которые не нужны плану (пищевая паста из плана на
; ОЗ в G6 — иначе цикл съел бы её голодным, M4); когда кончаются — любые.
Function RunLoop(Actor akPlayer, Int aiUse, ActorValue akAV, Int aiTrigger, Int aiTarget, String asLabel)
    Float stage = akPlayer.GetValue(akAV)
    If stage < aiTrigger
        Return
    EndIf
    Int taken = 0
    Int stalled = 0
    String why = ""
    While why == "" && Math.Floor(stage + 0.5) > aiTarget
        If taken >= MAX_ITEMS_PER_NEED
            why = "лимит " + MAX_ITEMS_PER_NEED + " предметов"
        ElseIf stalled >= MAX_STALLED
            why = stalled + " штук подряд не сдвинули стадию — не насыщают"
        Else
            Int k = LoopPick(aiUse)
            If k < 0
                why = LoopEmptyReason(aiUse)
            ElseIf !Consume(akPlayer, k)
                E_Bad[k] = true
                SkipLine(CandName(k) + " [" + asLabel + "]: не применился")
            Else
                taken += 1
                E_LoopRadIn += K_RadIn[k]
                Float t0 = Utility.GetCurrentRealTime()
                Float now = WaitStage(akPlayer, akAV, stage)
                String line = CandName(k) + " -> " + asLabel + " " + R0(stage) + " -> " + R0(now) + \
                    " (" + StageName(aiUse, now) + ")"
                If now == stage
                    stalled += 1
                Else
                    stalled = 0
                    line += "  через " + Ms(t0, Utility.GetCurrentRealTime())
                EndIf
                UseLine(line)
                stage = now
            EndIf
        EndIf
    EndWhile
    If why != ""
        E_Unmet = Join(E_Unmet, asLabel + " (" + StageName(aiUse, stage) + "): " + why)
    EndIf
EndFunction

; Ждёт смены AV после приёма, не дольше STAGE_WAIT.
Float Function WaitStage(Actor akPlayer, ActorValue akAV, Float afFrom)
    Float now = akPlayer.GetValue(akAV)
    Float waited = 0.0
    While now == afFrom && waited < STAGE_WAIT
        Utility.WaitMenuMode(0.1)
        waited += 0.1
        now = akPlayer.GetValue(akAV)
    EndWhile
    Return now
EndFunction

; Кандидат для цикла или -1: сначала не нужные плану штуки, из них — самая
; дешёвая по LoopCost.
Int Function LoopPick(Int aiUse)
    Totals(-1)
    Int best = -1
    Float bestCost = 0.0
    Bool bestFree = false
    Int k = 0
    While k < K_Forms.Length
        If Has(K_Uses[k], aiUse) && !E_Bad[k] && K_Counts[k] - E_Used[k] > 0 && LoopRadsAllowed(k) && \
                !(COLA_RESERVE > 0 && K_InCola[k] && ColaPoolLeft() - 1 < COLA_RESERVE)
            Bool isFree = K_Counts[k] - E_Used[k] - PendingPlanned(k) > 0
            Float cost = LoopCost(k)
            If best < 0 || (isFree && !bestFree) || (isFree == bestFree && cost < bestCost)
                best = k
                bestCost = cost
                bestFree = isFree
            EndIf
        EndIf
        k += 1
    EndWhile
    Return best
EndFunction

; Цена штуки в цикле: крышки + риск болезни (M14) + радиация в ОЗ потолка (M1).
Float Function LoopCost(Int k)
    Float risk = K_Risk[k] * COST_PER_RISK_PCT
    If Has(K_Flags[k], TF_IMMEDIATE_CHECK)
        risk *= 2.0
    EndIf
    Return K_Values[k] + risk + K_RadIn[k] * S_MaxHP / RADS_MAX
EndFunction

; Те же правила, что RadsAllowed у плана, но с учётом съеденного циклами.
; Ждёт свежих T_* (Totals(-1) в LoopPick).
Bool Function LoopRadsAllowed(Int k)
    If K_RadIn[k] <= 0.0
        Return true
    EndIf
    Float ate = T_RadIn + E_LoopRadIn + K_RadIn[k]
    If ate > MAX_INGESTED_RADS
        Return false
    EndIf
    If RAD_CAP_WITHOUT_CURE && C_RadsCount == 0 && S_Rads + ate >= N_RadTrigger
        Return false
    EndIf
    Return true
EndFunction

; Сколько штук кандидата k ещё ждут своей строки плана.
Int Function PendingPlanned(Int k)
    Int n = 0
    Int e = 0
    While e < P_K.Length
        If P_K[e] == k && !E_Done[e]
            n += 1
        EndIf
        e += 1
    EndWhile
    Return n
EndFunction

String Function LoopEmptyReason(Int aiUse)
    Int k = 0
    While k < K_Forms.Length
        If Has(K_Uses[k], aiUse)
            Return "подходящее кончилось (съедено, лимит радиации или не применилось)"
        EndIf
        k += 1
    EndWhile
    If aiUse == USE_HUNGER
        Return "нет еды"
    EndIf
    Return "нет питья"
EndFunction

; Фаза 5: добор ОЗ. План считался до циклов, а с тех пор стимпак фазы 1 уже
; капает, вода из цикла жажды подлечила (A3: вода лечит и при жажде),
; рад-еда фазы 5 тоже. Поэтому нужда перечитывается по живым ОЗ и «в полёте»
; (с радиацией ещё не исполненных строк, M1), и строка на ОЗ, без которой
; нужда уже в пределах допуска, пропускается — обрезка §4.3 по факту.
Function ExecuteHealth(Actor akPlayer)
    Bool any = false
    Int e = 0
    While e < P_K.Length && !any
        any = !E_Done[e] && P_For[e] == NEED_HP
        e += 1
    EndWhile
    If !any
        Return
    EndIf
    Float need = RecheckHP(akPlayer)
    Float tol = HPTolerance()
    e = 0
    While e < P_K.Length
        If !E_Done[e] && P_For[e] == NEED_HP
            Int k = P_K[e]
            If need <= tol
                E_Done[e] = true
                SkipLine(CandName(k) + " [hp]: уже не нужен (нужда " + R0(need) + " <= допуск " + R0(tol) + ")")
            ElseIf ApplyEntry(akPlayer, e)
                need -= K_Heal[k]
            EndIf
        EndIf
        e += 1
    EndWhile
EndFunction

; Полный максимум ОЗ сейчас. Он меняется по ходу исполнения: голод и жажда
; в Survival режут Выносливость, и после циклов максимум растёт (прогон
; 2026-09-21: 360 при Hungry+Thirsty, 458 при Fed+Hydrated). С максимумом
; фазы 0 RECHECK недооценивал нужду, а AFTER печатал «HP 356/314».
Float Function CurrentMaxHP(Actor akPlayer)
    Float pct = akPlayer.GetValuePercentage(AV_Health)
    If pct > 0.0
        Return akPlayer.GetValue(AV_Health) / pct
    EndIf
    Return S_MaxHP
EndFunction

Float Function RecheckHP(Actor akPlayer)
    ScanInFlight(akPlayer)
    Float radOut = 0.0
    Float radIn = 0.0
    Int e = 0
    While e < P_K.Length
        If !E_Done[e]
            radOut += K_RadOut[P_K[e]]
            radIn += K_RadIn[P_K[e]]
        EndIf
        e += 1
    EndWhile
    Float hp = akPlayer.GetValue(AV_Health)
    Float rads = akPlayer.GetValue(AV_Rads) - F_RadOut - radOut + F_RadIn + radIn
    If rads < 0.0
        rads = 0.0
    EndIf
    Float maxHP = CurrentMaxHP(akPlayer)
    Float effMax = maxHP * (1.0 - rads / RADS_MAX)
    Float need = effMax * HEAL_TARGET_PCT / 100.0 - hp - F_Heal
    If need < 0.0
        need = 0.0
    EndIf
    LogAt(LOG_DETAILED, "  RECHECK hp " + R0(hp) + ", в полёте " + Signed(F_Heal) + ", максимум " + \
        R0(maxHP) + " (был " + R0(S_MaxHP) + "), потолок " + R0(effMax) + " -> нужда " + R0(need) + " (план ждал " + R0(N_HP) + ")")
    Return need
EndFunction

; Лёгкий вариант ReadActiveEffects для исполнения: только «в полёте», без
; статусов и лога. Лечение — за вычетом урона.
Function ScanInFlight(Actor akPlayer)
    F_Heal = 0.0
    F_RadOut = 0.0
    F_RadIn = 0.0
    GardenOfEden3:ActiveEffectData[] effects = GardenOfEden3.GetActiveEffects(akPlayer)
    Int i = 0
    While effects != None && i < effects.Length
        GardenOfEden3:ActiveEffectData ae = effects[i]
        If IsTimed(ae) && ae.fDuration > ae.fElapsedTime
            Int role = EffectRoleL(ae.BaseEffect)
            Float rest = ae.fMagnitude * (ae.fDuration - ae.fElapsedTime)
            If role == TR_HEAL_HP || role == TR_HEAL_HP_PCT
                F_Heal += rest
            ElseIf role == TR_DAMAGE_HP
                F_Heal -= rest
            ElseIf role == TR_RADS_REMOVE
                rest = Math.Abs(rest)
                If ae.BaseEffect == ME_RestoreRadsChem && S_BobbleMedicine
                    rest *= 1.1
                EndIf
                F_RadOut += rest
            ElseIf role == TR_RADS_ADD
                F_RadIn += rest
            EndIf
        EndIf
        i += 1
    EndWhile
EndFunction

; =====================================================================
;  Шаг 4: наблюдение после цикла (строки WATCH)
; =====================================================================

; Для проверок, где важна динамика, а не снимок: A5 (складываются ли
; одинаковые эффекты — два экземпляра или один обновлённый), A7 (скорость
; вывода радиации при двух RadAway), A9 (rads от грязной воды с Lead Belly),
; M4 (лечит ли еда на стадии Peckish), и на какие эффекты действует
; fDiffMultEffectDuration_SV = 10 (A22).
;
; WATCH_SECONDS раз в секунду: AV пишутся, только если изменились, эффекты —
; только появление (+), обновление длительности (~) и исчезновение (-).
; В меню (Pip-Boy) Utility.Wait стоит — секунды идут только в мире.
; Любое следующее нажатие обрывает наблюдение (AM_WatchToken).

Bool Function IsTimed(GardenOfEden3:ActiveEffectData akEffect)
    Return akEffect != None && akEffect.fDuration > 0.0 && akEffect.fDuration <= PERMANENT_DURATION
EndFunction

String Function EffectText(GardenOfEden3:ActiveEffectData akEffect)
    Return akEffect.BaseEffect + " src=" + akEffect.MagicItem + " mag=" + R1(akEffect.fMagnitude) + \
        " dur=" + R1(akEffect.fDuration) + " left=" + R1(akEffect.fDuration - akEffect.fElapsedTime) + \
        " role=" + EffectRoleL(akEffect.BaseEffect)
EndFunction

; Засевает список известных эффектов из снимка фазы 0, без печати.
Function WatchSeed(GardenOfEden3:ActiveEffectData[] akEffects)
    W_Keys = new String[0]
    W_Names = new String[0]
    W_Left = new Float[0]
    If akEffects == None
        Return
    EndIf
    Int i = 0
    While i < akEffects.Length && W_Keys.Length < 128
        GardenOfEden3:ActiveEffectData ae = akEffects[i]
        If IsTimed(ae)
            W_Keys.Add(ae.ActiveEffectMemoryAddress)
            W_Names.Add(ae.BaseEffect + " src=" + ae.MagicItem)
            W_Left.Add(ae.fDuration - ae.fElapsedTime)
        EndIf
        i += 1
    EndWhile
EndFunction

; Сравнивает текущие эффекты с известными и печатает разницу.
Function WatchEffects(Actor akPlayer, String asStamp)
    GardenOfEden3:ActiveEffectData[] effects = GardenOfEden3.GetActiveEffects(akPlayer)
    String[] keys = new String[0]
    String[] names = new String[0]
    Float[] lefts = new Float[0]
    If effects != None
        Int i = 0
        While i < effects.Length && keys.Length < 128
            GardenOfEden3:ActiveEffectData ae = effects[i]
            If IsTimed(ae)
                String addr = ae.ActiveEffectMemoryAddress
                Float left = ae.fDuration - ae.fElapsedTime
                Int known = W_Keys.Find(addr)
                If known < 0
                    Log(asStamp + " +EFFECT " + EffectText(ae))
                ElseIf left > W_Left[known] + 0.5
                    ; Тот же экземпляр, а остаток вырос — длительность обновили (A5).
                    Log(asStamp + " ~EFFECT " + EffectText(ae) + " (было left=" + R1(W_Left[known]) + ")")
                EndIf
                keys.Add(addr)
                names.Add(ae.BaseEffect + " src=" + ae.MagicItem)
                lefts.Add(left)
            EndIf
            i += 1
        EndWhile
    EndIf
    Int j = 0
    While j < W_Keys.Length
        If keys.Find(W_Keys[j]) < 0
            Log(asStamp + " -EFFECT " + W_Names[j])
        EndIf
        j += 1
    EndWhile
    W_Keys = keys
    W_Names = names
    W_Left = lefts
EndFunction

Function Watch(Int aiToken)
    If LOG_LEVEL < LOG_TRACE || WATCH_SECONDS <= 0
        Return
    EndIf
    Actor player = PlayerRef()
    Float t0 = Utility.GetCurrentRealTime()
    Float hp = S_HP
    Float rads = S_Rads
    Float hunger = S_Hunger
    Float thirst = S_Thirst
    Float ap = S_AP
    Log("  WATCH  " + WATCH_SECONDS + " с: пишутся только изменения. Следующее нажатие прервёт.")
    Int tick = 0
    While tick < WATCH_SECONDS && aiToken == AM_WatchToken
        Utility.Wait(1.0)
        tick += 1
        If aiToken == AM_WatchToken
            String stamp = "  WATCH  +" + R1(Utility.GetCurrentRealTime() - t0) + "s"
            Float nowHP = player.GetValue(AV_Health)
            Float nowRads = player.GetValue(AV_Rads)
            Float nowHunger = player.GetValue(AV_Hunger)
            Float nowThirst = player.GetValue(AV_Thirst)
            Float nowAP = player.GetValue(AV_AP)
            String line = ""
            If Math.Abs(nowHP - hp) >= 0.1
                line += " HP " + R1(hp) + "->" + R1(nowHP) + " (" + Signed(nowHP - hp) + ")"
            EndIf
            If Math.Abs(nowRads - rads) >= 0.05
                line += " Rads " + R1(rads) + "->" + R1(nowRads) + " (" + Signed(nowRads - rads) + ")"
            EndIf
            If nowHunger != hunger
                line += " Hunger " + R1(hunger) + "->" + R1(nowHunger)
            EndIf
            If nowThirst != thirst
                line += " Thirst " + R1(thirst) + "->" + R1(nowThirst)
            EndIf
            If Math.Abs(nowAP - ap) >= 1.0
                line += " AP " + R0(ap) + "->" + R0(nowAP)
            EndIf
            If line != ""
                Log(stamp + line)
            EndIf
            hp = nowHP
            rads = nowRads
            hunger = nowHunger
            thirst = nowThirst
            ap = nowAP
            WatchEffects(player, stamp)
            FlushLog()
        EndIf
    EndWhile
    If aiToken == AM_WatchToken
        Log("  WATCH  конец")
    Else
        Log("  WATCH  прервано новым нажатием")
    EndIf
    FlushLog()
EndFunction

; =====================================================================
;  Шаг 4: тест A16 — чем применять предметы (AM_TestMode = 1)
; =====================================================================

; Самая дешёвая вода из инвентаря выпивается дважды: сначала через
; GardenOfEden.DrinkPotion, через 3 с — через Actor.EquipItem(item, false, true).
; Главный вопрос не «исчезла ли штука», а «засчитал ли её Survival»:
; HC_Manager ловит еду только в OnItemEquipped. Ответ — в Hardcore.0.log
; (строка «Adding Food Item» на каждое засчитанное применение); здесь пишется
; время, счётчик, жажда и эффекты от этого предмета.
; НЕ ПЕРЕИМЕНОВЫВАТЬ: вызывается по имени через CallFunctionNoWait.
Function RunConsumeTest()
    If !TryBusy()
        Return
    EndIf
    Actor player = PlayerRef()
    Log("=== AutoMedic test A16 (game day " + R1(Utility.GetCurrentGameTime()) + \
        ", PowerArmor " + player.IsInPowerArmor() + ") ===")
    ReadValues(player)
    N_Uses = 0
    CollectCandidates(player, USE_THIRST)
    EvalCandidates()
    If C_ThirstCheapest < 0
        Log("  A16 нет ни одного предмета, утоляющего жажду")
        Debug.Notification("AutoMedic A16: нет воды в инвентаре")
        FlushLog()
        AM_Busy = false
        Return
    EndIf
    Form item = K_Forms[C_ThirstCheapest]
    Log("  A16 предмет: " + item + " (" + K_Values[C_ThirstCheapest] + "c)")
    ConsumeProbe(player, item, true)
    Utility.Wait(3.0)
    ConsumeProbe(player, item, false)
    Log("  A16 готово — сверить с Hardcore.0.log: сколько раз там Adding Food Item")
    Debug.Notification("AutoMedic A16: готово, см. лог")
    FlushLog()
    AM_Busy = false
EndFunction

Int Function EffectsFrom(Actor akPlayer, Form akItem)
    GardenOfEden3:ActiveEffectData[] effects = GardenOfEden3.GetActiveEffects(akPlayer)
    Int n = 0
    Int i = 0
    While effects != None && i < effects.Length
        If effects[i] != None && effects[i].MagicItem == akItem
            n += 1
        EndIf
        i += 1
    EndWhile
    Return n
EndFunction

Function ConsumeProbe(Actor akPlayer, Form akItem, Bool abDrinkPotion)
    String method = "Actor.EquipItem"
    If abDrinkPotion
        method = "GardenOfEden.DrinkPotion"
    EndIf
    Int before = akPlayer.GetItemCount(akItem)
    Float thirst0 = akPlayer.GetValue(AV_Thirst)
    Float hp0 = akPlayer.GetValue(AV_Health)
    Int fx0 = EffectsFrom(akPlayer, akItem)
    Float t0 = Utility.GetCurrentRealTime()
    If abDrinkPotion
        GardenOfEden.DrinkPotion(akPlayer, akItem as Potion)
    Else
        akPlayer.EquipItem(akItem, false, true)
    EndIf
    Float tCall = Utility.GetCurrentRealTime()
    ; До 3 с ждём, пока уйдёт штука и сменится жажда (HC_Manager
    ; обрабатывает еду асинхронно, через очередь и CallFunctionNoWait).
    ; Флаги, а не «-1.0 = ещё нет»: `Float x = -1.0` роняет оптимизатор
    ; PapyrusCompiler («входная строка имела неверный формат»), `0.0 - 1.0`
    ; он сворачивает в ту же константу.
    Bool gone = false
    Bool thirstMoved = false
    Float tGone = 0.0
    Float tThirst = 0.0
    Int after = before
    Float thirst = thirst0
    Int n = 0
    While n < 30 && (!gone || !thirstMoved)
        Utility.Wait(0.1)
        n += 1
        If !gone
            after = akPlayer.GetItemCount(akItem)
            If after < before
                gone = true
                tGone = Utility.GetCurrentRealTime() - t0
            EndIf
        EndIf
        If !thirstMoved
            thirst = akPlayer.GetValue(AV_Thirst)
            If thirst != thirst0
                thirstMoved = true
                tThirst = Utility.GetCurrentRealTime() - t0
            EndIf
        EndIf
    EndWhile
    Int fx = EffectsFrom(akPlayer, akItem)
    String goneText = "не ушла за 3 с"
    If gone
        goneText = "через " + R0(tGone * 1000.0) + " мс"
    EndIf
    String thirstText = "не менялась за 3 с"
    If thirstMoved
        thirstText = R1(thirst0) + "->" + R1(thirst) + " через " + R0(tThirst * 1000.0) + " мс"
    EndIf
    Log("  A16 " + method + ": вызов " + Ms(t0, tCall) + ", штук " + before + "->" + after + \
        " (" + goneText + "), жажда " + thirstText + ", эффектов от предмета " + fx0 + "->" + fx + \
        ", HP " + R1(hp0) + "->" + R1(akPlayer.GetValue(AV_Health)))
EndFunction
