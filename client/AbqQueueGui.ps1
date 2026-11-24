#Requires -Version 5.1
# Compatibility: open unified GUI
$ErrorActionPreference = "Stop"
& (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "AbqCtlGui.ps1")
