@echo off
chcp 65001 >nul
title Aula-Scrapt USM - Sincronizador con Obsidian
cd /d "%~dp0"
echo Iniciando servidor local Aula-Scrapt...
start "" "http://localhost:8000"
python main.py
pause
