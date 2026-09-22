Scriptname AutoMedicScript extends ActiveMagicEffect

; Скрипт на AM_UseEffect — эффекте предмета-инструмента AutoMedic.
;
; Возвращает предмет в инвентарь и отдаёт управление квесту: весь цикл
; (фазы 0-4, §4) живёт в AutoMedicQuestScript и запускается там асинхронно,
; так что эффект заканчивается сразу.

AutoMedicQuestScript Property AutoMedicQuest Auto Const Mandatory
Potion Property AutoMedicTool Auto Const Mandatory

Event OnEffectStart(Actor akTarget, Actor akCaster)
    ; Предмет задуман многоразовым, но движок всегда съедает тот экземпляр,
    ; который сработал, — поэтому возвращаем его первым же действием.
    akTarget.AddItem(AutoMedicTool, 1, true)
    AutoMedicQuest.OnToolUsed(akTarget)
EndEvent
