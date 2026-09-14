@echo off
rem Double click to patch every GH SigMaker v2.0 that Cheat Engine knows about,
rem or drop GH-CE-SigMaker.dll onto this file to patch that one.
rem Extra switches pass straight through, for example -Restore or -Check.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0GH-SigMaker-Patch.ps1" -PauseAtEnd %*
exit /b %ERRORLEVEL%
