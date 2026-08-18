[CmdletBinding()]
param(
    [AllowEmptyString()]
    [string]$TargetDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:TrustedHost = 'developers.binance.com'
$script:MaximumRedirects = 5
$script:MaximumAttempts = 3
$script:RequestTimeout = [TimeSpan]::FromSeconds(30)
$script:ReadTimeoutMilliseconds = 30000
$script:Utf8Strict = New-Object System.Text.UTF8Encoding($false, $true)

function Get-DocumentSpecifications {
    return @(
        [pscustomobject]@{
            FileName = 'llms.txt'
            Uri = [Uri]'https://developers.binance.com/en/docs/llms.txt'
            MinimumBytes = 1KB
            MaximumBytes = 10MB
            RequiredMarkers = @(
                '# Binance Developer Docs',
                '> Documentation files for Large Language Models'
            )
        },
        [pscustomobject]@{
            FileName = 'llms-full.txt'
            Uri = [Uri]'https://developers.binance.com/en/docs/llms-full.txt'
            MinimumBytes = 100KB
            MaximumBytes = 128MB
            RequiredMarkers = @(
                '# Binance Developer Docs',
                '> Complete documentation for Large Language Models',
                '## Document:'
            )
        }
    )
}

function Assert-TrustedUri {
    param(
        [Parameter(Mandatory)]
        [Uri]$Uri
    )

    if (-not $Uri.IsAbsoluteUri -or $Uri.Scheme -ine 'https') {
        throw [System.IO.InvalidDataException]::new("Refusing non-HTTPS URL '$Uri'.")
    }

    if ($Uri.Host -ine $script:TrustedHost -or (-not $Uri.IsDefaultPort -and $Uri.Port -ne 443)) {
        throw [System.IO.InvalidDataException]::new("Refusing URL outside https://$($script:TrustedHost): '$Uri'.")
    }

    if (-not [string]::IsNullOrEmpty($Uri.UserInfo)) {
        throw [System.IO.InvalidDataException]::new("Refusing URL containing user information: '$Uri'.")
    }
}

function Resolve-TargetDirectory {
    param(
        [AllowEmptyString()]
        [Parameter(Mandatory)]
        [string]$TargetDirectory
    )

    if ([string]::IsNullOrWhiteSpace($TargetDirectory)) {
        throw [System.IO.InvalidDataException]::new('TargetDirectory is required and must be an absolute directory path.')
    }
    if (-not [System.IO.Path]::IsPathRooted($TargetDirectory)) {
        throw [System.IO.InvalidDataException]::new("TargetDirectory must be absolute: '$TargetDirectory'.")
    }

    $fullTarget = [System.IO.Path]::GetFullPath($TargetDirectory)
    if (Test-Path -LiteralPath $fullTarget -PathType Leaf) {
        throw [System.IO.InvalidDataException]::new("TargetDirectory points to a file: '$fullTarget'.")
    }

    $pathToInspect = $fullTarget
    while (-not [string]::IsNullOrEmpty($pathToInspect)) {
        if (Test-Path -LiteralPath $pathToInspect) {
            $item = Get-Item -LiteralPath $pathToInspect -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw [System.IO.InvalidDataException]::new("Refusing target path containing reparse point '$pathToInspect'.")
            }
        }

        $parent = [System.IO.Directory]::GetParent($pathToInspect)
        $pathToInspect = if ($null -eq $parent) { $null } else { $parent.FullName }
    }

    if (-not (Test-Path -LiteralPath $fullTarget)) {
        [void][System.IO.Directory]::CreateDirectory($fullTarget)
    }

    return (Get-Item -LiteralPath $fullTarget -Force).FullName
}

function Get-UpdateMutexName {
    param(
        [Parameter(Mandatory)]
        [string]$TargetDirectory
    )

    $normalizedPath = $TargetDirectory.ToUpperInvariant()
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalizedPath))
    }
    finally {
        $sha256.Dispose()
    }

    $pathToken = [System.BitConverter]::ToString($hash, 0, 16).Replace('-', '')
    return "Local\binance-llms-update-$pathToken"
}

