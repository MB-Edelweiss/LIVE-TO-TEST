param(
    [ValidateSet('sync','files','db','urls','plugins','status')]
    [string]$Action = 'sync',

    [switch]$SkipFiles,
    [switch]$SkipDb,
    [switch]$NoBuild,
    [switch]$DryRun,
    [switch]$ForceVolumeReset
)

$ErrorActionPreference = 'Stop'

# -----------------------------
# Configuration
# -----------------------------
$Config = @{
    SshAlias        = 'edellive'
    LiveWebRoot     = 'web'
    LiveDbName      = 'c1685edellive'
    LiveDbUser      = 'c1685edellive'

    LocalBase       = 'D:/SALALYTIC/STAGING_EAAT'
    DockerProject   = 'D:/SALALYTIC/STAGING_EAAT/Docker/edelweiss-wp-docker'
    LocalWpExtract  = 'D:/SALALYTIC/STAGING_EAAT/Docker/edelweiss-wp-docker/wordpress'

    RemoteFilesTgz  = '/tmp/edelweiss_wp_files.tgz'
    RemoteDbSql     = '/tmp/edelweiss_db.sql'
    RemoteDbGz      = '/tmp/edelweiss_db.sql.gz'

    LocalFilesTgz   = 'D:/SALALYTIC/STAGING_EAAT/edelweiss_wp_files.tgz'
    LocalDbGz       = 'D:/SALALYTIC/STAGING_EAAT/edelweiss_db.sql.gz'
    LocalDbSql      = 'D:/SALALYTIC/STAGING_EAAT/edelweiss_db.sql'

    DockerDbContainer = 'edelweiss_wp_db'
    DockerWebContainer = 'edelweiss_wp_web'
    DockerWpVolume     = 'edelweiss-wp-docker_wpdata'

    LocalSiteUrl    = 'http://localhost:8080'

    ProblemPlugins  = @(
        'wp-google-maps',
        'wp-webhooks-pro',
        'wp-mail-smtp-pro',
        'woocommerce-ultimate-gift-card'
    )
}

function Write-Step([string]$Message) {
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Invoke-LoggedCommand {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [string]$WorkingDirectory = $null,
        [switch]$AllowFailure
    )

    if ($WorkingDirectory) {
        Write-Host "[$WorkingDirectory] $Command" -ForegroundColor DarkGray
    }
    else {
        Write-Host $Command -ForegroundColor DarkGray
    }

    if ($DryRun) { return }

    $previous = Get-Location
    try {
        if ($WorkingDirectory) { Set-Location $WorkingDirectory }
        Invoke-Expression $Command
        $exitCode = $LASTEXITCODE
        if (-not $AllowFailure -and $exitCode -ne 0) {
            throw "Command failed with exit code $exitCode"
        }
    }
    finally {
        Set-Location $previous
    }
}

function Test-Prerequisites {
    Write-Step 'Pruefe Voraussetzungen'
    foreach ($cmd in @('ssh','scp','docker')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "Befehl '$cmd' wurde nicht gefunden. Bitte zuerst installieren bzw. in PATH aufnehmen."
        }
    }

    if (-not (Test-Path $Config.DockerProject)) {
        throw "Docker-Projektordner nicht gefunden: $($Config.DockerProject)"
    }

    if (-not (Test-Path $Config.LocalBase)) {
        throw "Lokaler Basisordner nicht gefunden: $($Config.LocalBase)"
    }
}

function New-LocalFolders {
    foreach ($folder in @($Config.LocalBase, $Config.DockerProject, $Config.LocalWpExtract)) {
        if (-not (Test-Path $folder)) {
            if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
        }
    }
}

function Get-LiveFiles {
    Write-Step 'Erstelle Live-Dateiarchiv am Server'
    $remoteTar = @"
ssh $($Config.SshAlias) "cd $($Config.LiveWebRoot) && tar -czf $($Config.RemoteFilesTgz) . --exclude='wp-content/cache' --exclude='wp-content/ai1wm-backups' --exclude='wp-content/updraft' --exclude='wp-content/backups'"
"@
    Invoke-LoggedCommand $remoteTar

    Write-Step 'Lade Live-Dateiarchiv herunter'
    Invoke-LoggedCommand "scp $($Config.SshAlias):$($Config.RemoteFilesTgz) $($Config.LocalFilesTgz)"

    Write-Step 'Entpacke Dateien lokal in wordpress/'
    if (-not $DryRun) {
        if (Test-Path $Config.LocalWpExtract) {
            Get-ChildItem -Path $Config.LocalWpExtract -Force | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        }
        else {
            New-Item -ItemType Directory -Force -Path $Config.LocalWpExtract | Out-Null
        }
    }
    Invoke-LoggedCommand "tar -xzf $($Config.LocalFilesTgz) -C $($Config.LocalWpExtract)"
}

