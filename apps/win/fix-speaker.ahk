; Purpose: Disconnect and reconnect bluetooth speaker SPACE 5
; Requires AutoHotkey v1 @ https://www.autohotkey.com/
; Requires BCTL @ https://bluetoothinstaller.com/bluetooth-command-line-tools
#Persistent
#NoEnv
#SingleInstance Force  ; Automatically replace any running instance
SendMode Input
CoordMode, Mouse, Screen

; Step 1: Unpair any existing devices
Gui, +AlwaysOnTop -SysMenu -MinimizeBox -MaximizeBox
Gui, Font, s14
Gui, Add, Text, Center, Please wait....
Gui, Show, Center w300 h100, Pairing Process  ; 
Run, cmd.exe /c btpair -u,, Hide
Sleep, 5000  ; Wait for 5 seconds to allow the unpairing process to complete
Gui, Destroy  ;

; Step 2: Run the btpair command to pair the device
Gui, +AlwaysOnTop -SysMenu -MinimizeBox -MaximizeBox
Gui, Font, s14
Gui, Add, Text, Center, Scanning for speaker....
Gui, Show, Center w300 h100, Pairing Process  ; 
Run, cmd.exe /c btpair -n"SPACE 5" -p,, Hide
Gui, Destroy  ;

; Step 3: Pause briefly to let the "Add a device" popup appear
Gui, +AlwaysOnTop -SysMenu -MinimizeBox -MaximizeBox
Gui, Font, s14
Gui, Add, Text, Center, Connecting speaker....
Gui, Show, Center w300 h100, Pairing Process  ; 
Sleep, 10000  ; 
Gui, Destroy  ;
Sleep, 2000  ; 

; Step 4: Click on the "Add a device" popup
MouseClick, Left, 1609, 959  ; Adjust coordinates if needed
Sleep, 2500  ;

; Step 5: Confirm the "Pair Device?" prompt
Send, {Enter}  ; Simulate pressing Enter to confirm pairing
Sleep, 1000  ; 
Send, {Tab}   ; Send Tab key to navigate
Sleep, 1000    ; 
Send, {Enter}  ; Press Enter again
Sleep, 1000  ; 
Send, !{F4}  ; Simulate Alt+F4 to close the window
Sleep, 1000  ; Pause to ensure the window is closed

; Step 6: Display "Pairing completed." message
Gui, +AlwaysOnTop -SysMenu -MinimizeBox -MaximizeBox
Gui, Font, s14
Gui, Add, Text, Center, Pairing completed.
Gui, Show, Center w300 h100, Pairing Process  ; Center the message on the screen
Sleep, 1000  ; 
Gui, Destroy  ; 

; Step 7: Fully exit AutoHotkey
ExitApp  ; This ensures AutoHotkey completely exits