function Assert-SafeTargetFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force
        if (-not $item.PSIsContainer -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing reparse-point target file '$Path'."
        }

        if ($item.PSIsContainer) {
            throw "Refusing target path because it is a directory: '$Path'."
        }
    }
}

function New-DocumentationHttpClient {
    Add-Type -AssemblyName System.Net.Http

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.AllowAutoRedirect = $false
    $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::None
    $handler.UseCookies = $false
    $handler.MaxResponseHeadersLength = 64

    $client = New-Object System.Net.Http.HttpClient($handler, $true)
    $client.Timeout = $script:RequestTimeout
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('binance-llms-update/1.0')
    $client.DefaultRequestHeaders.Accept.ParseAdd('text/plain')
    $client.DefaultRequestHeaders.AcceptEncoding.ParseAdd('identity')
    return $client
}

function Get-SafeHttpResponse {
    param(
        [Parameter(Mandatory)]
        [System.Net.Http.HttpClient]$Client,

        [Parameter(Mandatory)]
        [Uri]$Uri
    )

    $currentUri = $Uri
    for ($redirectCount = 0; $redirectCount -le $script:MaximumRedirects; $redirectCount++) {
        Assert-TrustedUri -Uri $currentUri

        $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $currentUri)
        try {
            $response = $Client.SendAsync(
                $request,
                [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
            ).GetAwaiter().GetResult()
        }
        finally {
            $request.Dispose()
        }

        $statusCode = [int]$response.StatusCode
        if ($statusCode -notin @(301, 302, 303, 307, 308)) {
            return $response
        }

        try {
            if ($redirectCount -eq $script:MaximumRedirects) {
                throw [System.IO.InvalidDataException]::new("Too many redirects while downloading '$Uri'.")
            }

            $location = $response.Headers.Location
            if ($null -eq $location) {
                throw [System.IO.InvalidDataException]::new("Redirect response for '$currentUri' has no Location header.")
            }

            $nextUri = if ($location.IsAbsoluteUri) {
                $location
            }
            else {
                [Uri]::new($currentUri, $location)
            }
            Assert-TrustedUri -Uri $nextUri
            $currentUri = $nextUri
        }
        finally {
            $response.Dispose()
        }
    }
}

function Test-IsTransientException {
    param(
        [Parameter(Mandatory)]
        [Exception]$Exception
    )

    $current = $Exception
    while ($null -ne $current) {
        if (
            $current -is [System.Net.Http.HttpRequestException] -or
            $current -is [System.Net.Sockets.SocketException] -or
            $current -is [System.IO.IOException] -or
            $current -is [System.Threading.Tasks.TaskCanceledException] -or
            $current -is [TimeoutException]
        ) {
            return $true
        }

        $current = $current.InnerException
    }

    return $false
}

function Start-RetryDelay {
    param(
        [Parameter(Mandatory)]
        [int]$Attempt
    )

    Start-Sleep -Seconds ([Math]::Pow(2, $Attempt - 1))
}

function Test-IsTransientStatusCode {
    param(
        [Parameter(Mandatory)]
        [int]$StatusCode
    )

    return $StatusCode -in @(408, 425, 429, 500, 502, 503, 504)
}

function Read-ResponseChunk {
    param(
        [Parameter(Mandatory)]
        [System.IO.Stream]$Stream,

        [Parameter(Mandatory)]
        [byte[]]$Buffer
    )

    $readTask = $Stream.ReadAsync($Buffer, 0, $Buffer.Length)
    if (-not $readTask.Wait($script:ReadTimeoutMilliseconds)) {
        throw [TimeoutException]::new("Response body read exceeded $($script:ReadTimeoutMilliseconds) milliseconds.")
    }

    return $readTask.GetAwaiter().GetResult()
}

