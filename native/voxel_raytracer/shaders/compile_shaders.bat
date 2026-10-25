@echo off
set "DXC=C:\Users\6\VulkanBin\Bin\dxc.exe"

if not exist "%DXC%" (
    echo [ERROR] DXC compiler not found at %DXC%
    exit /b 1
)

echo [1/4] Compiling raygen.hlsl -> raygen.spv...
"%DXC%" -spirv -fspv-target-env="vulkan1.3" -T lib_6_6 -Fo raygen.spv raygen.hlsl

echo [2/4] Compiling miss.hlsl -> miss.spv...
"%DXC%" -spirv -fspv-target-env="vulkan1.3" -T lib_6_6 -Fo miss.spv miss.hlsl

echo [3/4] Compiling caelix_intersection.hlsl -> caelix_intersection.spv...
"%DXC%" -spirv -fspv-target-env="vulkan1.3" -T lib_6_6 -Fo caelix_intersection.spv caelix_intersection.hlsl

echo [4/4] Compiling closesthit.hlsl -> closesthit.spv...
"%DXC%" -spirv -fspv-target-env="vulkan1.3" -T lib_6_6 -Fo closesthit.spv closesthit.hlsl

echo All shaders compiled successfully!
