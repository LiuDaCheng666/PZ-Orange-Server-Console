$ErrorActionPreference = 'Stop'
$jdk = 'C:\Program Files\Microsoft\jdk-25.0.4.7-hotspot\bin'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$build = Join-Path $root 'build'
$classes = Join-Path $build 'classes'
$deps = Join-Path $build 'deps'
$output = Join-Path $build 'PZDryingCraftSyncThrottle-agent.jar'
$gameJar = 'D:\PZ_Sub server\java\projectzomboid.jar'
$asmJar = 'D:\PZ_Sub server\server-patches\PZServerStreamingStability-agent.jar'
New-Item -ItemType Directory -Force -Path $classes, $deps | Out-Null
Push-Location $deps
& (Join-Path $jdk 'jar.exe') xf $asmJar org/objectweb/asm
Pop-Location
& (Join-Path $jdk 'javac.exe') -encoding UTF-8 -cp "$asmJar;$gameJar" -d $classes `
    (Join-Path $root 'src\main\java\cn\zombiecommunity\pzdrying\DryingCraftSyncThrottleAgent.java') `
    (Join-Path $root 'src\main\java\cn\zombiecommunity\pzdrying\DryingCraftSyncThrottleRuntime.java') `
    (Join-Path $root 'src\test\java\cn\zombiecommunity\pzdrying\TransformSmokeTest.java')
if ($LASTEXITCODE -ne 0) { throw 'javac failed' }
& (Join-Path $jdk 'java.exe') -cp "$classes;$asmJar;$gameJar" `
    cn.zombiecommunity.pzdrying.TransformSmokeTest
if ($LASTEXITCODE -ne 0) { throw 'smoke test failed' }
& (Join-Path $jdk 'jar.exe') --create --file $output `
    --manifest (Join-Path $root 'META-INF\MANIFEST.MF') `
    -C $classes cn -C $deps org\objectweb\asm
if ($LASTEXITCODE -ne 0) { throw 'jar failed' }
Write-Host "Built $output"