function Save-ResponseBody {
    param(
        [Parameter(Mandatory)]
        [System.Net.Http.HttpResponseMessage]$Response,

        [Parameter(Mandatory)]
        [psobject]$Specification,

        [Parameter(Mandatory)]
        [string]$StagedPath
    )

    $statusCode = [int]$Response.StatusCode
    if ($statusCode -ne 200) {
        if (Test-IsTransientStatusCode -StatusCode $statusCode) {
            throw [System.Net.Http.HttpRequestException]::new("Transient HTTP $statusCode while downloading '$($Specification.Uri)'.")
        }

        throw [System.IO.InvalidDataException]::new("Unexpected HTTP $statusCode while downloading '$($Specification.Uri)'.")
    }

    $mediaType = $Response.Content.Headers.ContentType.MediaType
    if ($mediaType -ine 'text/plain') {
        throw [System.IO.InvalidDataException]::new("Unexpected Content-Type '$mediaType' for '$($Specification.Uri)'.")
    }

    $contentLength = $Response.Content.Headers.ContentLength
    if ($null -ne $contentLength -and $contentLength -gt $Specification.MaximumBytes) {
        throw [System.IO.InvalidDataException]::new("Content-Length $contentLength exceeds the $($Specification.MaximumBytes)-byte limit for '$($Specification.FileName)'.")
    }

    $inputStream = $null
    $outputStream = $null
    $bytesWritten = 0L
    try {
        $inputStream = $Response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outputStream = New-Object System.IO.FileStream(
            $StagedPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            65536,
            [System.IO.FileOptions]::SequentialScan
        )
        $buffer = New-Object byte[] 65536

        while (($bytesRead = Read-ResponseChunk -Stream $inputStream -Buffer $buffer) -gt 0) {
            $bytesWritten += $bytesRead
            if ($bytesWritten -gt $Specification.MaximumBytes) {
                throw [System.IO.InvalidDataException]::new("Response exceeds the $($Specification.MaximumBytes)-byte limit for '$($Specification.FileName)'.")
            }

            $outputStream.Write($buffer, 0, $bytesRead)
        }

        if ($null -ne $contentLength -and $bytesWritten -ne $contentLength) {
            throw [System.IO.IOException]::new("Incomplete response for '$($Specification.FileName)': expected $contentLength bytes, received $bytesWritten.")
        }

        $outputStream.Flush($true)
    }
    finally {
        if ($null -ne $outputStream) {
            $outputStream.Dispose()
        }
        if ($null -ne $inputStream) {
            $inputStream.Dispose()
        }
    }
}

function Test-StagedDocument {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [psobject]$Specification
    )

    $length = (Get-Item -LiteralPath $Path).Length
    if ($length -lt $Specification.MinimumBytes -or $length -gt $Specification.MaximumBytes) {
        throw [System.IO.InvalidDataException]::new("Invalid size $length for '$($Specification.FileName)'; expected $($Specification.MinimumBytes)..$($Specification.MaximumBytes) bytes.")
    }

    $reader = $null
    $prefix = New-Object System.Text.StringBuilder
    try {
        $reader = New-Object System.IO.StreamReader($Path, $script:Utf8Strict, $false, 65536)
        $buffer = New-Object char[] 65536
        while (($charactersRead = $reader.Read($buffer, 0, $buffer.Length)) -gt 0) {
            if ($prefix.Length -lt 65536) {
                $charactersToKeep = [Math]::Min($charactersRead, 65536 - $prefix.Length)
                [void]$prefix.Append($buffer, 0, $charactersToKeep)
            }
        }
    }
    catch [System.Text.DecoderFallbackException] {
        throw [System.IO.InvalidDataException]::new("'$($Specification.FileName)' is not valid UTF-8.", $_.Exception)
    }
    finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        }
    }

    $normalizedPrefix = $prefix.ToString().Replace("`r`n", "`n")
    foreach ($marker in $Specification.RequiredMarkers) {
        if ($normalizedPrefix.IndexOf($marker, [System.StringComparison]::Ordinal) -lt 0) {
            throw [System.IO.InvalidDataException]::new("'$($Specification.FileName)' does not contain the required marker '$marker'.")
        }
    }
}

