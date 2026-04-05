; Purpose
; =======
; Auto page-flip on ADE and Libby to record eBook with OBS.
;
; Script
; ======
;
#NoEnv  
; Recommended for performance and compatibility with future AutoHotkey releases.
; Enable warnings to assist with detecting common errors.
; Recommended for new scripts due to its superior speed and reliability.
; Ensures a consistent starting directory.
SendMode Input  
SetWorkingDir %A_ScriptDir%  

F12::
SetTimer, PressTheKey, 2000
Return

Pause::
Pause
Suspend
Return

Escape::
ExitApp
Return

PressTheKey:
Send, {Space}
Return
