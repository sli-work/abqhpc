' Launch AbqCtlGui without a visible console window.
Option Explicit
Dim sh, fso, dir, ps
Set sh = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")
dir = fso.GetParentFolderName(WScript.ScriptFullName)
ps = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & dir & "\AbqCtlGui.ps1"""
sh.CurrentDirectory = dir
sh.Run ps, 0, False