function Save-DownloadAttempt {
    param(
        [Parameter(Mandatory)]
        [System.Net.Http.HttpClient]$Client,

        [Parameter(Mandatory)]
        [psobject]$Specification,

        [Parameter(Mandatory)]
        [string]$StagedPath
    )

    $response = $null
    try {
        $response = Get-SafeHttpResponse -Client $Client -Uri $Specification.Uri
        Save-ResponseBody -Response $response -Specification $Specification -StagedPath $StagedPath
        Test-StagedDocument -Path $StagedPath -Specification $Specification
    }
    finally {
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
}

function Invoke-DocumentDownload {
    param(
        [Parameter(Mandatory)]
        [System.Net.Http.HttpClient]$Client,

        [Parameter(Mandatory)]
        [psobject]$Specification,

        [Parameter(Mandatory)]
        [string]$TargetDirectory
    )

    for ($attempt = 1; $attempt -le $script:MaximumAttempts; $attempt++) {
        $stagedPath = Join-Path $TargetDirectory ('.{0}.{1}.download' -f $Specification.FileName, [Guid]::NewGuid().ToString('N'))
        try {
            Save-DownloadAttempt -Client $Client -Specification $Specification -StagedPath $stagedPath
            return $stagedPath
        }
        catch {
            if (Test-Path -LiteralPath $stagedPath) {
                Remove-Item -LiteralPath $stagedPath -Force
            }

            if ($attempt -eq $script:MaximumAttempts -or -not (Test-IsTransientException -Exception $_.Exception)) {
                throw
            }

            Start-RetryDelay -Attempt $attempt
        }
    }
}

function Test-FileContentEqual {
    param(
        [Parameter(Mandatory)]
        [string]$FirstPath,

        [Parameter(Mandatory)]
        [string]$SecondPath
    )

    if (-not (Test-Path -LiteralPath $FirstPath -PathType Leaf)) {
        return $false
    }

    $first = Get-Item -LiteralPath $FirstPath
    $second = Get-Item -LiteralPath $SecondPath
    if ($first.Length -ne $second.Length) {
        return $false
    }

    return (Get-FileHash -LiteralPath $FirstPath -Algorithm SHA256).Hash -eq
        (Get-FileHash -LiteralPath $SecondPath -Algorithm SHA256).Hash
}

function Move-StagedFile {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [AllowNull()]
        [string]$BackupPath
    )

    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        [System.IO.File]::Replace($Source, $Destination, $BackupPath)
    }
    else {
        [System.IO.File]::Move($Source, $Destination)
    }
}

function Restore-BackupFile {
    param(
        [AllowNull()]
        [string]$BackupPath,

        [Parameter(Mandatory)]
        [string]$TargetPath
    )

    if ($null -eq $BackupPath) {
        if (Test-Path -LiteralPath $TargetPath) {
            Remove-Item -LiteralPath $TargetPath -Force
        }
        return
    }

    if (Test-Path -LiteralPath $TargetPath -PathType Leaf) {
        $discardedPath = Join-Path ([System.IO.Path]::GetDirectoryName($TargetPath)) ('.{0}.{1}.rollback' -f [System.IO.Path]::GetFileName($TargetPath), [Guid]::NewGuid().ToString('N'))
        try {
            [System.IO.File]::Replace($BackupPath, $TargetPath, $discardedPath)
        }
        finally {
            if (Test-Path -LiteralPath $discardedPath) {
                Remove-Item -LiteralPath $discardedPath -Force
            }
        }
    }
    else {
        [System.IO.File]::Move($BackupPath, $TargetPath)
    }
}

