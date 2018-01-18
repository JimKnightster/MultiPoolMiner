@echo off
cd /d %~dp0
ECHO Deleting benchmark data for updated miners

if exist "Stats\MkxminerAmd_*_HashRate.txt" del "Stats\MkxminerAmd_*_HashRate.txt"
if exist "Stats\BMiner_*_HashRate.txt" del "Stats\BMiner_*_HashRate.txt"
if exist "Stats\EMiner_*_HashRate.txt" del "Stats\EMiner_*_HashRate.txt"
if exist "Stats\Cast_*_HashRate.txt" del "Stats\Cast_*_HashRate.txt"
if exist "Stats\EthminerNvidia_*_HashRate.txt" del "Stats\EthMinerNvidia_*_HashRate.txt"
if exist "Stats\EthminerAmd_*_HashRate.txt" del "Stats\EthMinerAmd_*_HashRate.txt"

ECHO You need to rebenchmark some algorithms.
PAUSE
