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
$Jar = Join-Path $JdkRoot 'bin\jar.exe'
$GameJar = Join-Path $ServerRoot 'java\projectzomboid.jar'
$LibDir = Join-Path $ProjectRoot 'lib'
$BuildDir = Join-Path $ProjectRoot 'build'
$ClassesDir = Join-Path $BuildDir 'classes'
$AsmJar = Join-Path $LibDir 'asm-9.8.jar'
$OutputJar = Join-Path $BuildDir 'PZGlassRemovalGuard-agent.jar'

New-Item -ItemType Directory -Force -Path $LibDir, $ClassesDir | Out-Null

if (-not (Test-Path -LiteralPath $AsmJar)) {
    Invoke-WebRequest `
        -Uri 'https://repo1.maven.org/maven2/org/ow2/asm/asm/9.8/asm-9.8.jar' `
        -OutFile $AsmJar
}

Get-ChildItem -LiteralPath $ClassesDir -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force

$Sources = Get-ChildItem -LiteralPath (Join-Path $ProjectRoot 'src\main\java') -Filter '*.java' -Recurse |
    Select-Object -ExpandProperty FullName

& $Javac --release 25 -encoding UTF-8 -cp "$GameJar;$AsmJar" -d $ClassesDir $Sources
if ($LASTEXITCODE -ne 0) { throw "javac failed with exit code $LASTEXITCODE" }

Push-Location $ClassesDir
try {
    & $Jar xf $AsmJar
    Remove-Item -LiteralPath 'META-INF\MANIFEST.MF' -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'module-info.class' -Force -ErrorAction SilentlyContinue
} finally {
    Pop-Location
}

if (Test-Path -LiteralPath $OutputJar) { Remove-Item -LiteralPath $OutputJar -Force }
& $Jar --create --file $OutputJar `
    --manifest (Join-Path $ProjectRoot 'META-INF\MANIFEST.MF') `
    -C $ClassesDir .
if ($LASTEXITCODE -ne 0) { throw "jar failed with exit code $LASTEXITCODE" }

$Hash = Get-FileHash -LiteralPath $OutputJar -Algorithm SHA256
Write-Host "Built: $OutputJar"
Write-Host "SHA256: $($Hash.Hash)"
