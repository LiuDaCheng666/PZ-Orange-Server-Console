param(
    [string]$ServerRoot = 'D:\PZ_Sub server',
    [string]$JdkRoot = 'C:\Program Files\Microsoft\jdk-25.0.4.7-hotspot'
)

$ErrorActionPreference = 'Stop'
$jdk = Join-Path $JdkRoot 'bin'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$build = Join-Path $root 'build'
$classes = Join-Path $build 'classes'
$deps = Join-Path $build 'deps'
$output = Join-Path $build 'PZPacketRoutingOptimization-agent.jar'
$gameJar = Join-Path $ServerRoot 'java\projectzomboid.jar'
$asmJar = 'D:\PZ_Sub server\server-patches\PZServerStreamingStability-agent.jar'
$expectedGameHash = '80E405A4BFC42F6072E75B3735F458A6514143DA011D3226007DED305A442F44'
if ((Get-FileHash -LiteralPath $gameJar -Algorithm SHA256).Hash -ne $expectedGameHash) {
    throw 'REFUSED unsupported projectzomboid.jar'
}
New-Item -ItemType Directory -Force -Path $classes, $deps | Out-Null
Get-ChildItem -LiteralPath $classes -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
Get-ChildItem -LiteralPath $deps -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
Push-Location $deps
& (Join-Path $jdk 'jar.exe') xf $asmJar org/objectweb/asm
Pop-Location
& (Join-Path $jdk 'javac.exe') -encoding UTF-8 -cp "$asmJar;$gameJar" -d $classes `
    (Join-Path $root 'src\main\java\cn\zombiecommunity\pzrouting\PacketRoutingOptimizationAgent.java') `
    (Join-Path $root 'src\main\java\cn\zombiecommunity\pzrouting\PacketRoutingOptimizationRuntime.java') `
    (Join-Path $root 'src\test\java\cn\zombiecommunity\pzrouting\TransformSmokeTest.java') `
    (Join-Path $root 'src\test\java\cn\zombiecommunity\pzrouting\GameClassLoadSmokeTest.java')
if ($LASTEXITCODE -ne 0) { throw 'javac failed' }
& (Join-Path $jdk 'java.exe') -cp "$classes;$asmJar;$gameJar" `
    cn.zombiecommunity.pzrouting.TransformSmokeTest $gameJar
if ($LASTEXITCODE -ne 0) { throw 'smoke test failed' }
& (Join-Path $jdk 'jar.exe') --create --file $output `
    --manifest (Join-Path $root 'META-INF\MANIFEST.MF') `
    -C $classes cn -C $deps org\objectweb\asm
if ($LASTEXITCODE -ne 0) { throw 'jar failed' }
& (Join-Path $jdk 'java.exe') -Xverify:all `
    "-javaagent:$output=syncIsoObject=true,antibodies=true,antibodiesIntervalMs=20000,farmingDedup=true,farmingHeartbeatMs=300000,farmingCacheMax=32768,farmingCacheTtlMs=900000,connectionTelemetry=true,telemetryIntervalMs=1000,telemetryStaleMs=900000,reportSeconds=300" `
    -cp "$gameJar;$output" cn.zombiecommunity.pzrouting.GameClassLoadSmokeTest
if ($LASTEXITCODE -ne 0) { throw 'class-load smoke test failed' }
Write-Host "Built $output"
Write-Host "SHA256: $((Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash)"
