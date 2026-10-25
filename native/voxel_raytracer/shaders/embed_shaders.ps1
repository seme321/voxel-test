$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputHeader = Join-Path $scriptDir "..\src\vulkan\embedded_shaders.h"

function Format-SpvToCpp($filePath, $varName) {
    $bytes = [System.IO.File]::ReadAllBytes($filePath)
    $u32Count = $bytes.Length / 4
    $u32Array = New-Object uint32[] $u32Count
    [System.Buffer]::BlockCopy($bytes, 0, $u32Array, 0, $bytes.Length)

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("alignas(4) const uint32_t ${varName}[] = {")
    for ($i = 0; $i -lt $u32Count; $i += 8) {
        $chunk = for ($j = $i; $j -lt [Math]::Min($i + 8, $u32Count); $j++) {
            "0x{0:X8}u" -f $u32Array[$j]
        }
        [void]$sb.AppendLine(($chunk -join ", ") + ", ")
    }
    [void]$sb.AppendLine("};")
    [void]$sb.AppendLine("const size_t ${varName}_size = $($bytes.Length);`n")
    return $sb.ToString()
}

$headerContent = @"
#pragma once
#include <cstdint>
#include <cstddef>

namespace godot {
namespace Shaders {

"@

$headerContent += Format-SpvToCpp (Join-Path $scriptDir "raygen.spv") "kRayGenSpv"
$headerContent += Format-SpvToCpp (Join-Path $scriptDir "miss.spv") "kMissSpv"
$headerContent += Format-SpvToCpp (Join-Path $scriptDir "caelix_intersection.spv") "kIntersectionSpv"
$headerContent += Format-SpvToCpp (Join-Path $scriptDir "closesthit.spv") "kClosestHitSpv"

$headerContent += @"
} // namespace Shaders
} // namespace godot
"@

[System.IO.File]::WriteAllText($outputHeader, $headerContent)
Write-Host "Generated $outputHeader successfully!"
