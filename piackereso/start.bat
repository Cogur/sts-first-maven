@echo off
rem Piackereso inditasa Windowson: dupla kattintas. Elso inditaskor telepiti a csomagokat.
cd /d "%~dp0"
if not exist .venv (
  py -3 -m venv .venv || python -m venv .venv
  .venv\Scripts\python -m pip install -r requirements.txt
)
.venv\Scripts\python server.py %*
pause
