@echo off
REM Lanzador del puente entre la app IRIS y esta carpeta de audios.
REM Va JUNTO con iniciar_vigilante.bat: hacen falta las dos ventanas abiertas.
REM   vigilante.py  -> transcribe los audios que aparecen en la carpeta
REM   puente_iris.py -> baja los audios que graba la app y le devuelve el SOIP

chcp 65001 >nul
cd /d "%~dp0"

title IRIS - Puente con la app

echo.
echo  ============================================
echo   IRIS - Puente con la app
echo  ============================================
echo.
echo   Baja los audios grabados desde el Tablero,
echo   los deja en la carpeta vigilada (y en Drive)
echo   y devuelve el SOIP ya extraido.
echo.
echo   Necesita IRIS_SUPABASE_SERVICE_KEY y
echo   ANTHROPIC_API_KEY en el entorno.
echo.
echo   Para detener: Ctrl+C o cerrar esta ventana.
echo.

python puente_iris.py %*

echo.
echo  El puente se detuvo.
pause
