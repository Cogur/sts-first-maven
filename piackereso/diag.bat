@echo off
rem Hardverapro diagnosztika: kiprobal tobbfele lekerest, az eredmeny a debug\diag_hardverapro.txt fajlba kerul.
cd /d "%~dp0"
if not exist .venv (
  echo Elobb inditsd el egyszer a start.bat-ot, hogy telepitse a csomagokat.
  pause
  exit /b 1
)
.venv\Scripts\python tools\diag_hardverapro.py %*
pause
