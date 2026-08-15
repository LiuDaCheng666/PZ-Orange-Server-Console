param()

$ErrorActionPreference = "Stop"
$panelPath = Join-Path $PSScriptRoot "PZ-ControlPanel.ps1"
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($panelPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw ($errors | Out-String) }

foreach ($functionName in @("Convert-JvmSizeToBytes", "Get-JvmGcLogPathArgument", "Get-JvmMemoryMetrics")) {
    $targetName = $functionName
    $functionAst = $ast.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq $targetName
    }, $true)
    if (-not $functionAst) { throw "$targetName was not found." }
    Invoke-Expression $functionAst.Extent.Text
}

$cases = @(
    [pscustomobject]@{
        Name = "relative"
        Arguments = '-Xlog:gc*,safepoint:file=logs/jvm-gc.log:time,uptime,level,tags:filecount=5,filesize=20M'
        Expected = 'logs/jvm-gc.log'
    },
    [pscustomobject]@{
        Name = "windows-forward-slash"
        Arguments = '-Xlog:gc*,safepoint:file=D:/PZServerData2/Logs/jvm-gc.log:time,uptime,level,tags:filecount=5,filesize=20M'
        Expected = 'D:/PZServerData2/Logs/jvm-gc.log'
    },
    [pscustomobject]@{
        Name = "windows-backslash"
        Arguments = '-Xlog:gc:file=D:\PZServerData2\Logs\jvm-gc.log:time,uptime'
        Expected = 'D:\PZServerData2\Logs\jvm-gc.log'
    },
    [pscustomobject]@{
        Name = "quoted-space"
        Arguments = '-Xlog:gc:file="D:\PZ Server Data\Logs\jvm-gc.log":time,uptime'
        Expected = 'D:\PZ Server Data\Logs\jvm-gc.log'
    },
    [pscustomobject]@{
        Name = "missing"
        Arguments = '-XX:+UseZGC -Xmx48g zombie.network.GameServer'
        Expected = $null
    }
)

foreach ($case in $cases) {
    $actual = Get-JvmGcLogPathArgument -Arguments $case.Arguments
    if ([string]$actual -cne [string]$case.Expected) {
        throw "$($case.Name): expected '$($case.Expected)', got '$actual'."
    }
}

$testRoot = Join-Path $env:TEMP ("PZJvmGcTelemetry-" + [guid]::NewGuid().ToString("N"))
try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    $logPath = Join-Path $testRoot "jvm-gc.log"
    $startedAt = [datetimeoffset]::Now
    $timestamp = $startedAt.ToString("yyyy-MM-ddTHH:mm:ss.fffzzz")
    $logLines = @(
        "[$timestamp][0.006s][info][gc,init] Initializing The Z Garbage Collector",
        "[$timestamp][1.006s][info][gc,heap     ] GC(1) y: Used: 31082M (47%) 31512M (48%) 25046M (38%) 14950M (23%) 31512M (48%) 14950M (23%)"
    )
    [IO.File]::WriteAllLines($logPath, $logLines, [Text.UTF8Encoding]::new($false))

    $forwardLogPath = $logPath.Replace('\', '/')
    $script:mockJvmProcessInfo = [pscustomobject]@{
        ProcessId = 4242
        CommandLine = "java.exe -Xmx48g -Xlog:gc*,safepoint:file=$($forwardLogPath):time,uptime,level,tags:filecount=5,filesize=20M zombie.network.GameServer"
    }
    function Get-PZProcessInfos { return @($script:mockJvmProcessInfo) }
    $jvmMemoryCache = @{}
    $profile = [pscustomobject]@{ id = "absolute-path-test"; runtimeRoot = "D:\unused" }
    $process = [pscustomobject]@{ Id = 4242; StartTime = $startedAt.LocalDateTime }
    $metrics = Get-JvmMemoryMetrics -Profile $profile -Process $process
    if (-not $metrics.available -or [int]$metrics.sampleCount -ne 1 -or
        [int64]$metrics.currentUsedBytes -ne (14950L * 1MB) -or
        [int64]$metrics.peakUsedBytes -ne (31512L * 1MB)) {
        throw "Absolute Windows JVM log path did not produce the expected heap metrics: $($metrics | ConvertTo-Json -Compress)"
    }

    [pscustomobject]@{
        ok = $true
        pathCases = $cases.Count
        server2Path = Get-JvmGcLogPathArgument -Arguments $cases[1].Arguments
        metricAvailable = [bool]$metrics.available
        metricSamples = [int]$metrics.sampleCount
    } | ConvertTo-Json
}
finally {
    if (Test-Path -LiteralPath $testRoot) {
        $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
        $resolvedTempRoot = [IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\'
        if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
        }
    }
}
