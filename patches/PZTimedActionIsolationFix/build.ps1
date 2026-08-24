param(
    [Parameter(Mandatory = $true)][string]$ServerRoot,
    [string]$JdkRoot = $env:JAVA_HOME
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($JdkRoot)) {
    $javacCommand = Get-Command javac.exe -ErrorAction SilentlyContinue
    if (-not $javacCommand) { throw 'Set JAVA_HOME or pass -JdkRoot with a JDK 25 installation.' }
    $JdkRoot = Split-Path -Parent (Split-Path -Parent $javacCommand.Source)
}
$Javac = Join-Path $JdkRoot 'bin\javac.exe'
$Java = Join-Path $JdkRoot 'bin\java.exe'
$Jar = Join-Path $JdkRoot 'bin\jar.exe'
$GameJar = Join-Path $ServerRoot 'java\projectzomboid.jar'
$AsmJar = Join-Path $ProjectRoot 'lib\asm-9.8.jar'
$BuildDir = Join-Path $ProjectRoot 'build'
$ClassesDir = Join-Path $BuildDir 'classes'
$TestClassesDir = Join-Path $BuildDir 'test-classes'
$OutputJar = Join-Path $BuildDir 'PZTimedActionIsolationFix-agent.jar'

if (-not (Test-Path -LiteralPath $AsmJar -PathType Leaf)) {
    throw "Missing ASM dependency: $AsmJar"
}

New-Item -ItemType Directory -Force -Path $ClassesDir, $TestClassesDir | Out-Null
Get-ChildItem -LiteralPath $ClassesDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
Get-ChildItem -LiteralPath $TestClassesDir -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

$Sources = Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'src\main\java') -Filter '*.java' -Recurse |
    Select-Object -ExpandProperty FullName
& $Javac --release 25 -encoding UTF-8 -cp "$GameJar;$AsmJar" -d $ClassesDir $Sources
if ($LASTEXITCODE -ne 0) { throw "javac failed with exit code $LASTEXITCODE" }

$TestSources = Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'src\test\java') -Filter '*.java' -Recurse |
    Select-Object -ExpandProperty FullName
& $Javac --release 25 -encoding UTF-8 -cp "$AsmJar;$ClassesDir" -d $TestClassesDir $TestSources
if ($LASTEXITCODE -ne 0) { throw "test javac failed with exit code $LASTEXITCODE" }

& $Java -Xverify:all -cp "$AsmJar;$ClassesDir;$TestClassesDir" `
    cn.zombiecommunity.pzactionisolation.TransformSmokeTest $GameJar
if ($LASTEXITCODE -ne 0) { throw "transform test failed with exit code $LASTEXITCODE" }

& $Java -Xverify:all -cp "$ClassesDir;$TestClassesDir" `
    cn.zombiecommunity.pzactionisolation.RuntimeIntegrationTest
if ($LASTEXITCODE -ne 0) { throw "runtime integration test failed with exit code $LASTEXITCODE" }

Push-Location $ClassesDir
try {
    & $Jar xf $AsmJar
    Remove-Item -LiteralPath 'META-INF\MANIFEST.MF' -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'module-info.class' -Force -ErrorAction SilentlyContinue
} finally {
    Pop-Location
}

if (Test-Path -LiteralPath $OutputJar) { Remove-Item -LiteralPath $OutputJar -Force }
& $Jar --create --file $OutputJar --manifest (Join-Path $ProjectRoot 'META-INF\MANIFEST.MF') -C $ClassesDir .
if ($LASTEXITCODE -ne 0) { throw "jar failed with exit code $LASTEXITCODE" }

& $Java -Xverify:all "-javaagent:$OutputJar" -cp "$GameJar;$OutputJar;$TestClassesDir" `
    cn.zombiecommunity.pzactionisolation.GameClassLoadSmokeTest
if ($LASTEXITCODE -ne 0) { throw "real game-class load test failed with exit code $LASTEXITCODE" }

$Hash = Get-FileHash -LiteralPath $OutputJar -Algorithm SHA256
Write-Host "Built: $OutputJar"
Write-Host "SHA256: $($Hash.Hash)"
