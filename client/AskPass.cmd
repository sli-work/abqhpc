@echo off
rem Print the password exactly, with no extra newline or carriage return.
setlocal DisableDelayedExpansion
set "F=%~dp0.askpass"
if not exist "%F%" exit /b 1
for /f "usebackq delims=" %%P in ("%F%") do (
  <nul set /p "=%%P"
  exit /b 0
)
exit /b 1
