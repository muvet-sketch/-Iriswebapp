@echo off
REM Lanzador del vigilante de audios. Doble clic para arrancar.
REM Dejar esta ventana abierta: si se cierra, el vigilante se detiene.

chcp 65001 >nul
cd /d "%~dp0"

title IRIS - Vigilante de audios

echo.
echo  ============================================
echo   IRIS - Transcripcion automatica de audios
echo  ============================================
echo.
echo   Deja los audios en la carpeta vigilada.
echo   Las transcripciones salen en Transcripciones\
echo.
echo   Para detener: Ctrl+C o cerrar esta ventana.
echo.

python vigilante.py %*

echo.
echo  El vigilante se detuvo.
pause
