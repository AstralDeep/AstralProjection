@echo off
REM Double-click launcher for the packaged Windows client: runs dist\AstralDeep.exe, forwarding all
REM arguments (e.g. --deployment-profile for an explicit or developer override).

"%~dp0dist\AstralDeep.exe" %*
