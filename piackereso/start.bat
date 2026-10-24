@echo off
rem Piackereso inditasa Windowson: dupla kattintas.
rem Elso inditaskor, es ha a requirements.txt valtozott, telepiti a csomagokat.
cd /d "%~dp0"
if not exist .venv (
  py -3 -m venv .venv || python -m venv .venv
)
fc /b requirements.txt .venv\installed-requirements.txt >nul 2>&1
if errorlevel 1 (
  .venv\Scripts\python -m pip install -r requirements.txt && copy /y requirements.txt .venv\installed-requirements.txt >nul
)
.venv\Scripts\python server.py %*
pause