function Get-LiveDatabase {
    Write-Step 'Erstelle DB-Dump am Server'
    $dumpCmd = @"
ssh $($Config.SshAlias) "mysqldump -u $($Config.LiveDbUser) -p --single-transaction --quick --routines --triggers --events $($Config.LiveDbName) > $($Config.RemoteDbSql)"
"@
    Invoke-LoggedCommand $dumpCmd

    Write-Step 'Komprimiere DB-Dump am Server'
    Invoke-LoggedCommand "ssh $($Config.SshAlias) \"gzip -f $($Config.RemoteDbSql)\""

    Write-Step 'Lade DB-Dump herunter'
    Invoke-LoggedCommand "scp $($Config.SshAlias):$($Config.RemoteDbGz) $($Config.LocalDbGz)"

    Write-Step 'Entpacke DB-Dump lokal'
    if (-not $DryRun -and (Test-Path $Config.LocalDbSql)) {
        Remove-Item $Config.LocalDbSql -Force
    }
    Invoke-LoggedCommand "gzip -d -c $($Config.LocalDbGz) > $($Config.LocalDbSql)"
}

function Start-DockerStack {
    Write-Step 'Starte Docker-Stack'
    $buildFlag = ''
    if (-not $NoBuild) { $buildFlag = ' --build' }
    Invoke-LoggedCommand "docker compose up -d$buildFlag" -WorkingDirectory $Config.DockerProject
}

function Reset-WordPressVolume {
    if (-not $ForceVolumeReset) { return }

    Write-Step 'Setze WordPress-Volume hart zurueck'
    Invoke-LoggedCommand "docker compose down" -WorkingDirectory $Config.DockerProject
    Invoke-LoggedCommand "docker volume rm $($Config.DockerWpVolume)" -AllowFailure
    Start-DockerStack
}

function Sync-FilesToDockerVolume {
    Write-Step 'Kopiere WordPress-Dateien ins Docker-Volume'
    $cmd = @"
docker run --rm -v $($Config.DockerWpVolume):/to -v $($Config.LocalWpExtract):/from alpine sh -lc "rm -rf /to/* /to/.[!.]* /to/..?* 2>/dev/null; cd /from && tar -cf - . | tar -xf - -C /to"
"@
    Invoke-LoggedCommand $cmd

    Write-Step 'Pruefe WordPress-Dateien im Container'
    Invoke-LoggedCommand "docker exec $($Config.DockerWebContainer) bash -lc 'ls -la /var/www/html | head -n 20'"
}

function Import-Database {
    Write-Step 'Leere lokale WordPress-Datenbank'
    Invoke-LoggedCommand "docker exec -i $($Config.DockerDbContainer) mysql -uroot -proot -e \"DROP DATABASE IF EXISTS wordpress; CREATE DATABASE wordpress CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;\""

    Write-Step 'Importiere SQL-Dump in Docker-DB'
    Invoke-LoggedCommand "docker exec -i $($Config.DockerDbContainer) mysql -uroot -proot wordpress < $($Config.LocalDbSql)"
}

function Update-WordPressUrls {
    Write-Step 'Setze WordPress-URLs auf lokal um'
    $wp = 'docker compose run --rm --user 0:0 wpcli --allow-root'
    Invoke-LoggedCommand "$wp option update home '$($Config.LocalSiteUrl)'" -WorkingDirectory $Config.DockerProject
    Invoke-LoggedCommand "$wp option update siteurl '$($Config.LocalSiteUrl)'" -WorkingDirectory $Config.DockerProject
    Invoke-LoggedCommand "$wp rewrite flush --hard" -WorkingDirectory $Config.DockerProject
}

function Disable-ProblemPlugins {
    Write-Step 'Deaktiviere bekannte Problem-Plugins per Umbenennung'
    foreach ($plugin in $Config.ProblemPlugins) {
        $target = "/var/www/html/wp-content/plugins/$plugin"
        $disabled = "/var/www/html/wp-content/plugins/_$plugin.disabled"
        $cmd = "docker exec $($Config.DockerWebContainer) bash -lc 'if [ -d \"$target\" ]; then mv \"$target\" \"$disabled\"; fi'"
        Invoke-LoggedCommand $cmd
    }
}

function Show-Status {
    Write-Step 'Status'
    Invoke-LoggedCommand "docker compose ps" -WorkingDirectory $Config.DockerProject
    Invoke-LoggedCommand "docker compose run --rm --user 0:0 wpcli --allow-root option get home" -WorkingDirectory $Config.DockerProject
    Invoke-LoggedCommand "docker compose run --rm --user 0:0 wpcli --allow-root option get siteurl" -WorkingDirectory $Config.DockerProject
}

# -----------------------------
# Main
# -----------------------------
Test-Prerequisites
New-LocalFolders

switch ($Action) {
    'files' {
        Get-LiveFiles
        Start-DockerStack
        Reset-WordPressVolume
        Sync-FilesToDockerVolume
    }
    'db' {
        Get-LiveDatabase
        Start-DockerStack
        Import-Database
    }
    'urls' {
        Start-DockerStack
        Update-WordPressUrls
        Disable-ProblemPlugins
    }
    'plugins' {
        Start-DockerStack
        Disable-ProblemPlugins
    }
    'status' {
        Show-Status
    }
    'sync' {
        if (-not $SkipFiles) { Get-LiveFiles }
        if (-not $SkipDb)    { Get-LiveDatabase }
        Start-DockerStack
        Reset-WordPressVolume
        if (-not $SkipFiles) { Sync-FilesToDockerVolume }
        if (-not $SkipDb)    { Import-Database }
        Update-WordPressUrls
        Disable-ProblemPlugins
        Show-Status
    }
}

Write-Host "`nFertig." -ForegroundColor Green
