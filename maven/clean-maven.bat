set REPOSITORY_PATH=D:\.m2\repository
rem ÕýÔÚËÑË÷...
for /f "delims=" %%i in ('dir /b /s "%REPOSITORY_PATH%\*lastUpdated*"') do (
    del /s /q %%i
)
rem ËÑË÷Íê±Ï
pause