function Install-StagedDocuments {
    param(
        [Parameter(Mandatory)]
        [array]$Entries
    )

    $changedEntries = @($Entries | Where-Object { $_.Changed })
    $committedEntries = New-Object System.Collections.Generic.List[object]

    try {
        foreach ($entry in $changedEntries) {
            $entry | Add-Member -NotePropertyName BackupPath -NotePropertyValue $null -Force
            if (Test-Path -LiteralPath $entry.TargetPath -PathType Leaf) {
                $entry.BackupPath = Join-Path ([System.IO.Path]::GetDirectoryName($entry.TargetPath)) ('.{0}.{1}.backup' -f [System.IO.Path]::GetFileName($entry.TargetPath), [Guid]::NewGuid().ToString('N'))
            }
        }

        foreach ($entry in $changedEntries) {
            Move-StagedFile -Source $entry.StagedPath -Destination $entry.TargetPath -BackupPath $entry.BackupPath
            $committedEntries.Add($entry)
        }
    }
    catch {
        $commitError = $_
        for ($index = $committedEntries.Count - 1; $index -ge 0; $index--) {
            $entry = $committedEntries[$index]
            Restore-BackupFile -BackupPath $entry.BackupPath -TargetPath $entry.TargetPath
            $entry.BackupPath = $null
        }
        throw $commitError
    }
    finally {
        foreach ($entry in $changedEntries) {
            if ($entry.PSObject.Properties.Name -contains 'BackupPath' -and
                $null -ne $entry.BackupPath -and
                (Test-Path -LiteralPath $entry.BackupPath)) {
                Remove-Item -LiteralPath $entry.BackupPath -Force
            }
        }
    }
}

function Invoke-BinanceLlmsUpdate {
    param(
        [Parameter(Mandatory)]
        [string]$TargetDirectory
    )

    if ($env:OS -ne 'Windows_NT') {
        throw 'This updater supports Windows only.'
    }

    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12

    $resolvedTargetDirectory = Resolve-TargetDirectory -TargetDirectory $TargetDirectory

    $mutexName = Get-UpdateMutexName -TargetDirectory $resolvedTargetDirectory
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)
    $mutexAcquired = $false
    $client = $null
    $entries = New-Object System.Collections.Generic.List[object]
    try {
        try {
            $mutexAcquired = $mutex.WaitOne(0)
        }
        catch [System.Threading.AbandonedMutexException] {
            $mutexAcquired = $true
        }
        if (-not $mutexAcquired) {
            throw 'Another Binance LLM documentation update is already running.'
        }

        $client = New-DocumentationHttpClient
        foreach ($specification in Get-DocumentSpecifications) {
            $targetPath = Join-Path $resolvedTargetDirectory $specification.FileName
            Assert-SafeTargetFile -Path $targetPath
            $stagedPath = Invoke-DocumentDownload -Client $client -Specification $specification -TargetDirectory $resolvedTargetDirectory
            $changed = -not (Test-FileContentEqual -FirstPath $targetPath -SecondPath $stagedPath)
            $entries.Add([pscustomobject]@{
                FileName = $specification.FileName
                TargetPath = $targetPath
                StagedPath = $stagedPath
                Changed = $changed
            })
        }

        Install-StagedDocuments -Entries $entries.ToArray()
        foreach ($entry in $entries) {
            if ($entry.Changed) {
                "{0}: updated" -f $entry.FileName
            }
            else {
                "{0}: unchanged" -f $entry.FileName
            }
        }
        "Binance LLM documentation update completed successfully in '$resolvedTargetDirectory'."
    }
    finally {
        foreach ($entry in $entries) {
            if (Test-Path -LiteralPath $entry.StagedPath) {
                Remove-Item -LiteralPath $entry.StagedPath -Force
            }
        }
        if ($null -ne $client) {
            $client.Dispose()
        }
        if ($mutexAcquired) {
            $mutex.ReleaseMutex()
        }
        $mutex.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if ([string]::IsNullOrWhiteSpace($TargetDirectory)) {
        throw 'TargetDirectory is required. Pass an explicit absolute directory path with -TargetDirectory.'
    }

    Invoke-BinanceLlmsUpdate -TargetDirectory $TargetDirectory
}
