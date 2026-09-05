param(
    [string]$ServerRoot = 'D:\PZ_Sub server',
    [string]$JdkRoot = 'C:\Program Files\Microsoft\jdk-25.0.4.7-hotspot',
    [string]$AsmJar = ''
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$build = Join-Path $root 'build'
$mainClasses = Join-Path $build 'main-classes'
$testClasses = Join-Path $build 'test-classes'
$deps = Join-Path $build 'deps'
$output = Join-Path $root 'PZZombieNetworkQueueOptimization-agent.jar'
$gameJar = Join-Path $ServerRoot 'java\projectzomboid.jar'
$serverJava = Join-Path $ServerRoot 'jre64\bin\java.exe'
$javac = Join-Path $JdkRoot 'bin\javac.exe'
$jar = Join-Path $JdkRoot 'bin\jar.exe'
if ([string]::IsNullOrWhiteSpace($AsmJar)) {
    $AsmJar = Join-Path $ServerRoot 'server-patches\PZServerStreamingStability-agent.jar'
}

$expectedGameJarHash = '80E405A4BFC42F6072E75B3735F458A6514143DA011D3226007DED305A442F44'
foreach ($required in @($gameJar, $serverJava, $javac, $jar, $AsmJar)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required file not found: $required"
    }
}
if ((Get-FileHash -LiteralPath $gameJar -Algorithm SHA256).Hash -ne $expectedGameJarHash) {
    throw 'REFUSED unsupported projectzomboid.jar'
}

New-Item -ItemType Directory -Force -Path $mainClasses, $testClasses, $deps | Out-Null
foreach ($directory in @($mainClasses, $testClasses, $deps)) {
    Get-ChildItem -LiteralPath $directory -Force -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force
}

Push-Location $deps
try {
    & $jar xf $AsmJar org/objectweb/asm
    if ($LASTEXITCODE -ne 0) { throw 'ASM extraction failed' }
} finally {
    Pop-Location
}

$mainSources = Get-ChildItem -LiteralPath (Join-Path $root 'src\main\java') -Recurse -Filter '*.java' |
    Select-Object -ExpandProperty FullName
$testSources = Get-ChildItem -LiteralPath (Join-Path $root 'src\test\java') -Recurse -Filter '*.java' |
    Select-Object -ExpandProperty FullName

& $javac -encoding UTF-8 -cp "$AsmJar;$gameJar" -d $mainClasses $mainSources
if ($LASTEXITCODE -ne 0) { throw 'main javac failed' }
& $javac -encoding UTF-8 -cp "$mainClasses;$AsmJar;$gameJar" -d $testClasses $testSources
if ($LASTEXITCODE -ne 0) { throw 'test javac failed' }

& $serverJava -cp "$testClasses;$mainClasses;$AsmJar;$gameJar" `
    cn.zombiecommunity.pzzombiequeue.TransformContractTest $gameJar
if ($LASTEXITCODE -ne 0) { throw 'transform contract tests failed' }
& $serverJava -cp "$testClasses;$mainClasses;$AsmJar;$gameJar" `
    cn.zombiecommunity.pzzombiequeue.RuntimeSemanticTest
if ($LASTEXITCODE -ne 0) { throw 'runtime semantic tests failed' }

& $jar --create --file $output `
    --manifest (Join-Path $root 'META-INF\MANIFEST.MF') `
    -C $mainClasses cn -C $deps org\objectweb\asm
if ($LASTEXITCODE -ne 0) { throw 'agent jar creation failed' }

& $serverJava -Xverify:all `
    "-javaagent:$output=enabled=true,threshold=64,linearQueries=3,reportSeconds=60" `
    -cp "$gameJar;$output;$testClasses" `
    cn.zombiecommunity.pzzombiequeue.GameClassLoadSmokeTest
if ($LASTEXITCODE -ne 0) { throw 'JRE 25 class-load verification failed' }

& $serverJava -cp "$testClasses;$mainClasses;$gameJar" `
    cn.zombiecommunity.pzzombiequeue.QueueMicrobenchmark
if ($LASTEXITCODE -ne 0) { throw 'microbenchmark failed' }

Write-Host "Built $output"
Write-Host "SHA256: $((Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash)"

