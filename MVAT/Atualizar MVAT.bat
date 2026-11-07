@echo off
rem ======================================================================
rem  Atualizar MVAT - baixa a versao mais nova do GitHub e atualiza o addon.
rem  Duplo clique. Pode ficar dentro da pasta do addon (AddOns\MVAT) ou em
rem  qualquer lugar: se nao estiver dentro do jogo, ele acha a pasta do WoW
rem  (ou pergunta uma vez) e instala la.
rem  Para forcar a reinstalacao mesmo na mesma versao: Atualizar MVAT.bat force
rem  Codigo-fonte: https://github.com/cleytoncl3/MVAT-CombatTutor
rem ======================================================================
title Atualizar MVAT
set "MVAT_BAT=%~f0"
if /i "%~1"=="force" set "MVAT_FORCE=1"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$t=[IO.File]::ReadAllText($env:MVAT_BAT); $i=$t.IndexOf(([string][char]35+'PS'+[char]35)); Invoke-Expression $t.Substring($i+4)" & (if not defined MVAT_NOPAUSE pause) & exit /b
#PS#
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Repo   = 'cleytoncl3/MVAT-CombatTutor'
$Branch = 'main'
$Force  = ($env:MVAT_FORCE -eq '1')

function Say($m, $c = 'White') { Write-Host $m -ForegroundColor $c }

function ReadVersion($toc) {
    if (-not (Test-Path -LiteralPath $toc)) { return $null }
    foreach ($l in Get-Content -LiteralPath $toc) {
        if ($l -match '^\s*##\s*Version:\s*([0-9][0-9\.]*)') { return $matches[1] }
    }
    return $null
}
function ToVer($v) { try { [version]$v } catch { [version]'0.0' } }

try {
    Say ''
    Say '  MVAT - Tutor de Combate: atualizador' 'Cyan'
    Say '  -----------------------------------' 'Cyan'

    # 1) onde esta (ou sera instalado) o addon
    $self = Split-Path -Parent $env:MVAT_BAT
    $target = $null
    if ($self -match '\\AddOns\\MVAT$' -and (Test-Path -LiteralPath (Join-Path $self 'MVAT.toc'))) {
        $target = $self
    } else {
        $saved = Join-Path $env:APPDATA 'MVAT-updater.txt'
        $cands = @()
        if (Test-Path -LiteralPath $saved) { $cands += (Get-Content -LiteralPath $saved -Raw).Trim() }
        foreach ($root in @('C:\Program Files (x86)', 'C:\Program Files', 'D:', 'E:', 'D:\Games', 'C:\Games')) {
            foreach ($fl in @('_forever_', '_classic_', '_classic_era_')) {
                $cands += (Join-Path $root "World of Warcraft\$fl\Interface\AddOns")
            }
        }
        foreach ($c in $cands) {
            if ($c -and (Test-Path -LiteralPath $c)) { $target = Join-Path $c 'MVAT'; break }
        }
        if (-not $target) {
            Say '  Nao achei a pasta de addons do WoW.' 'Yellow'
            Say '  Cole o caminho da pasta AddOns (ex.: C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns)' 'Yellow'
            $ans = (Read-Host '  Caminho').Trim().Trim('"')
            if (-not (Test-Path -LiteralPath $ans)) { throw "Pasta nao existe: $ans" }
            $target = Join-Path $ans 'MVAT'
        }
        Set-Content -LiteralPath (Join-Path $env:APPDATA 'MVAT-updater.txt') -Value (Split-Path -Parent $target) -Encoding ASCII
    }
    Say "  Pasta do addon: $target"

    # 2) versao instalada x versao no GitHub
    $local = ReadVersion (Join-Path $target 'MVAT.toc')
    $tmpToc = Join-Path $env:TEMP 'mvat_remote.toc'
    Invoke-WebRequest -UseBasicParsing -Uri "https://raw.githubusercontent.com/$Repo/$Branch/MVAT/MVAT.toc" -OutFile $tmpToc
    $remote = ReadVersion $tmpToc
    if (-not $remote) { throw 'Nao consegui ler a versao do GitHub.' }
    Say ("  Instalada: {0}   GitHub: {1}" -f ($(if ($local) { $local } else { 'nenhuma' })), $remote)

    if ($local -and -not $Force -and ((ToVer $local) -ge (ToVer $remote))) {
        Say ''
        Say '  Ja esta atualizado. Nada a fazer.' 'Green'
        return
    }

    # 3) baixa e instala
    Say '  Baixando...'
    $zip = Join-Path $env:TEMP 'mvat_main.zip'
    $dir = Join-Path $env:TEMP 'mvat_extract'
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    Invoke-WebRequest -UseBasicParsing -Uri "https://github.com/$Repo/archive/refs/heads/$Branch.zip" -OutFile $zip
    Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
    $root1 = Get-ChildItem -LiteralPath $dir -Directory | Select-Object -First 1
    $srcAddon = Join-Path $root1.FullName 'MVAT'
    if (-not (Test-Path -LiteralPath (Join-Path $srcAddon 'MVAT.toc'))) { throw 'Pacote baixado esta incompleto.' }

    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $selfName = 'Atualizar MVAT.bat'
    # o proprio .bat vai por ultimo (ele esta em execucao)
    Get-ChildItem -LiteralPath $srcAddon -Force | Where-Object { $_.Name -ne $selfName } |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $target -Recurse -Force }
    $newBat = Join-Path $srcAddon $selfName
    if (Test-Path -LiteralPath $newBat) {
        Copy-Item -LiteralPath $newBat -Destination (Join-Path $target $selfName) -Force -ErrorAction SilentlyContinue
    }

    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue

    $now = ReadVersion (Join-Path $target 'MVAT.toc')
    Say ''
    Say "  Pronto! MVAT atualizado para a versao $now." 'Green'
    Say '  No jogo: digite /reload  (suas configuracoes continuam salvas).' 'Green'
}
catch {
    Say ''
    Say ('  FALHA: ' + $_.Exception.Message) 'Red'
    Say '  Verifique a internet e tente de novo. Se persistir, baixe o ZIP em:' 'Yellow'
    Say "  https://github.com/$Repo" 'Yellow'
}
