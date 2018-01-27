@echo off
cd /d %~dp0
ECHO Deleting benchmark data for updated miners

if exist "Stats\Cast_*_HashRate.txt" del "Stats\Cast_*_HashRate.txt"
if exist "Stats\BMiner_*_HashRate.txt" del "Stats\BMiner_*_HashRate.txt"
if exist "Stats\CpuminerJayddee*_HashRate.txt" del "Stats\CpuminerJayddee*_HashRate.txt"
if exist "Stats\CcminerKlaust_*_HashRate.txt" del "Stats\CcminerKlaust_*_HashRate.txt"

ECHO You need to rebenchmark some algorithms.
PAUSE
