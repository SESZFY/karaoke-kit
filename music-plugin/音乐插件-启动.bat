@echo off
chcp 65001 >nul
title 音乐插件（点歌 → 搜源 → RVC → 发 QQ）
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\surfcore\state\music-plugin.ps1" start
echo.
echo 关掉这个窗口不影响后台服务。
pause