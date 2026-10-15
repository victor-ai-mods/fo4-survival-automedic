Scriptname AutoMedicCheck extends Quest

; Самопроверка установки (1.5.0) — третий скрипт на AM_Quest.
;
; Без F4SE или GOEPE мод раньше молчал: вызовы их функций тихо возвращают
; None / 0 / "", а без файлов GOEPE основной скрипт, скорее всего, не
; загружается вовсе (в нём есть тип GardenOfEden3:ActiveEffectData) — тогда
; нет ни предмета, ни сообщений. Поэтому проверка живёт здесь и не объявляет
; ни одного типа F4SE / GOEPE / MCM: только статические вызовы, которые
; ищутся в момент вызова и без расширения просто возвращают 0 или "".
;
; Блокирующее — окно на каждой загрузке и при каждом применении предмета:
;   F4SE не запущен; GOEPE не загружен (не установлен или сборка не под эту
;   версию игры). GOEPE — плагин F4SE, так что его ответ доказывает и F4SE.
; Мягкое — уведомление при первом применении предмета за сессию:
;   Survival выключен (правило голода/жажды HC_Rule_SustenanceEffects != 1),
;   нет MCM (настройки и автоматический режим не включить).

Int Property STATUS_OK = 0 AutoReadOnly Hidden
Int Property STATUS_NO_F4SE = 1 AutoReadOnly Hidden
Int Property STATUS_NO_GOEPE = 2 AutoReadOnly Hidden

; Подписка на загрузки: у сейвов с 1.4.0 и раньше OnQuestInit этого скрипта
; уже не придёт — подписывает основной скрипт из Refresh (EnsureRegistered).
Bool CK_Registered = false
; Мягкие уведомления уже показаны в этой сессии.
Bool CK_SoftShown = false

Event OnQuestInit()
    EnsureRegistered()
EndEvent

Event Actor.OnPlayerLoadGame(Actor akSender)
    CK_SoftShown = false
    Report()
EndEvent

; Первая подписка сама показывает проверку: событие этой загрузки уже прошло.
Function EnsureRegistered()
    If CK_Registered
        Return
    EndIf
    CK_Registered = true
    RegisterForRemoteEvent(Game.GetPlayer(), "OnPlayerLoadGame")
    CK_SoftShown = false
    Report()
EndFunction

Int Function Status()
    If GardenOfEden.GetVersionRelease() > 0
        Return STATUS_OK
    EndIf
    If F4SE.GetVersionRelease() <= 0
        Return STATUS_NO_F4SE
    EndIf
    Return STATUS_NO_GOEPE
EndFunction

; Окно, если мод не может работать. true — всё в порядке.
Bool Function Report()
    Int status = Status()
    If status == STATUS_OK
        Return true
    EndIf
    Debug.MessageBox(ProblemText(status))
    Return false
EndFunction

; Вызывается основным скриптом при применении предмета. false — цикл не
; запускать (окно уже показано).
Bool Function CheckOnUse()
    If !Report()
        Return false
    EndIf
    If CK_SoftShown
        Return true
    EndIf
    CK_SoftShown = true
    GlobalVariable sustenance = Game.GetFormFromFile(0x000854, "Fallout4.esm") as GlobalVariable  ; HC_Rule_SustenanceEffects
    If sustenance != None && sustenance.GetValue() != 1.0
        Debug.Notification(T("AutoMedic: Survival mode is off - hunger, thirst and diseases are skipped", \
            "AutoMedic: режим выживания выключен — голод, жажда и болезни не учитываются"))
    EndIf
    If !MCM.IsInstalled()
        Debug.Notification(T("AutoMedic: MCM is not installed - settings and automatic mode can't be changed", \
            "AutoMedic: MCM не установлен — настройки и автоматический режим не изменить"))
    EndIf
    Return true
EndFunction

; Строка для лога основного скрипта (он пишет в файл через GOEPE, так что
; появляется только при рабочем GOEPE — для разбора чужих логов).
String Function Summary()
    GlobalVariable sustenance = Game.GetFormFromFile(0x000854, "Fallout4.esm") as GlobalVariable
    Return "game " + Debug.GetVersionNumber() + ", F4SE " + F4SE.GetVersion() + "." + F4SE.GetVersionMinor() + "." + \
        F4SE.GetVersionBeta() + ", GOEPE " + GardenOfEden.GetVersionRelease() + ", MCM " + MCM.IsInstalled() + \
        ", sustenance " + (sustenance != None && sustenance.GetValue() == 1.0)
EndFunction

String Function ProblemText(Int aiStatus)
    String version = Debug.GetVersionNumber()
    If aiStatus == STATUS_NO_F4SE
        Return T("Survival AutoMedic can't work: F4SE is not running.\n\n" + \
            "Start the game with f4se_loader.exe (or the F4SE entry in your mod manager), not with the normal launcher. " + \
            "If you already do, reinstall F4SE together with its Data\\Scripts files.\n\nYour game version: " + version, \
            "Survival AutoMedic не может работать: F4SE не запущен.\n\n" + \
            "Запускайте игру через f4se_loader.exe (или пункт F4SE в менеджере модов), а не обычным лаунчером. " + \
            "Если так и делаете — переустановите F4SE вместе с файлами из Data\\Scripts.\n\nВаша версия игры: " + version)
    EndIf
    Return T("Survival AutoMedic can't work: Garden of Eden Papyrus Script Extender is not loaded.\n\n" + \
        "Install its main file from Nexus (Fallout 4 mod 74160): it supports game versions 1.10.163, 1.10.984 and " + \
        "1.11.137-1.11.240. Each \"Legacy\" file works with one game version only.\n\nYour game version: " + version, \
        "Survival AutoMedic не может работать: не загружен Garden of Eden Papyrus Script Extender.\n\n" + \
        "Установите его основной файл с Nexus (мод 74160 для Fallout 4): он поддерживает версии игры 1.10.163, 1.10.984 и " + \
        "1.11.137-1.11.240. Каждый файл «Legacy» работает только со своей версией игры.\n\nВаша версия игры: " + version)
EndFunction

; Язык как в основном скрипте (sLanguage через GOEPE). Без GOEPE — по имени
; стимулятора через F4SE: «Стимулятор» в русской игре; иначе английский.
String Function T(String asEn, String asRu)
    String lang = GardenOfEden.GetINISetting("sLanguage:General")
    If lang == "ru"
        Return asRu
    ElseIf lang != ""
        Return asEn
    EndIf
    Form stimpak = Game.GetFormFromFile(0x023736, "Fallout4.esm")
    If stimpak != None && stimpak.GetName() == "Стимулятор"
        Return asRu
    EndIf
    Return asEn
EndFunction
