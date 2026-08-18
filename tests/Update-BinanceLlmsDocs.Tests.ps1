[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$updaterPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\scripts\Update-BinanceLlmsDocs.ps1'))
. $updaterPath

$script:TestsRun = 0

function Assert-True {
    param(
        [Parameter(Mandatory)]
        [bool]$Condition,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param(
        [AllowNull()]
        [object]$Expected,

        [AllowNull()]
        [object]$Actual,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message. Expected '$Expected', received '$Actual'."
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [Parameter(Mandatory)]
        [Type]$ExceptionType,

        [string]$MessageFragment
    )

    try {
        & $Action
    }
    catch {
        $exception = $_.Exception
        while ($null -ne $exception -and -not $ExceptionType.IsInstanceOfType($exception)) {
            $exception = $exception.InnerException
        }

        if ($null -eq $exception) {
            throw "Expected exception type '$($ExceptionType.FullName)', received '$($_.Exception.GetType().FullName)'."
        }
        if (-not [string]::IsNullOrEmpty($MessageFragment) -and
            $exception.Message.IndexOf($MessageFragment, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) {
            throw "Expected exception message containing '$MessageFragment', received '$($exception.Message)'."
        }
        return
    }

    throw "Expected exception type '$($ExceptionType.FullName)', but no exception was thrown."
}

function Invoke-Test {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    & $Action
    $script:TestsRun++
    "PASS: $Name"
}

function New-TestDirectory {
    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('binance-llms-update-tests-{0}' -f [Guid]::NewGuid().ToString('N'))
    [void][System.IO.Directory]::CreateDirectory($path)
    return $path
}

function Write-Utf8Text {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Content
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

Invoke-Test -Name 'accepts fixed official HTTPS URLs' -Action {
    foreach ($specification in Get-DocumentSpecifications) {
        Assert-TrustedUri -Uri $specification.Uri
    }
}

Invoke-Test -Name 'rejects untrusted schemes, hosts, ports, and user information' -Action {
    Assert-Throws -Action { Assert-TrustedUri -Uri ([Uri]'http://developers.binance.com/en/docs/llms.txt') } -ExceptionType ([System.IO.InvalidDataException]) -MessageFragment 'non-HTTPS'
    Assert-Throws -Action { Assert-TrustedUri -Uri ([Uri]'https://example.com/en/docs/llms.txt') } -ExceptionType ([System.IO.InvalidDataException]) -MessageFragment 'outside'
    Assert-Throws -Action { Assert-TrustedUri -Uri ([Uri]'https://developers.binance.com:8443/en/docs/llms.txt') } -ExceptionType ([System.IO.InvalidDataException]) -MessageFragment 'outside'
    Assert-Throws -Action { Assert-TrustedUri -Uri ([Uri]'https://user@developers.binance.com/en/docs/llms.txt') } -ExceptionType ([System.IO.InvalidDataException]) -MessageFragment 'user information'
}

Invoke-Test -Name 'requires an explicit absolute target directory' -Action {
    Assert-Throws -Action { Resolve-TargetDirectory -TargetDirectory '' } -ExceptionType ([System.IO.InvalidDataException]) -MessageFragment 'required'
    Assert-Throws -Action { Resolve-TargetDirectory -TargetDirectory 'docs\binance' } -ExceptionType ([System.IO.InvalidDataException]) -MessageFragment 'must be absolute'
}

Invoke-Test -Name 'creates and returns the exact requested target directory' -Action {
    $testDirectory = New-TestDirectory
    try {
        $targetDirectory = Join-Path $testDirectory 'nested\binance-docs'
        $resolvedDirectory = Resolve-TargetDirectory -TargetDirectory $targetDirectory

        Assert-Equal -Expected ([System.IO.Path]::GetFullPath($targetDirectory)) -Actual $resolvedDirectory -Message 'The resolved target should match the requested absolute path'
        Assert-True -Condition ([System.IO.Directory]::Exists($targetDirectory)) -Message 'The requested target directory should be created'
    }
    finally {
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}

Invoke-Test -Name 'rejects a target directory path that points to a file' -Action {
    $testDirectory = New-TestDirectory
    try {
        $filePath = Join-Path $testDirectory 'not-a-directory.txt'
        [System.IO.File]::WriteAllText($filePath, 'content')
        Assert-Throws -Action { Resolve-TargetDirectory -TargetDirectory $filePath } -ExceptionType ([System.IO.InvalidDataException]) -MessageFragment 'points to a file'
    }
    finally {
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}

Invoke-Test -Name 'scopes the update mutex to the resolved target directory' -Action {
    $testDirectory = New-TestDirectory
    try {
        $firstPath = Join-Path $testDirectory 'first'
        $secondPath = Join-Path $testDirectory 'second'
        $firstName = Get-UpdateMutexName -TargetDirectory $firstPath

        Assert-Equal -Expected $firstName -Actual (Get-UpdateMutexName -TargetDirectory $firstPath.ToLowerInvariant()) -Message 'Mutex names should be case-insensitive on Windows'
        Assert-True -Condition ($firstName -ne (Get-UpdateMutexName -TargetDirectory $secondPath)) -Message 'Different target directories should use different mutexes'
    }
    finally {
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}

Invoke-Test -Name 'script invocation fails instead of choosing a default target directory' -Action {
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = (Get-Command powershell.exe).Source
    $startInfo.Arguments = "-NoLogo -NoProfile -File `"$updaterPath`""
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $output = $process.StandardOutput.ReadToEnd() + $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $exitCode = $process.ExitCode
    }
    finally {
        $process.Dispose()
    }

    Assert-True -Condition ($exitCode -ne 0) -Message 'Invoking the updater without TargetDirectory should fail'
    Assert-True -Condition ($output.IndexOf('TargetDirectory is required', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -Message 'The failure should explain the required parameter'
}

Invoke-Test -Name 'validates a correctly structured summary document' -Action {
    $testDirectory = New-TestDirectory
    try {
        $specification = (Get-DocumentSpecifications)[0]
        $path = Join-Path $testDirectory $specification.FileName
        $content = "# Binance Developer Docs`n`n> Documentation files for Large Language Models`n`n" + ('- [Document](/en/docs/example.md)' * 64)
        Write-Utf8Text -Path $path -Content $content

        Test-StagedDocument -Path $path -Specification $specification
    }
    finally {
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}

Invoke-Test -Name 'rejects HTML and invalid UTF-8 documents' -Action {
    $testDirectory = New-TestDirectory
    try {
        $specification = (Get-DocumentSpecifications)[0]
        $htmlPath = Join-Path $testDirectory 'html.txt'
        Write-Utf8Text -Path $htmlPath -Content ('<html><body>gateway error</body></html>' * 64)
        Assert-Throws -Action { Test-StagedDocument -Path $htmlPath -Specification $specification } -ExceptionType ([System.IO.InvalidDataException]) -MessageFragment 'required marker'

        $invalidPath = Join-Path $testDirectory 'invalid.txt'
        $validText = "# Binance Developer Docs`n`n> Documentation files for Large Language Models`n`n" + ('A' * 2048)
        [byte[]]$bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($validText)
        $bytes[$bytes.Length - 1] = 0xFF
        [System.IO.File]::WriteAllBytes($invalidPath, $bytes)
        Assert-Throws -Action { Test-StagedDocument -Path $invalidPath -Specification $specification } -ExceptionType ([System.IO.InvalidDataException]) -MessageFragment 'valid UTF-8'
    }
    finally {
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}

Invoke-Test -Name 'rejects files outside configured size limits' -Action {
    $testDirectory = New-TestDirectory
    try {
        $path = Join-Path $testDirectory 'oversized.txt'
        Write-Utf8Text -Path $path -Content ('A' * 65)
        $specification = [pscustomobject]@{
            FileName = 'oversized.txt'
            MinimumBytes = 1
            MaximumBytes = 64
            RequiredMarkers = @('A')
        }
        Assert-Throws -Action { Test-StagedDocument -Path $path -Specification $specification } -ExceptionType ([System.IO.InvalidDataException]) -MessageFragment 'Invalid size'
    }
    finally {
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}

Invoke-Test -Name 'classifies transient HTTP failures and rejects permanent HTTP failures' -Action {
    Add-Type -AssemblyName System.Net.Http
    $testDirectory = New-TestDirectory
    try {
        $specification = (Get-DocumentSpecifications)[0]
        $path = Join-Path $testDirectory 'response.txt'

        $transientResponse = New-Object System.Net.Http.HttpResponseMessage([System.Net.HttpStatusCode]::ServiceUnavailable)
        try {
            Assert-Throws -Action { Save-ResponseBody -Response $transientResponse -Specification $specification -StagedPath $path } -ExceptionType ([System.Net.Http.HttpRequestException]) -MessageFragment 'Transient HTTP 503'
        }
        finally {
            $transientResponse.Dispose()
        }

        $permanentResponse = New-Object System.Net.Http.HttpResponseMessage([System.Net.HttpStatusCode]::NotFound)
        try {
            Assert-Throws -Action { Save-ResponseBody -Response $permanentResponse -Specification $specification -StagedPath $path } -ExceptionType ([System.IO.InvalidDataException]) -MessageFragment 'Unexpected HTTP 404'
        }
        finally {
            $permanentResponse.Dispose()
        }
    }
    finally {
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}

Invoke-Test -Name 'rejects an incomplete response body' -Action {
    Add-Type -AssemblyName System.Net.Http
    $testDirectory = New-TestDirectory
    try {
        $specification = [pscustomobject]@{
            FileName = 'partial.txt'
            Uri = [Uri]'https://developers.binance.com/en/docs/llms.txt'
            MinimumBytes = 1
            MaximumBytes = 1MB
            RequiredMarkers = @('content')
        }
        $path = Join-Path $testDirectory 'partial.txt'
        $response = New-Object System.Net.Http.HttpResponseMessage([System.Net.HttpStatusCode]::OK)
        $response.Content = New-Object System.Net.Http.ByteArrayContent(,[System.Text.Encoding]::UTF8.GetBytes('content'))
        $response.Content.Headers.ContentType = New-Object System.Net.Http.Headers.MediaTypeHeaderValue('text/plain')
        $response.Content.Headers.ContentLength = 99
        try {
            Assert-Throws -Action { Save-ResponseBody -Response $response -Specification $specification -StagedPath $path } -ExceptionType ([System.IO.IOException]) -MessageFragment 'Incomplete response'
        }
        finally {
            $response.Dispose()
        }
    }
    finally {
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}

Invoke-Test -Name 'retries transient download failures without retaining partial files' -Action {
    Add-Type -AssemblyName System.Net.Http
    $testDirectory = New-TestDirectory
    $originalDownloadAttempt = (Get-Item Function:Save-DownloadAttempt).ScriptBlock
    $originalRetryDelay = (Get-Item Function:Start-RetryDelay).ScriptBlock
    $client = New-DocumentationHttpClient
    try {
        $script:DownloadAttempts = 0
        Set-Item Function:Save-DownloadAttempt -Value {
            param($Client, $Specification, $StagedPath)
            $script:DownloadAttempts++
            if ($script:DownloadAttempts -lt 3) {
                [System.IO.File]::WriteAllText($StagedPath, 'partial')
                throw [System.Net.Http.HttpRequestException]::new('temporary failure')
            }
            [System.IO.File]::WriteAllText($StagedPath, 'complete')
        }
        Set-Item Function:Start-RetryDelay -Value { param($Attempt) }

        $specification = (Get-DocumentSpecifications)[0]
        $stagedPath = Invoke-DocumentDownload -Client $client -Specification $specification -TargetDirectory $testDirectory
        Assert-Equal -Expected 3 -Actual $script:DownloadAttempts -Message 'Transient failures should be retried'
        Assert-Equal -Expected 'complete' -Actual ([System.IO.File]::ReadAllText($stagedPath)) -Message 'The successful attempt should be returned'
        Assert-Equal -Expected 1 -Actual ([System.IO.Directory]::GetFiles($testDirectory).Count) -Message 'Failed attempt files should be removed'
    }
    finally {
        Set-Item Function:Save-DownloadAttempt -Value $originalDownloadAttempt
        Set-Item Function:Start-RetryDelay -Value $originalRetryDelay
        $client.Dispose()
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}

Invoke-Test -Name 'commits both staged documents successfully' -Action {
    $testDirectory = New-TestDirectory
    try {
        $firstTarget = Join-Path $testDirectory 'first.txt'
        $secondTarget = Join-Path $testDirectory 'second.txt'
        $firstStage = Join-Path $testDirectory 'first.stage'
        $secondStage = Join-Path $testDirectory 'second.stage'
        [System.IO.File]::WriteAllText($firstTarget, 'first-old')
        [System.IO.File]::WriteAllText($secondTarget, 'second-old')
        [System.IO.File]::WriteAllText($firstStage, 'first-new')
        [System.IO.File]::WriteAllText($secondStage, 'second-new')
        $entries = @(
            [pscustomobject]@{ Changed = $true; TargetPath = $firstTarget; StagedPath = $firstStage },
            [pscustomobject]@{ Changed = $true; TargetPath = $secondTarget; StagedPath = $secondStage }
        )

        Install-StagedDocuments -Entries $entries

        Assert-Equal -Expected 'first-new' -Actual ([System.IO.File]::ReadAllText($firstTarget)) -Message 'The first target should be updated'
        Assert-Equal -Expected 'second-new' -Actual ([System.IO.File]::ReadAllText($secondTarget)) -Message 'The second target should be updated'
        Assert-Equal -Expected 0 -Actual ([System.IO.Directory]::GetFiles($testDirectory, '*.backup').Count) -Message 'Backup files should be removed'
    }
    finally {
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}

Invoke-Test -Name 'rolls back the first replacement when the second replacement fails' -Action {
    $testDirectory = New-TestDirectory
    $originalMoveStagedFile = (Get-Item Function:Move-StagedFile).ScriptBlock
    try {
        $firstTarget = Join-Path $testDirectory 'first.txt'
        $secondTarget = Join-Path $testDirectory 'second.txt'
        $firstStage = Join-Path $testDirectory 'first.stage'
        $secondStage = Join-Path $testDirectory 'second.stage'
        [System.IO.File]::WriteAllText($firstTarget, 'first-old')
        [System.IO.File]::WriteAllText($secondTarget, 'second-old')
        [System.IO.File]::WriteAllText($firstStage, 'first-new')
        [System.IO.File]::WriteAllText($secondStage, 'second-new')
        $entries = @(
            [pscustomobject]@{ Changed = $true; TargetPath = $firstTarget; StagedPath = $firstStage },
            [pscustomobject]@{ Changed = $true; TargetPath = $secondTarget; StagedPath = $secondStage }
        )

        $script:MoveCalls = 0
        $script:OriginalMoveStagedFile = $originalMoveStagedFile
        Set-Item Function:Move-StagedFile -Value {
            param($Source, $Destination, $BackupPath)
            $script:MoveCalls++
            if ($script:MoveCalls -eq 2) {
                throw [System.IO.IOException]::new('simulated commit failure')
            }
            & $script:OriginalMoveStagedFile -Source $Source -Destination $Destination -BackupPath $BackupPath
        }

        Assert-Throws -Action { Install-StagedDocuments -Entries $entries } -ExceptionType ([System.IO.IOException]) -MessageFragment 'simulated commit failure'
        Assert-Equal -Expected 'first-old' -Actual ([System.IO.File]::ReadAllText($firstTarget)) -Message 'The first target should be rolled back'
        Assert-Equal -Expected 'second-old' -Actual ([System.IO.File]::ReadAllText($secondTarget)) -Message 'The second target should remain unchanged'
        Assert-Equal -Expected 0 -Actual ([System.IO.Directory]::GetFiles($testDirectory, '*.backup').Count) -Message 'Backup files should be removed after rollback'
    }
    finally {
        Set-Item Function:Move-StagedFile -Value $originalMoveStagedFile
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}

"All $script:TestsRun binance-llms-update tests passed."
