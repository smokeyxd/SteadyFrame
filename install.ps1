# SteadyFrame installer for "irm ... | iex" (see the README). The release workflow fills in
# $version and $sha256, so only the copy attached to a GitHub release runs.

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $version = '__VERSION__'
    $sha256 = '__SHA256__'
    if ($version -notmatch '^\d+(\.\d+){1,3}$' -or $sha256 -notmatch '^[0-9a-f]{64}$') {
        Write-Host 'This is the unbuilt install.ps1 from the repo. Use the command from the README instead.' -ForegroundColor Red
        return
    }
    $release = "https://github.com/smokeyxd/SteadyFrame/releases/download/v$version"
    # full path, so nothing else named powershell.exe gets picked up
    $powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'

    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Host 'SteadyFrame needs admin rights. Accept the prompt and it opens in a new window.'
        $command = "irm '$release/install.ps1' | iex; Read-Host 'Press Enter to close'"
        try { Start-Process -FilePath $powershell -Verb RunAs -ArgumentList "-NoProfile -Command `"$command`"" }
        catch { Write-Host 'Cancelled.' -ForegroundColor Yellow }
        return
    }

    # not $env:ProgramFiles: users can set their own environment variables, and elevated processes see them
    $base = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'SteadyFrame'
    $app = Join-Path $base "SteadyFrame-$version"
    $marker = Join-Path $app '.release-sha256'
    $zip = "$app.zip"
    $part = "$app.part"
    try {
        $installed = (Test-Path -LiteralPath $marker) -and ("$(Get-Content -LiteralPath $marker -Raw)".Trim() -eq $sha256)
        if (-not $installed) {
            Write-Host "Downloading SteadyFrame $version..."
            New-Item -ItemType Directory -Path $base -Force | Out-Null
            Remove-Item -LiteralPath $zip, $part -Recurse -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri "$release/SteadyFrame-$version.zip" -OutFile $zip -UseBasicParsing
            $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($hash -ne $sha256) { throw "the download doesn't match the release (SHA256 $hash), nothing was installed" }
            Expand-Archive -LiteralPath $zip -DestinationPath $part

            # runs\ has the health reports and FPS history
            New-Item -ItemType Directory -Path $app -Force | Out-Null
            Get-ChildItem -LiteralPath $app -Force | Where-Object { $_.Name -ne 'runs' } | Remove-Item -Recurse -Force
            Get-ChildItem -LiteralPath (Join-Path $part 'SteadyFrame') -Force | Move-Item -Destination $app
            if (-not (Test-Path -LiteralPath (Join-Path $app 'runs'))) {
                $previous = Get-ChildItem -LiteralPath $base -Directory |
                    Where-Object { $_.Name -match '^SteadyFrame-\d+(\.\d+){1,3}$' -and (Test-Path -LiteralPath (Join-Path $_.FullName 'runs')) } |
                    Sort-Object { [version]($_.Name -replace '^SteadyFrame-') } -Descending |
                    Select-Object -First 1
                if ($previous) { Copy-Item -LiteralPath (Join-Path $previous.FullName 'runs') -Destination $app -Recurse }
            }
            [IO.File]::WriteAllText($marker, $sha256)
        }
        & $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $app 'SteadyFrame.ps1') -NoUpdateCheck
    } catch {
        Write-Host "SteadyFrame didn't start: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        Remove-Item -LiteralPath $zip, $part -Recurse -Force -ErrorAction SilentlyContinue
    }
}
