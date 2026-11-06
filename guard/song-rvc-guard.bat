@echo off
chcp 65001 >nul
title 点歌服务守护（song-rvc + 点歌监听）
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\surfcore\state\song-guard.ps1"
pause
