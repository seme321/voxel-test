@echo off
setlocal enabledelayedexpansion

echo [1/4] Initializing MSVC x64 Environment...
call "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat" x64

set "PATH=C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin;C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja;%PATH%"

cd /d "%~dp0"

echo [2/4] Generating CMake build files with Ninja...
cmake -B build -G "Ninja" -DCMAKE_BUILD_TYPE=Debug
if %ERRORLEVEL% neq 0 (
    echo [ERROR] CMake configuration failed!
    exit /b %ERRORLEVEL%
)

echo [3/4] Compiling GDExtension with Ninja...
cmake --build build --config Debug
if %ERRORLEVEL% neq 0 (
    echo [ERROR] Compilation failed!
    exit /b %ERRORLEVEL%
)

echo [4/4] Build complete! Checking output DLL...
if exist "..\..\bin\voxel_raytracer.windows.template_debug.x86_64.dll" (
    echo [SUCCESS] DLL generated at bin\voxel_raytracer.windows.template_debug.x86_64.dll
    exit /b 0
) else (
    echo [ERROR] DLL not found in bin directory!
    exit /b 1
)
