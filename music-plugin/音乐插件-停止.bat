@echo off
chcp 65001 >nul
title 音乐插件 - 停止
powershell -NoProfile -ExecutionPolicy Bypass -File "D:\surfcore\state\music-plugin.ps1" stop
pause