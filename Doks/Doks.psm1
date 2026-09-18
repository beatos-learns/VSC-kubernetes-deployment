#Requires -Version 5.1
<#
.SYNOPSIS
    Doks - DigitalOcean Kubernetes (DOKS) clusters from PowerShell.

.DESCRIPTION

    ONE-TIME SETUP
        Import-Module .\Doks
        Set-DoksToken                      # paste the API token once -> Credential Manager
        Test-DoksSetup                     # doctl/kubectl/token/API all green?

    DAILY USE
        New-DoksCluster | Sync-DoksTerraform | Bootstrap-DoksCluster; Connect-DoksPortForward
                                           # the whole startup of a fresh cluster in one line
        New-DoksCluster                    # create (fra1, 2x s-2vcpu-4gb, autoscale 2-5), wait, connect
        Sync-DoksTerraform                 # terraform.tfvars = this cluster, state, init + apply (managed database)
        Bootstrap-DoksCluster              # GitOps handover: secrets from terraform output, ArgoCD, root app, LB IP into the nip.io hosts
        Connect-DoksPortForward            # ArgoCD, Grafana, Prometheus, Alertmanager on localhost, with credentials
        Test-DoksStack                     # verification in order: GitOps, TLS, front door, policies, monitoring, module assignment, parallel users (-LoadTest adds k6)
        Start-DoksLoadTest                 # k6 load test from loadtest/ against staging or prod, followed to the end
        Get-DoksCluster                    # what is running (= what is billing) right now
        Use-DoksCluster k8s-test-fra1      # point this window at an existing cluster
        Disconnect-DoksCluster             # forget the cluster in this window
        Remove-DoksCluster k8s-test-fra1   # delete cluster + its load balancers/volumes + local kubeconfig

    DEFAULTS
        Get-DoksDefault
        Set-DoksDefault                    # for this session; put it in $PROFILE to keep it

.NOTES
    Requires doctl and kubectl on PATH (helm too for Bootstrap-DoksCluster).
    Works in Windows PowerShell 5.1 and PowerShell 7.
#>

# ---------------------------------------------------------------------------
# Module state
# ---------------------------------------------------------------------------

$script:UserDir = Join-Path -Path $HOME -ChildPath '.doks'
$script:Defaults = [ordered]@{
    Region           = 'fra1'
    Size             = 's-2vcpu-2gb'
    Count            = 2
    MinNodes         = 2
    MaxNodes         = 10
    Version          = 'latest'
    Tag              = 'doks-temp'
    KubeconfigDir    = (Join-Path -Path $PSScriptRoot -ChildPath 'kubeconfig')
    CredentialTarget = 'Doks/DigitalOcean-API-Token'
}
$script:DefaultSources = New-Object System.Collections.Generic.List[string]

$script:AuthVerified  = $false
$script:ApiToken      = $null   # exported to doctl per invocation only (Invoke-Doctl), never to the session
$script:ToolPaths     = @{}
$script:IsWindowsHost = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)

function Set-DoksDefaultValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Source,
        [string]$BaseDir
    )
    if (-not $script:Defaults.Contains($Key)) {
        Write-Warning "Doks: ignoring unknown setting '$Key' from $Source. Valid settings: $($script:Defaults.Keys -join ', ')."
        return
    }
    if ($script:Defaults[$Key] -is [int]) {
        try { $Value = [int]$Value }
        catch { Write-Warning "Doks: '$Key' from $Source must be a whole number (got '$Value'); ignored."; return }
    }
    elseif ($Key -eq 'KubeconfigDir') {
        $Value = "$Value"
        if (-not $Value) { Write-Warning "Doks: empty KubeconfigDir from $Source ignored."; return }
        if ($BaseDir -and -not [System.IO.Path]::IsPathRooted($Value) -and -not $Value.StartsWith('~')) {
            $Value = Join-Path -Path $BaseDir -ChildPath $Value
        }
        $Value = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Value)
    }
    elseif ($Key -eq 'Tag') {
        $Value = (@($Value) | Where-Object { "$_" }) -join ','
    }
    else {
        $Value = "$Value"
    }
    $script:Defaults[$Key] = $Value
}

function Import-DoksDefaultsFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    try { $data = Import-PowerShellDataFile -LiteralPath $Path -ErrorAction Stop }
    catch { Write-Warning "Doks: could not read $Label defaults file $Path - $($_.Exception.Message)"; return }
    $baseDir = Split-Path -Path $Path -Parent
    foreach ($key in @($data.Keys)) {
        Set-DoksDefaultValue -Key $key -Value $data[$key] -Source "$Label defaults file $Path" -BaseDir $baseDir
    }
    $script:DefaultSources.Add("$Label defaults file: $Path")
}

function Import-DoksDefaultsFromEnv {
    foreach ($key in @($script:Defaults.Keys)) {
        $envName = 'DOKS_' + (($key -creplace '(?<=[a-z0-9])(?=[A-Z])', '_').ToUpperInvariant())
        $value = [System.Environment]::GetEnvironmentVariable($envName)
        if ($null -ne $value -and $value -ne '') {
            Set-DoksDefaultValue -Key $key -Value $value -Source "`$env:$envName"
            $script:DefaultSources.Add("`$env:$envName")
        }
    }
}

Update-TypeData -TypeName 'Doks.Cluster' -DefaultDisplayPropertySet Name, State, Nodes, Age -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Windows Credential Manager
# ---------------------------------------------------------------------------

$script:CredManSource = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Doks
{
    public static class CredentialManager
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public uint   Flags;
            public uint   Type;
            public string TargetName;
            public string Comment;
            public uint   LastWrittenLow;
            public uint   LastWrittenHigh;
            public uint   CredentialBlobSize;
            public IntPtr CredentialBlob;
            public uint   Persist;
            public uint   AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        private const uint CRED_TYPE_GENERIC = 1;
        private const uint CRED_PERSIST_LOCAL_MACHINE = 2;
        private const int ERROR_NOT_FOUND = 1168;

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, uint type, uint reservedFlag, out IntPtr credentialPtr);

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWrite([In] ref CREDENTIAL userCredential, uint flags);

        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredDelete(string target, uint type, uint flags);

        [DllImport("advapi32.dll", EntryPoint = "CredFree")]
        private static extern void CredFree(IntPtr cred);

        private static Exception Fail(string operation, int error)
        {
            return new InvalidOperationException(string.Format("Windows Credential Manager {0} failed with Win32 error {1}.", operation, error));
        }

        // Returns { userName, secret } or null when no such entry exists.
        public static string[] Read(string target)
        {
            IntPtr ptr;
            if (!CredRead(target, CRED_TYPE_GENERIC, 0, out ptr))
            {
                int err = Marshal.GetLastWin32Error();
                if (err == ERROR_NOT_FOUND) return null;
                throw Fail("read", err);
            }
            try
            {
                CREDENTIAL cred = (CREDENTIAL)Marshal.PtrToStructure(ptr, typeof(CREDENTIAL));
                string secret = string.Empty;
                if (cred.CredentialBlobSize > 0 && cred.CredentialBlob != IntPtr.Zero)
                {
                    secret = Marshal.PtrToStringUni(cred.CredentialBlob, (int)cred.CredentialBlobSize / 2);
                }
                return new string[] { cred.UserName, secret };
            }
            finally
            {
                CredFree(ptr);
            }
        }

        public static void Write(string target, string userName, string secret, string comment)
        {
            byte[] blob = Encoding.Unicode.GetBytes(secret);
            if (blob.Length > 2560)
            {
                throw new ArgumentException("Secret exceeds the Credential Manager limit of 2560 bytes.");
            }
            CREDENTIAL cred = new CREDENTIAL();
            cred.Type = CRED_TYPE_GENERIC;
            cred.TargetName = target;
            cred.UserName = userName;
            cred.Comment = comment;
            cred.Persist = CRED_PERSIST_LOCAL_MACHINE;
            cred.CredentialBlobSize = (uint)blob.Length;
            cred.CredentialBlob = Marshal.AllocHGlobal(blob.Length);
            try
            {
                Marshal.Copy(blob, 0, cred.CredentialBlob, blob.Length);
                if (!CredWrite(ref cred, 0))
                {
                    throw Fail("write", Marshal.GetLastWin32Error());
                }
            }
            finally
            {
                Marshal.FreeHGlobal(cred.CredentialBlob);
            }
        }

        // True when an entry was deleted, false when there was none.
        public static bool Delete(string target)
        {
            if (CredDelete(target, CRED_TYPE_GENERIC, 0)) return true;
            int err = Marshal.GetLastWin32Error();
            if (err == ERROR_NOT_FOUND) return false;
            throw Fail("delete", err);
        }
    }
}
'@

function Get-DoksCredManType {
    if (-not $script:IsWindowsHost) {
        throw 'Windows Credential Manager is only available on Windows. Set $env:DIGITALOCEAN_ACCESS_TOKEN for this session instead.'
    }
    $type = 'Doks.CredentialManager' -as [type]
    if (-not $type) {
        Add-Type -TypeDefinition $script:CredManSource -ErrorAction Stop
        $type = 'Doks.CredentialManager' -as [type]
    }
    $type
}

# ---------------------------------------------------------------------------
# Token store: Windows Credential Manager, or ~/.doks/token elsewhere
# ---------------------------------------------------------------------------

function Get-DoksUserDir {
    if (-not (Test-Path -LiteralPath $script:UserDir -PathType Container)) {
        New-Item -ItemType Directory -Path $script:UserDir -Force | Out-Null
    }
    $script:UserDir
}

function Get-DoksTokenFilePath {
    Join-Path -Path (Get-DoksUserDir) -ChildPath 'token'
}

function Get-DoksTokenStoreName {
    if ($script:IsWindowsHost) { return "Windows Credential Manager ('$($script:Defaults.CredentialTarget)')" }
    "token file $(Get-DoksTokenFilePath)"
}

function Read-DoksStoredToken {
    if ($script:IsWindowsHost) {
        $cm = Get-DoksCredManType
        $entry = $cm::Read($script:Defaults.CredentialTarget)
        if (-not $entry) { return $null }
        return [pscustomobject]@{ User = $entry[0]; Token = $entry[1] }
    }
    $file = Get-DoksTokenFilePath
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $null }
    $token = ([System.IO.File]::ReadAllText($file)).Trim()
    if (-not $token) { return $null }
    [pscustomobject]@{ User = 'token file'; Token = $token }
}

function Write-DoksStoredToken {
    param([Parameter(Mandatory)][string]$User, [Parameter(Mandatory)][string]$Token)
    if ($script:IsWindowsHost) {
        $cm = Get-DoksCredManType
        $cm::Write($script:Defaults.CredentialTarget, $User, $Token, 'DigitalOcean API token used by the Doks PowerShell module')
        return
    }
    $file = Get-DoksTokenFilePath
    $chmod = Get-Command -Name chmod -CommandType Application -ErrorAction SilentlyContinue
    if ($chmod) { & $chmod.Source 700 (Split-Path -Path $file -Parent) }
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { [System.IO.File]::WriteAllText($file, '') }
    if ($chmod) { & $chmod.Source 600 $file }   # lock the file down before the token lands in it
    [System.IO.File]::WriteAllText($file, $Token + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Remove-DoksStoredToken {
    if ($script:IsWindowsHost) {
        $cm = Get-DoksCredManType
        return $cm::Delete($script:Defaults.CredentialTarget)
    }
    $file = Get-DoksTokenFilePath
    if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file -Force; return $true }
    $false
}

function ConvertFrom-DoksSecureString {
    param([Parameter(Mandatory)][securestring]$SecureString)
    [System.Net.NetworkCredential]::new('', $SecureString).Password
}

# ---------------------------------------------------------------------------
# Native tool plumbing
# ---------------------------------------------------------------------------

function Get-DoksTool {
    param([Parameter(Mandatory)][ValidateSet('doctl', 'kubectl', 'helm', 'terraform')][string]$Name)
    if ($script:ToolPaths[$Name]) { return $script:ToolPaths[$Name] }
    $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) {
        $hint = switch ($Name) {
            'doctl'   { 'https://docs.digitalocean.com/reference/doctl/how-to/install/' }
            'kubectl' { 'https://kubernetes.io/docs/tasks/tools/' }
            'helm'    { 'https://helm.sh/docs/intro/install/' }
            'terraform' { 'https://developer.hashicorp.com/terraform/install' }
        }
        throw "'$Name' was not found on PATH. Install it ($hint) and open a new PowerShell window."
    }
    $script:ToolPaths[$Name] = $cmd.Source
    $cmd.Source
}

function Get-DoksErrorText {
    param([AllowEmptyString()][string]$Text)
    $trimmed = "$Text".Trim()
    if ($trimmed.StartsWith('{')) {
        try {
            $obj = ConvertFrom-Json -InputObject $trimmed
            if ($obj.errors) {
                $details = @($obj.errors | ForEach-Object { $_.detail } | Where-Object { $_ })
                if ($details.Count -gt 0) { return ($details -join '; ') }
            }
        } catch { }
    }
    $trimmed -replace '^Error:\s*', ''
}

# Pipeline sink for terraform output: the "<resource>: Still creating... [1m20s elapsed]"
# ticks become one dotted line per set of resources in flight (like Wait-DoksNodeReady),
# one dot per tick; every other line passes through unchanged.
function Write-DoksTerraformProgress {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline)][AllowNull()]$InputObject)
    begin {
        $inFlight = [ordered]@{}   # resource -> verb (creating, destroying, ...)
        $header   = $null
    }
    process {
        $line = [string]$InputObject
        if ($line -match '^(?<resource>\S+): Still (?<verb>\w+)\.\.\. \[') {
            $first = -not $inFlight.Contains($Matches.resource) -or $Matches.resource -eq @($inFlight.Keys)[0]
            $inFlight[$Matches.resource] = $Matches.verb
            $verbs = @($inFlight.Values | Select-Object -Unique) -join '/'
            $next  = "  still $verbs $($inFlight.Keys -join ', ') "
            if ($next -ne $header) {
                if ($header) { Write-Host '' }
                Write-Host $next -NoNewline
                $header = $next
            }
            if ($first) { Write-Host '.' -NoNewline }
            return
        }
        if ($header) { Write-Host ''; $header = $null }
        if ($line -match '^(?<resource>\S+): (?<verb>\w+)\.\.\.$') { $inFlight[$Matches.resource] = $Matches.verb.ToLowerInvariant() }
        elseif ($line -match '^(?<resource>\S+): \w+ complete after ') { $inFlight.Remove($Matches.resource) }
        Write-Host $line
    }
    end { if ($header) { Write-Host '' } }
}

function Invoke-DoksNative {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('doctl', 'kubectl', 'helm')][string]$Tool,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments,
        [switch]$Json,
        [switch]$Stream
    )
    $exe = Get-DoksTool -Name $Tool
    $ErrorActionPreference = 'Continue'
    $display = "$Tool $($Arguments -join ' ')"
    if ($Json) { $Arguments = @($Arguments) + @('--output', 'json') }

    if ($Stream) {
        & $exe @Arguments | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "$display failed with exit code $LASTEXITCODE." }
        return
    }

    $raw  = @(& $exe @Arguments 2>&1)
    $code = $LASTEXITCODE
    $stdout = New-Object System.Collections.Generic.List[string]
    $stderr = New-Object System.Collections.Generic.List[string]
    foreach ($item in $raw) {
        if ($item -is [System.Management.Automation.ErrorRecord]) { $stderr.Add([string]$item) } else { $stdout.Add([string]$item) }
    }
    if ($code -ne 0) {
        $detail = @(@($stderr) + @($stdout) | Where-Object { $_ -and $_.Trim() }) -join [Environment]::NewLine
        throw "$display failed (exit code $code): $(Get-DoksErrorText -Text $detail)"
    }
    foreach ($line in $stderr) { Write-Verbose "[$Tool] $line" }

    if ($Json) {
        $text = ($stdout -join "`n").Trim()
        if (-not $text) { return $null }
        return (ConvertFrom-Json -InputObject $text)
    }
    return $stdout.ToArray()
}

function Invoke-Doctl {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Json, [switch]$Stream)
    if ($script:ApiToken) {
        Invoke-DoksWithToken -Token $script:ApiToken -ScriptBlock { Invoke-DoksNative -Tool doctl -Arguments $Arguments -Json:$Json -Stream:$Stream }
    }
    else {
        Invoke-DoksNative -Tool doctl -Arguments $Arguments -Json:$Json -Stream:$Stream
    }
}

function Invoke-KubectlManifest {
    # Applies a manifest passed via stdin so secret material never appears on a
    # command line, in process listings or in error text.
    param([Parameter(Mandatory)][string]$Manifest, [string[]]$Arguments = @('apply', '-f', '-'))
    $exe = Get-DoksTool -Name kubectl
    $ErrorActionPreference = 'Continue'
    $raw  = @($Manifest | & $exe @Arguments 2>&1)
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        $text = @($raw | ForEach-Object { [string]$_ } | Where-Object { $_ -and $_.Trim() }) -join [Environment]::NewLine
        throw "kubectl $($Arguments -join ' ') failed (exit code $code): $(Get-DoksErrorText -Text $text)"
    }
    foreach ($line in $raw) { Write-Verbose "[kubectl] $line" }
}

function Invoke-Kubectl {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Json, [switch]$Stream)
    Invoke-DoksNative -Tool kubectl -Arguments $Arguments -Json:$Json -Stream:$Stream
}

function Invoke-Helm {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Json, [switch]$Stream)
    Invoke-DoksNative -Tool helm -Arguments $Arguments -Json:$Json -Stream:$Stream
}

# ---------------------------------------------------------------------------
# Authentication
# ---------------------------------------------------------------------------

function Get-DoksAccountInfo {
    @(Invoke-Doctl -Arguments @('account', 'get') -Json)[0]
}

function Invoke-DoksWithToken {
    param([Parameter(Mandatory)][string]$Token, [Parameter(Mandatory)][scriptblock]$ScriptBlock)
    $previous = $env:DIGITALOCEAN_ACCESS_TOKEN
    $env:DIGITALOCEAN_ACCESS_TOKEN = $Token
    try { & $ScriptBlock }
    finally {
        if ($null -eq $previous) { Remove-Item -Path Env:DIGITALOCEAN_ACCESS_TOKEN -ErrorAction SilentlyContinue }
        else { $env:DIGITALOCEAN_ACCESS_TOKEN = $previous }
    }
}

function Assert-DoksAuth {
    if ($script:AuthVerified) { return }
    Connect-DoksAccount -Quiet | Out-Null
}

function Set-DoksToken {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Position = 0)][securestring]$Token,
        [switch]$SkipValidation
    )
    if (-not $Token) {
        Write-Host 'Create a token at https://cloud.digitalocean.com/account/api/tokens (Kubernetes read + write).' -ForegroundColor DarkGray
        $Token = Read-Host -Prompt 'DigitalOcean API token (input is hidden)' -AsSecureString
    }
    $plain = ConvertFrom-DoksSecureString -SecureString $Token
    if (-not $plain) { throw 'No token entered.' }

    $user = 'digitalocean'
    if (-not $SkipValidation) {
        $saved = $script:ApiToken
        $script:ApiToken = $plain
        try { $account = Get-DoksAccountInfo } finally { $script:ApiToken = $saved }
        if ($account.email) { $user = $account.email }
    }

    $store = Get-DoksTokenStoreName
    if (-not $PSCmdlet.ShouldProcess($store, 'Store DigitalOcean API token')) { return }
    Write-DoksStoredToken -User $user -Token $plain
    Write-Host "Token stored in $store (user: $user)." -ForegroundColor Green

    Connect-DoksAccount -Force -Quiet | Out-Null
    Write-Host 'This session is connected; new sessions pick the token up automatically.'
}

function Remove-DoksToken {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param()
    $store = Get-DoksTokenStoreName
    if (-not $PSCmdlet.ShouldProcess($store, 'Delete stored DigitalOcean API token')) { return }
    if (Remove-DoksStoredToken) { Write-Host "Deleted the token from $store." }
    else { Write-Host "No token was stored in $store." }
    Disconnect-DoksAccount
}

function Connect-DoksAccount {
    [CmdletBinding()]
    param(
        [securestring]$Token,
        [switch]$Force,
        [switch]$Quiet
    )
    $setByUs = $false
    $script:ApiToken = $null
    if ($Token) {
        $script:ApiToken = ConvertFrom-DoksSecureString -SecureString $Token
        $source = 'the -Token parameter (this session only)'
        $setByUs = $true
    }
    elseif ($env:DIGITALOCEAN_ACCESS_TOKEN -and -not $Force) {
        $source = '$env:DIGITALOCEAN_ACCESS_TOKEN'
    }
    else {
        $stored = Read-DoksStoredToken
        if ($stored) {
            $script:ApiToken = $stored.Token
            $source = Get-DoksTokenStoreName
            $setByUs = $true
        }
        elseif ($env:DIGITALOCEAN_ACCESS_TOKEN) {
            $source = '$env:DIGITALOCEAN_ACCESS_TOKEN'
        }
        else {
            $source = "doctl's own configuration"
        }
    }

    try {
        $account = Get-DoksAccountInfo
    }
    catch {
        $script:AuthVerified = $false
        if ($setByUs) { $script:ApiToken = $null }
        if ($source -eq "doctl's own configuration") {
            throw "No DigitalOcean API token available. Run Set-DoksToken once to store yours ($(Get-DoksTokenStoreName)), or set `$env:DIGITALOCEAN_ACCESS_TOKEN for this session. doctl said: $($_.Exception.Message)"
        }
        throw "The DigitalOcean API rejected the token from $source. $($_.Exception.Message)"
    }

    $script:AuthVerified = $true
    if (-not $Quiet) {
        $team = ''
        if ($account.team -and $account.team.name) { $team = " (team: $($account.team.name))" }
        Write-Host "Connected to DigitalOcean as $($account.email)$team via $source."
    }
    $account
}

function Disconnect-DoksAccount {
    [CmdletBinding()]
    param()
    $script:ApiToken = $null
    if ($env:DIGITALOCEAN_ACCESS_TOKEN) {
        Remove-Item -Path Env:DIGITALOCEAN_ACCESS_TOKEN
        Write-Host 'Removed $env:DIGITALOCEAN_ACCESS_TOKEN from this session.'
    }
    $script:AuthVerified = $false
}

function Get-DoksAccount {
    [CmdletBinding()]
    param()
    Assert-DoksAuth
    Get-DoksAccountInfo
}

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

function Get-DoksDefault {
    [CmdletBinding()]
    param()
    [pscustomobject]$script:Defaults
}

function Set-DoksDefault {
    [CmdletBinding()]
    param(
        [string]$Region,
        [string]$Size,
        [ValidateRange(1, 512)][int]$Count,
        [ValidateRange(1, 512)][int]$MinNodes,
        [ValidateRange(0, 512)][int]$MaxNodes,
        [string]$Version,
        [string[]]$Tag,
        [string]$KubeconfigDir,
        [string]$CredentialTarget
    )
    foreach ($key in $PSBoundParameters.Keys) {
        if ($script:Defaults.Contains($key)) {
            Set-DoksDefaultValue -Key $key -Value $PSBoundParameters[$key] -Source 'Set-DoksDefault'
        }
    }
    Get-DoksDefault
}

function Get-DoksKubeconfigDir {
    $dir = $script:Defaults.KubeconfigDir
    if (-not $dir) { $dir = (Get-Location).ProviderPath }
    $dir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($dir)
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $dir
}

function Get-DoksKubeconfigPath {
    param([Parameter(Mandatory)][string]$Name)
    Join-Path -Path (Get-DoksKubeconfigDir) -ChildPath "$Name-kubeconfig.yaml"
}

# ---------------------------------------------------------------------------
# Cluster objects
# ---------------------------------------------------------------------------

function Format-DoksAge {
    param([timespan]$Span)
    if ($Span.TotalSeconds -lt 0) { $Span = [timespan]::Zero }
    if ($Span.TotalDays -ge 1)  { return ('{0}d {1}h' -f [int][math]::Floor($Span.TotalDays), $Span.Hours) }
    if ($Span.TotalHours -ge 1) { return ('{0}h {1}m' -f $Span.Hours, $Span.Minutes) }
    return ('{0}m' -f [int][math]::Floor($Span.TotalMinutes))
}

function ConvertTo-DoksClusterObject {
    param([Parameter(Mandatory)]$Raw)
    $pools = @()
    if ($Raw.node_pools) { $pools = @($Raw.node_pools) }
    $pool = $null
    if ($pools.Count -gt 0) { $pool = $pools[0] }
    $nodeCount = 0
    foreach ($p in $pools) { $nodeCount += [int]$p.count }

    $autoscale = ''
    if ($pool -and $pool.auto_scale) { $autoscale = "$($pool.min_nodes)-$($pool.max_nodes)" }
    $nodes = "$nodeCount x $(if ($pool) { $pool.size } else { '?' })"
    if ($autoscale) { $nodes += " (auto $autoscale)" }

    $created = $null
    $age = ''
    if ($Raw.created_at) {
        try {
            $created = [datetime]::Parse($Raw.created_at, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $age = Format-DoksAge -Span ([datetime]::UtcNow - $created.ToUniversalTime())
        } catch { }
    }

    $state = ''
    if ($Raw.status -and $Raw.status.state) { $state = $Raw.status.state }

    [pscustomobject]@{
        PSTypeName = 'Doks.Cluster'
        Name       = $Raw.name
        State      = $state
        Nodes      = $nodes
        Age        = $age
        Region     = $Raw.region
        Version    = $Raw.version
        NodePool   = $(if ($pool) { $pool.name } else { $null })
        Size       = $(if ($pool) { $pool.size } else { $null })
        NodeCount  = $nodeCount
        Autoscale  = $autoscale
        Endpoint   = $Raw.endpoint
        Id         = $Raw.id
        Tags       = @($Raw.tags)
        Created    = $created
        Kubeconfig = Get-DoksKubeconfigPath -Name $Raw.name
    }
}

function Find-DoksCluster {
    param([Parameter(Mandatory)][string]$Name)
    $all = @(Invoke-Doctl -Arguments @('kubernetes', 'cluster', 'list') -Json)
    foreach ($c in $all) {
        if ($c.name -eq $Name) { return (ConvertTo-DoksClusterObject -Raw $c) }
    }
    $null
}

# ---------------------------------------------------------------------------
# Public cluster commands
# ---------------------------------------------------------------------------

function Get-DoksCluster {
    [CmdletBinding()]
    [OutputType('Doks.Cluster')]
    param(
        [Parameter(Position = 0)][SupportsWildcards()][string]$Name = '*'
    )
    Assert-DoksAuth
    $all = @(Invoke-Doctl -Arguments @('kubernetes', 'cluster', 'list') -Json)
    $matched = @($all | Where-Object { $_.name -like $Name })
    if ($matched.Count -eq 0 -and $Name -eq '*') {
        Write-Host 'No Kubernetes clusters in this account.' -ForegroundColor DarkGray
    }
    foreach ($c in $matched) { ConvertTo-DoksClusterObject -Raw $c }
}

function Get-DoksOption {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)][ValidateSet('Regions', 'Sizes', 'Versions')][string]$Type
    )
    Assert-DoksAuth
    @(Invoke-Doctl -Arguments @('kubernetes', 'options', $Type.ToLowerInvariant()) -Json)
}

function Use-DoksCluster {
    [CmdletBinding(DefaultParameterSetName = 'ByName')]
    param(
        [Parameter(ParameterSetName = 'ByName', Position = 0)][string]$Name,
        [Parameter(ParameterSetName = 'ByPath', Mandatory)][string]$Path,
        [Parameter(ParameterSetName = 'ByName')][ValidateRange(0, 2147483647)][int]$ExpirySeconds = 0,
        [switch]$Quiet
    )

    if ($PSCmdlet.ParameterSetName -eq 'ByPath') {
        $file = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Kubeconfig file not found: $file" }
    }
    else {
        Assert-DoksAuth
        if (-not $Name) {
            $all = @(Get-DoksCluster)
            if ($all.Count -eq 1) { $Name = $all[0].Name }
            elseif ($all.Count -eq 0) { throw 'There is no cluster in this account. New-DoksCluster creates one.' }
            else { throw "Several clusters exist ($(($all | ForEach-Object { $_.Name }) -join ', ')). Pass the name: Use-DoksCluster <name>" }
        }
        $cluster = Find-DoksCluster -Name $Name
        if (-not $cluster) {
            $names = @(Get-DoksCluster | ForEach-Object { $_.Name })
            $hint = if ($names.Count) { "Existing: $($names -join ', ')." } else { 'The account has no clusters.' }
            throw "No cluster named '$Name'. $hint"
        }

        $doctlArgs = @('kubernetes', 'cluster', 'kubeconfig', 'show', $Name)
        if ($ExpirySeconds -gt 0) { $doctlArgs += @('--expiry-seconds', "$ExpirySeconds") }
        $lines = @(Invoke-Doctl -Arguments $doctlArgs)

        $start = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^apiVersion:') { $start = $i; break }
        }
        if ($start -lt 0) { throw "doctl did not return a kubeconfig for '$Name'." }
        $yaml = ($lines[$start..($lines.Count - 1)] -join "`n") + "`n"

        $file = Get-DoksKubeconfigPath -Name $Name
        [System.IO.File]::WriteAllText($file, $yaml, [System.Text.UTF8Encoding]::new($false))
    }

    $env:KUBECONFIG = $file
    $context = ''
    try { $context = @(Invoke-Kubectl -Arguments @('config', 'current-context')) -join '' }
    catch { Write-Warning "kubectl could not read the kubeconfig: $($_.Exception.Message)" }

    if (-not $Quiet) {
        Write-Host "KUBECONFIG = $file  (this window only)" -ForegroundColor Green
        if ($context) { Write-Host "kubectl context: $context" }
    }
}

function Disconnect-DoksCluster {
    [CmdletBinding()]
    param()
    if ($env:KUBECONFIG) {
        Write-Host "Dropped KUBECONFIG ($env:KUBECONFIG) for this window."
        Remove-Item -Path Env:KUBECONFIG
    }
    else {
        Write-Host 'KUBECONFIG was not set in this window.'
    }
}

function Remove-DoksKubeconfigFromEnv {
    param([Parameter(Mandatory)][string]$Path)
    if (-not $env:KUBECONFIG) { return }
    $full = [System.IO.Path]::GetFullPath($Path)
    $keep = @()
    foreach ($entry in ($env:KUBECONFIG -split [regex]::Escape([string][System.IO.Path]::PathSeparator))) {
        if (-not $entry) { continue }
        $entryFull = try { [System.IO.Path]::GetFullPath($entry) } catch { $entry }
        if ($entryFull -ne $full) { $keep += $entry }
    }
    if ($keep.Count -eq 0) {
        Remove-Item -Path Env:KUBECONFIG
        Write-Host 'Dropped KUBECONFIG for this window.'
    }
    elseif ($keep.Count -ne @($env:KUBECONFIG -split [regex]::Escape([string][System.IO.Path]::PathSeparator) | Where-Object { $_ }).Count) {
        $env:KUBECONFIG = $keep -join [System.IO.Path]::PathSeparator
    }
}

function Wait-DoksNodeReady {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 512)][int]$Count = 1,
        [ValidateRange(10, 7200)][int]$TimeoutSeconds = 900,
        [ValidateRange(2, 300)][int]$PollSeconds = 10
    )
    if (-not $env:KUBECONFIG) { throw 'Not connected to a cluster in this window (Use-DoksCluster first).' }
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host "Waiting for $Count node(s) to become Ready (timeout ${TimeoutSeconds}s)" -ForegroundColor Cyan

    $apiReached = $false
    $lastError  = $null
    $lastStatus = ''
    $nodes = @()
    $ready = @()
    do {
        $nodes = @()
        try {
            $json = Invoke-Kubectl -Arguments @('get', 'nodes') -Json
            if ($json -and $json.items) { $nodes = @($json.items) }
            $apiReached = $true
            $lastError  = $null
        }
        catch { $lastError = $_.Exception.Message }

        $ready = @($nodes | Where-Object {
            $_.status -and $_.status.conditions -and
            @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0
        })
        if ($apiReached -and $nodes.Count -ge $Count -and $ready.Count -eq $nodes.Count) {
            if ($lastStatus) { Write-Host '' }
            Write-Host ("All nodes Ready ({0}/{1}) after {2}m {3}s." -f $ready.Count, $nodes.Count, [int][math]::Floor($watch.Elapsed.TotalMinutes), $watch.Elapsed.Seconds) -ForegroundColor Green
            return
        }

        $status = if (-not $apiReached) { 'waiting for the API server to answer' }
                  else { "$($ready.Count)/$([math]::Max($nodes.Count, $Count)) node(s) Ready" }
        if ($status -ne $lastStatus) {
            if ($lastStatus) { Write-Host '' }
            Write-Host "  $status " -NoNewline
            $lastStatus = $status
        }
        Write-Host '.' -NoNewline
        Start-Sleep -Seconds $PollSeconds
    } while ([datetime]::UtcNow -lt $deadline)
    Write-Host ''

    $state = if (-not $apiReached) { "the API server never answered (last error: $lastError)" }
             elseif ($nodes.Count -lt $Count) { "only $($nodes.Count) of $Count expected node(s) have registered ($($ready.Count) Ready)" }
             else { "only $($ready.Count) of $($nodes.Count) node(s) are Ready" }
    throw "Not ready after $TimeoutSeconds seconds: $state. The cluster may still be finishing - 'kubectl get nodes' shows progress, 'Wait-DoksNodeReady -Count $Count' resumes waiting."
}

function New-DoksCluster {
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Doks.Cluster')]
    param(
        [Parameter(Position = 0)]
        [ValidatePattern('^[a-z0-9][a-z0-9.-]{0,62}$')]
        [string]$Name,
        [string]$Region,
        [string]$Size,
        [ValidateRange(1, 512)][int]$Count,
        [ValidateRange(1, 512)][int]$MinNodes,
        [ValidateRange(0, 512)][int]$MaxNodes,
        [switch]$FixedSize,
        [string]$Version,
        [string]$NodePoolName,
        [string[]]$Tag,
        [switch]$HighAvailability,
        [switch]$NoConnect,
        [ValidateRange(10, 7200)][int]$NodeReadyTimeoutSeconds = 900
    )

    Assert-DoksAuth

    if (-not $PSBoundParameters.ContainsKey('Region'))   { $Region   = $script:Defaults.Region }
    if (-not $PSBoundParameters.ContainsKey('Size'))     { $Size     = $script:Defaults.Size }
    if (-not $PSBoundParameters.ContainsKey('Version'))  { $Version  = $script:Defaults.Version }
    if (-not $PSBoundParameters.ContainsKey('MinNodes')) { $MinNodes = [int]$script:Defaults.MinNodes }
    if (-not $PSBoundParameters.ContainsKey('MaxNodes')) { $MaxNodes = [int]$script:Defaults.MaxNodes }
    if (-not $PSBoundParameters.ContainsKey('Tag'))      { $Tag      = @($script:Defaults.Tag) }
    if (-not $Name)         { $Name = "k8s-test-$Region" }
    if (-not $NodePoolName) { $NodePoolName = "pool-$Name" }
    if (-not $Version)      { $Version = 'latest' }

    $autoscale = (-not $FixedSize) -and ($MaxNodes -gt 0)
    if ($autoscale) {
        if ($MaxNodes -lt $MinNodes) { throw "-MaxNodes ($MaxNodes) must not be smaller than -MinNodes ($MinNodes)." }
        if (-not $PSBoundParameters.ContainsKey('Count')) {
            $Count = [int]$script:Defaults.Count
            if ($Count -lt $MinNodes) { $Count = $MinNodes }
            if ($Count -gt $MaxNodes) { $Count = $MaxNodes }
        }
        if ($Count -lt $MinNodes -or $Count -gt $MaxNodes) { throw "-Count ($Count) must lie between -MinNodes ($MinNodes) and -MaxNodes ($MaxNodes)." }
        $poolSpec = "name=$NodePoolName;size=$Size;count=$Count;auto-scale=true;min-nodes=$MinNodes;max-nodes=$MaxNodes"
        $poolText = "$Count x $Size, autoscale $MinNodes-$MaxNodes"
    }
    else {
        if (-not $PSBoundParameters.ContainsKey('Count')) { $Count = [int]$script:Defaults.Count }
        $poolSpec = "name=$NodePoolName;size=$Size;count=$Count"
        $poolText = "$Count x $Size, fixed"
    }

    $existing = Find-DoksCluster -Name $Name
    if ($existing) {
        throw "A cluster named '$Name' already exists (state: $($existing.State), age $($existing.Age)). Use-DoksCluster $Name connects to it, Remove-DoksCluster $Name deletes it."
    }

    $doctlArgs = @(
        'kubernetes', 'cluster', 'create', $Name,
        '--region', $Region,
        '--version', $Version,
        '--node-pool', $poolSpec,
        '--update-kubeconfig=false',
        '--wait'
    )
    $tags = @($Tag | Where-Object { $_ })
    if ($tags.Count -gt 0) { $doctlArgs += @('--tag', ($tags -join ',')) }
    if ($HighAvailability) { $doctlArgs += '--ha' }

    $summary = "$Name in $Region ($poolText, Kubernetes $Version$(if ($HighAvailability) { ', HA control plane' }))"
    if (-not $PSCmdlet.ShouldProcess($summary, 'Create DigitalOcean Kubernetes cluster')) { return }

    Write-Host "Creating cluster $summary ..." -ForegroundColor Cyan
    Write-Host 'This usually takes 4-8 minutes. Ctrl+C stops waiting, not the creation.' -ForegroundColor DarkGray
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-Doctl -Arguments $doctlArgs -Stream
    Write-Host ("Cluster '{0}' is running after {1}m {2}s." -f $Name, [int][math]::Floor($watch.Elapsed.TotalMinutes), $watch.Elapsed.Seconds) -ForegroundColor Green

    if (-not $NoConnect) {
        $connected = $false
        try {
            Use-DoksCluster -Name $Name
            $connected = $true
        }
        catch {
            Write-Warning "Cluster '$Name' exists, but connecting this window to it failed: $($_.Exception.Message)"
            Write-Warning "Retry with: Use-DoksCluster $Name"
        }
        if ($connected) {
            try { Wait-DoksNodeReady -Count $Count -TimeoutSeconds $NodeReadyTimeoutSeconds }
            catch {
                # Terminating on purpose: piped commands (e.g. Bootstrap-DoksCluster)
                # cannot do anything useful against a cluster whose nodes never came up.
                $message = "Cluster '$Name' is created and this window is connected, but: $($_.Exception.Message)"
                $PSCmdlet.ThrowTerminatingError([System.Management.Automation.ErrorRecord]::new(
                    [System.InvalidOperationException]::new($message, $_.Exception),
                    'DoksNodesNotReady',
                    [System.Management.Automation.ErrorCategory]::OperationTimeout,
                    $Name))
            }
        }
    }
    Find-DoksCluster -Name $Name
}

function Remove-DoksCluster {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipelineByPropertyName)]
        [string]$Name,
        [switch]$KeepResources,
        [switch]$Force
    )
    process {
        Assert-DoksAuth
        if ($Force -and -not $PSBoundParameters.ContainsKey('Confirm')) { $ConfirmPreference = 'None' }

        $cluster = Find-DoksCluster -Name $Name
        if (-not $cluster) {
            Write-Warning "No cluster named '$Name' exists."
            return
        }
        $ownTags = @(([string]$script:Defaults.Tag) -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        $marked = @($ownTags | Where-Object { $cluster.Tags -contains $_ })
        if ($ownTags.Count -gt 0 -and $marked.Count -eq 0 -and -not $Force) {
            throw "Cluster '$Name' does not carry the tag '$($ownTags -join ',')' that marks clusters this module created (tags: $(if ($cluster.Tags) { $cluster.Tags -join ', ' } else { 'none' })). Refusing to delete it; pass -Force to override."
        }
        $action = if ($KeepResources) { 'Delete cluster (keep its load balancers/volumes)' } else { 'Delete cluster AND its load balancers/volumes' }
        if (-not $PSCmdlet.ShouldProcess("$Name ($($cluster.Nodes), age $($cluster.Age))", $action)) { return }

        $doctlArgs = @('kubernetes', 'cluster', 'delete', $Name, '--force', '--update-kubeconfig=false')
        if (-not $KeepResources) { $doctlArgs += '--dangerous' }
        Invoke-Doctl -Arguments $doctlArgs | Out-Null
        Write-Host "Cluster '$Name' deleted$(if (-not $KeepResources) { ' (including its load balancers and volumes)' })." -ForegroundColor Green

        $file = Get-DoksKubeconfigPath -Name $Name
        Remove-DoksKubeconfigFromEnv -Path $file
        if (Test-Path -LiteralPath $file -PathType Leaf) {
            Remove-Item -LiteralPath $file -Force
            Write-Host "Removed $file"
        }
    }
}

# ---------------------------------------------------------------------------
# GitOps bootstrap (shadows bootstrap/README.md)
# ---------------------------------------------------------------------------

function New-DoksRandomSecret {
    param([ValidateRange(1, 512)][int]$Bytes = 24)
    $buffer = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buffer) } finally { $rng.Dispose() }
    [Convert]::ToBase64String($buffer)
}

function Test-DoksKubectlResource {
    param(
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][string]$Name,
        [string]$Namespace
    )
    $kubectlArgs = @('get', $Kind, $Name)
    if ($Namespace) { $kubectlArgs += @('--namespace', $Namespace) }
    try { Invoke-Kubectl -Arguments $kubectlArgs | Out-Null; $true }
    catch { $false }
}

function Get-DoksDatabaseOutputs {
    # The managed database (terraform/database.tf) is known only through the
    # Terraform outputs: endpoint + database names, and the login roles + admin.
    param([Parameter(Mandatory)][string]$TerraformDir)
    $TerraformDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TerraformDir)
    if (-not (Test-Path -LiteralPath (Join-Path -Path $TerraformDir -ChildPath 'database.tf') -PathType Leaf)) {
        throw "No database.tf in $TerraformDir. Pass -TerraformDir pointing at the ops repository's terraform folder."
    }
    $exe = Get-DoksTool -Name terraform
    $read = {
        param([string]$Name)
        $ErrorActionPreference = 'Continue'
        $raw  = @(& $exe "-chdir=$TerraformDir" output -json $Name 2>&1)
        $code = $LASTEXITCODE
        $text = @($raw | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
        if ($code -ne 0 -or -not $text.Trim()) {
            throw "terraform output $Name failed in $TerraformDir (exit code $code): $($text.Trim()) - run Sync-DoksTerraform (or 'terraform apply' there) first; the managed database and its credentials are Terraform outputs."
        }
        ConvertFrom-Json -InputObject $text
    }
    $info  = & $read 'database'
    $creds = & $read 'database_credentials'
    if (-not $info.host -or -not $info.port -or -not $creds.admin.user) {
        throw "Terraform outputs 'database' / 'database_credentials' are incomplete - has 'terraform apply' created the database cluster?"
    }
    # the module service's managed MySQL (Aufgabe 6): endpoint, databases, the cluster CA
    $modInfo  = & $read 'modules_database'
    $modCreds = & $read 'modules_database_credentials'
    if (-not $modInfo.host -or -not $modInfo.port -or -not $modInfo.ca -or -not $modCreds.admin.user) {
        throw "Terraform outputs 'modules_database' / 'modules_database_credentials' are incomplete - has 'terraform apply' created the MySQL cluster?"
    }
    [pscustomobject]@{
        Info = $info; Credentials = $creds
        Modules = [pscustomobject]@{ Info = $modInfo; Credentials = $modCreds }
    }
}

function Sync-DoksTerraform {
    <#
    .SYNOPSIS
        Makes terraform/ describe a cluster and applies it: adopts the cluster,
        creates (or keeps) the managed databases (PostgreSQL, MySQL).

    .DESCRIPTION
        The step between New-DoksCluster and Bootstrap-DoksCluster, as a command:
          1. writes the cluster's id, name and Kubernetes version into
             terraform/terraform.tfvars (commit that change with the next PR),
          2. removes a previous cluster from the Terraform state, so the import
             block adopts this one instead of replacing the old one,
          3. 'terraform init' (first time) and 'terraform apply -auto-approve',
             streamed to the console, with the module's DigitalOcean token
             exported as DIGITALOCEAN_TOKEN for those processes only.
        Idempotent: an up-to-date configuration applies as a no-op. The cluster
        object is passed through, so the command sits in a pipeline:
        New-DoksCluster | Sync-DoksTerraform | Bootstrap-DoksCluster

    .PARAMETER Name
        Cluster to describe (from the pipeline: New-DoksCluster / Get-DoksCluster
        output). Omit to use the cluster this window is connected to.

    .PARAMETER TerraformDir
        Folder of the Terraform configuration. Default: <repo>/terraform.

    .EXAMPLE
        New-DoksCluster | Sync-DoksTerraform | Bootstrap-DoksCluster; Connect-DoksPortForward
        The whole startup of a fresh cluster in one line.

    .EXAMPLE
        Sync-DoksTerraform k8s-test-fra1 -WhatIf
        Shows what would change (tfvars, state, apply) without doing it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType('Doks.Cluster')]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName)]
        [string]$Name,
        [string]$TerraformDir
    )
    process {
        Assert-DoksAuth
        if (-not $TerraformDir) { $TerraformDir = Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'terraform' }
        $TerraformDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($TerraformDir)
        if (-not $Name) {
            if (-not $env:KUBECONFIG) { throw 'No cluster given and this window is not connected - pass a name or run Use-DoksCluster first.' }
            $context = @(Invoke-Kubectl -Arguments @('config', 'current-context')) -join ''
            if ($context -match '^do-[a-z0-9]+-(.+)$') { $Name = $Matches[1] } else { throw "Cannot derive the cluster name from kubectl context '$context'; pass -Name." }
        }
        $cluster = Find-DoksCluster -Name $Name
        if (-not $cluster) { throw "No cluster named '$Name' in this DigitalOcean account." }
        $exe = Get-DoksTool -Name terraform
        $tfvars = Join-Path -Path $TerraformDir -ChildPath 'terraform.tfvars'
        if (-not (Test-Path -LiteralPath $tfvars -PathType Leaf)) { throw "No terraform.tfvars in $TerraformDir." }
        Write-Host "Terraform for cluster $($cluster.Name) ($($cluster.Id), $($cluster.Version)) in $TerraformDir" -ForegroundColor Cyan

        # 1. terraform.tfvars = this cluster
        $content = [System.IO.File]::ReadAllText($tfvars)
        $updated = $content
        foreach ($pair in @(@('cluster_id', $cluster.Id), @('cluster_name', $cluster.Name), @('kubernetes_version', $cluster.Version))) {
            $key, $value = $pair
            $pattern = "(?m)^(\s*$key\s*=\s*)""[^""]*"""
            if ($updated -notmatch $pattern) { throw "terraform.tfvars has no '$key' line to update." }
            $updated = [regex]::Replace($updated, $pattern, ('${1}"' + $value + '"'))
        }
        if ($updated -ne $content) {
            if ($PSCmdlet.ShouldProcess($tfvars, "Name cluster $($cluster.Name)")) {
                [System.IO.File]::WriteAllText($tfvars, $updated)
                Write-Host "  terraform.tfvars updated - commit it with the next PR." -ForegroundColor Green
            }
        }
        else {
            Write-Host '  terraform.tfvars already names this cluster.'
        }

        # 2./3. state + apply, token scoped to these processes
        $token = $script:ApiToken
        if (-not $token) { $stored = Read-DoksStoredToken; if ($stored) { $token = $stored.Token } }
        if (-not $token -and -not $env:DIGITALOCEAN_TOKEN) { throw 'No DigitalOcean API token for Terraform: Set-DoksToken first, or export DIGITALOCEAN_TOKEN.' }
        $previous = $env:DIGITALOCEAN_TOKEN
        if ($token) { $env:DIGITALOCEAN_TOKEN = $token }
        try {
            $ErrorActionPreference = 'Continue'
            if (-not (Test-Path -LiteralPath (Join-Path -Path $TerraformDir -ChildPath '.terraform') -PathType Container)) {
                Write-Host '> terraform init' -ForegroundColor DarkGray
                & $exe "-chdir=$TerraformDir" init -input=false | Out-Host
                if ($LASTEXITCODE -ne 0) { throw "terraform init failed (exit code $LASTEXITCODE)." }
            }
            $shown = @(& $exe "-chdir=$TerraformDir" state show -no-color digitalocean_kubernetes_cluster.this 2>&1 | ForEach-Object { [string]$_ })
            if ($LASTEXITCODE -eq 0 -and (($shown -join "`n") -notmatch [regex]::Escape($cluster.Id))) {
                if ($PSCmdlet.ShouldProcess('digitalocean_kubernetes_cluster.this', 'Remove the previous cluster from the Terraform state')) {
                    Write-Host '> terraform state rm digitalocean_kubernetes_cluster.this  (a previous cluster; the import block adopts this one)' -ForegroundColor DarkGray
                    & $exe "-chdir=$TerraformDir" state rm digitalocean_kubernetes_cluster.this | Out-Host
                    if ($LASTEXITCODE -ne 0) { throw "terraform state rm failed (exit code $LASTEXITCODE)." }
                }
            }
            if ($PSCmdlet.ShouldProcess($TerraformDir, 'terraform apply -auto-approve (adopt the cluster, create or keep the managed databases)')) {
                Write-Host '> terraform apply -auto-approve  (new managed databases take about 5 minutes)' -ForegroundColor DarkGray
                & $exe "-chdir=$TerraformDir" apply -input=false -auto-approve 2>&1 | Write-DoksTerraformProgress
                if ($LASTEXITCODE -ne 0) { throw "terraform apply failed (exit code $LASTEXITCODE)." }
                Write-Host "Terraform applied: cluster adopted, managed databases ready." -ForegroundColor Green
            }
        }
        finally {
            if ($null -eq $previous) { Remove-Item -Path Env:DIGITALOCEAN_TOKEN -ErrorAction SilentlyContinue } else { $env:DIGITALOCEAN_TOKEN = $previous }
        }
        $cluster
    }
}

function Initialize-DoksCluster {
    <#
    .SYNOPSIS
        Bootstraps a DOKS cluster for GitOps: namespaces, secrets, ArgoCD, root application.

    .DESCRIPTION
        Automates the one-time imperative bootstrap documented in bootstrap/README.md.
        After it finishes, the cluster converges on git - ArgoCD pulls; nothing
        deploys via kubectl/helm from then on.

        Steps (in order):
          1. Connect   - point this window at the cluster (-ClusterName), verify access;
                         read the managed databases from the Terraform outputs
                         (Sync-DoksTerraform must have applied for this cluster).
          2. Secrets   - per environment namespace: create the namespace, an
                         'auth-stack-secrets' Secret (endpoints and credentials of the
                         managed PostgreSQL and MySQL from the Terraform outputs, the
                         MySQL cluster CA, + a random jwt-secret),
                         and optionally a GHCR image pull Secret (-GhcrUsername/-GhcrToken).
                         Then the monitoring namespace with Grafana's admin Secret
                         (random password) and the Alertmanager notification channel
                         (-AlertWebhookUrl, or a webhook.site inbox created on the spot
                         and opened in the browser when none is given).
          3. ArgoCD    - 'helm upgrade --install' (pinned chart version) from bootstrap/argocd-values.yaml
                         into the 'argocd' namespace.
          4. Root app  - 'kubectl apply' argocd/root.yaml; ArgoCD
                         takes over from here (app-of-apps).
          5. Hosts     - wait for the Traefik load balancer IP and write it into
                         the nip.io hosts of both environments and the load test
                         (Sync-DoksHostname; -NoHostUpdate skips it).
          6. Handover  - print what to commit, how to watch convergence, the
                         port-forward command, the environment URLs and where the
                         alerts are delivered.

        The command is idempotent and safe to re-run: existing Secrets are NEVER
        touched, ArgoCD upgrades in place, and the root application is applied
        declaratively. The whole startup of a fresh cluster is one line:
        New-DoksCluster | Sync-DoksTerraform | Bootstrap-DoksCluster; Connect-DoksPortForward

    .PARAMETER ClusterName
        Cluster to bootstrap. Connects this window to it first (Use-DoksCluster).
        Omit to use whatever cluster this window already points at ($env:KUBECONFIG).

    .PARAMETER Namespace
        Environment namespaces to create and equip with secrets.
        Default: auth-staging, auth-prod (the namespaces argocd/app-*.yaml deploys to).

    .PARAMETER SecretName
        Name of the per-namespace application Secret the chart references via
        'existingSecret'. Default: auth-stack-secrets.

    .PARAMETER NoHostUpdate
        Skip step 5 (the nip.io hosts keep the previous cluster's IP until
        Sync-DoksHostname runs).

    .PARAMETER HostTimeoutSeconds
        How long step 5 waits for the load balancer IP. Default: 900.

    .PARAMETER TerraformDir
        Folder of the Terraform configuration whose outputs 'database',
        'database_credentials', 'modules_database' and 'modules_database_credentials'
        provide the managed databases' endpoints and credentials
        (terraform/database.tf). Default: <RepoRoot>/terraform.

    .PARAMETER GhcrUsername
        GitHub username for the GHCR image pull Secret. Omit if the GHCR packages
        are public. To use it, set generic-stack.global.imagePullSecrets to
        [{ name: ghcr-pull }] in charts/auth-stack/values.yaml (commented example there).

    .PARAMETER GhcrToken
        Fine-grained PAT with read:packages only, as a SecureString.
        Prompted for interactively when -GhcrUsername is given without it.

    .PARAMETER PullSecretName
        Name of the docker-registry pull Secret. Default: ghcr-pull
        (to be referenced via generic-stack.global.imagePullSecrets in charts/auth-stack/values.yaml).

    .PARAMETER MonitoringNamespace
        Namespace of the monitoring stack (argocd/infra-monitoring.yaml deploys
        into it). Default: monitoring.

    .PARAMETER AlertWebhookUrl
        Notification channel for Alertmanager: any endpoint that accepts its JSON
        payload (chat bridge, automation platform, https://webhook.site/<id>).
        Stored in the 'alertmanager-webhook' Secret and read through 'url_file',
        so it never reaches git. Without it a fresh webhook.site inbox is created
        through its public API (no account), stored as the channel, opened in the
        browser, and both URLs are printed in the handover so the inbox can be
        found again. The inbox is public to anyone holding the URL and expires
        after seven days without traffic: a demonstration channel, not an
        operations one.

    .PARAMETER NoAlertInbox
        Do not create a webhook.site inbox when -AlertWebhookUrl is omitted; the
        Secret then holds a non-resolving placeholder. Alertmanager starts and
        alerts fire visibly, but nothing is delivered until the Secret is replaced.

    .PARAMETER RepoRoot
        Repository root containing bootstrap/argocd-values.yaml and
        argocd/root.yaml. Default: the folder above this module.

    .PARAMETER ArgoCdChartVersion
        argo-cd Helm chart version to install. Default: the targetRevision of
        the argo-cd source in argocd/argocd.yaml (single source of truth; ArgoCD
        reconciles itself from that file afterwards).

    .EXAMPLE
        New-DoksCluster | Initialize-DoksCluster
        Create a fresh cluster and bootstrap it in one line (public GHCR packages).

    .EXAMPLE
        Bootstrap-DoksCluster k8s-test-fra1 -GhcrUsername beatos-learns
        Connect to an existing cluster and bootstrap it; prompts (hidden) for the
        read:packages PAT and creates the pull secret in every namespace.

    .EXAMPLE
        Initialize-DoksCluster -WhatIf
        Show what would happen to the cluster this window points at, change nothing.

    .NOTES
        Requires doctl, kubectl, helm and terraform on PATH (Test-DoksSetup checks all four).
        Secrets are generated locally and never written to disk or git.
        'Bootstrap-DoksCluster' is an alias for this command.

    .LINK
        bootstrap/README.md
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [Alias('Bootstrap-DoksCluster')]
    param(
        [Parameter(Position = 0, ValueFromPipelineByPropertyName)]
        [Alias('Name')]
        [string]$ClusterName,
        [string[]]$Namespace = @('auth-staging', 'auth-prod'),
        [string]$SecretName = 'auth-stack-secrets',
        [string]$GhcrUsername,
        [securestring]$GhcrToken,
        [string]$PullSecretName = 'ghcr-pull',
        [string]$MonitoringNamespace = 'monitoring',
        [string]$AlertWebhookUrl,
        [switch]$NoAlertInbox,
        [string]$RepoRoot,
        [string]$ArgoCdChartVersion,
        [string]$TerraformDir,
        [switch]$NoHostUpdate,
        [ValidateRange(0, 7200)][int]$HostTimeoutSeconds = 900
    )

    if (-not $RepoRoot) { $RepoRoot = Split-Path -Path $PSScriptRoot -Parent }
    $RepoRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepoRoot)
    $argocdValues = Join-Path -Path (Join-Path -Path $RepoRoot -ChildPath 'bootstrap') -ChildPath 'argocd-values.yaml'
    $rootApp      = Join-Path -Path (Join-Path -Path $RepoRoot -ChildPath 'argocd') -ChildPath 'root.yaml'
    $argocdApp    = Join-Path -Path (Join-Path -Path $RepoRoot -ChildPath 'argocd') -ChildPath 'argocd.yaml'
    foreach ($required in $argocdValues, $rootApp, $argocdApp) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Bootstrap file not found: $required. Pass -RepoRoot pointing at the ops repository."
        }
    }
    if (-not $ArgoCdChartVersion) {
        $match = Select-String -LiteralPath $argocdApp -Pattern '^\s+targetRevision:\s*(\S+)' | Select-Object -First 1
        if (-not $match) { throw "Cannot read the argo-cd chart version from $argocdApp; pass -ArgoCdChartVersion." }
        $ArgoCdChartVersion = $match.Matches[0].Groups[1].Value
    }
    Get-DoksTool -Name helm | Out-Null
    if (-not $TerraformDir) { $TerraformDir = Join-Path -Path $RepoRoot -ChildPath 'terraform' }
    $database = Get-DoksDatabaseOutputs -TerraformDir $TerraformDir

    if ($GhcrUsername -and -not $GhcrToken) {
        $GhcrToken = Read-Host -Prompt "GHCR PAT for $GhcrUsername, read:packages only (input is hidden)" -AsSecureString
    }
    if ($GhcrUsername -and $GhcrToken.Length -eq 0) { throw "No GHCR token entered for $GhcrUsername. Omit -GhcrUsername for public packages." }

    # --- 1. Connect -------------------------------------------------------
    if ($ClusterName) { Use-DoksCluster -Name $ClusterName -Quiet }
    elseif (-not $env:KUBECONFIG) {
        throw 'This window is not connected to a cluster. Pass -ClusterName or run Use-DoksCluster first.'
    }
    $context = @(Invoke-Kubectl -Arguments @('config', 'current-context')) -join ''
    $target = if ($ClusterName) { "cluster '$ClusterName'" } else { "kubectl context '$context'" }

    if (-not $PSCmdlet.ShouldProcess($target, "Bootstrap GitOps stack (namespaces + secrets, ArgoCD, root application)")) { return }
    Write-Host "Bootstrapping $target ..." -ForegroundColor Cyan

    # --- 2. Namespaces and secrets (out-of-band, never in git) ------------
    foreach ($ns in $Namespace) {
        if (Test-DoksKubectlResource -Kind namespace -Name $ns) {
            Write-Host "Namespace $ns exists."
        }
        else {
            Invoke-Kubectl -Arguments @('create', 'namespace', $ns) | Out-Null
            Write-Host "Namespace $ns created." -ForegroundColor Green
        }

        if (Test-DoksKubectlResource -Kind secret -Name $SecretName -Namespace $ns) {
            Write-Host "  Secret $SecretName exists - left untouched."
        }
        else {
            $envKey = $ns -replace '^auth-', ''
            $dbName = $database.Info.databases.$envKey
            $role   = $database.Credentials.environments.$envKey
            if (-not $dbName -or -not $role) {
                throw "Terraform output 'database' has no environment '$envKey' for namespace $ns (var.environments in terraform/variables.tf lists: $(@($database.Info.databases.PSObject.Properties.Name) -join ', '))."
            }
            $modules = $database.Modules
            $modName = $modules.Info.databases.$envKey
            $modRole = $modules.Credentials.environments.$envKey
            if (-not $modName -or -not $modRole) {
                throw "Terraform output 'modules_database' has no environment '$envKey' for namespace $ns."
            }
            # the module service reads one URL (the password inside it URL-encoded)
            # and verifies the server against the cluster CA (PEM, indented into the block scalar)
            $modPassword = [System.Uri]::EscapeDataString($modRole.password)
            $caBlock = (($modules.Info.ca.Trim() -split "`r?`n") | ForEach-Object { '    ' + $_ }) -join "`n"
            # ${dbName} and ${modName} stay in braces: PowerShell would read $dbName?sslmode as one variable name
            $manifest = @"
apiVersion: v1
kind: Secret
metadata:
  name: $SecretName
  namespace: $ns
type: Opaque
stringData:
  db-host: "$($database.Info.host)"
  db-port: "$($database.Info.port)"
  db-name: "$dbName"
  db-url: "jdbc:postgresql://$($database.Info.host):$($database.Info.port)/${dbName}?sslmode=require"
  db-user: "$($role.user)"
  db-password: "$($role.password)"
  db-admin-user: "$($database.Credentials.admin.user)"
  db-admin-password: "$($database.Credentials.admin.password)"
  jwt-secret: "$(New-DoksRandomSecret -Bytes 48)"
  mysql-host: "$($modules.Info.host)"
  mysql-port: "$($modules.Info.port)"
  mysql-name: "$modName"
  mysql-admin-user: "$($modules.Credentials.admin.user)"
  mysql-admin-password: "$($modules.Credentials.admin.password)"
  mysql-ca: |
$caBlock
  database-url: "mysql+pymysql://$($modRole.user):$modPassword@$($modules.Info.host):$($modules.Info.port)/${modName}?charset=utf8mb4"
"@
            Invoke-KubectlManifest -Manifest $manifest -Arguments @('create', '-f', '-')
            Write-Host "  Secret $SecretName created (managed PostgreSQL $dbName as $($role.user), managed MySQL $modName as $($modRole.user), random jwt-secret)." -ForegroundColor Green
        }

        if ($GhcrUsername -and $GhcrToken) {
            if (Test-DoksKubectlResource -Kind secret -Name $PullSecretName -Namespace $ns) {
                Write-Host "  Pull secret $PullSecretName exists - left untouched."
            }
            else {
                $pat    = ConvertFrom-DoksSecureString -SecureString $GhcrToken
                $auth   = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${GhcrUsername}:$pat"))
                $config = @{ auths = @{ 'ghcr.io' = @{ username = $GhcrUsername; password = $pat; auth = $auth } } } | ConvertTo-Json -Compress -Depth 5
                $manifest = @"
apiVersion: v1
kind: Secret
metadata:
  name: $PullSecretName
  namespace: $ns
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($config)))
"@
                Invoke-KubectlManifest -Manifest $manifest -Arguments @('create', '-f', '-')
                Write-Host "  Pull secret $PullSecretName created." -ForegroundColor Green
            }
        }
    }
    if (-not ($GhcrUsername -and $GhcrToken)) {
        Write-Host 'No GHCR pull secret requested - assuming the GHCR packages are public.' -ForegroundColor DarkGray
    }

    # --- 2b. Monitoring secrets (Grafana admin, alert channel) ------------
    if (Test-DoksKubectlResource -Kind namespace -Name $MonitoringNamespace) {
        Write-Host "Namespace $MonitoringNamespace exists."
    }
    else {
        Invoke-Kubectl -Arguments @('create', 'namespace', $MonitoringNamespace) | Out-Null
        Write-Host "Namespace $MonitoringNamespace created." -ForegroundColor Green
    }

    if (Test-DoksKubectlResource -Kind secret -Name 'grafana-admin' -Namespace $MonitoringNamespace) {
        Write-Host '  Secret grafana-admin exists - left untouched.'
    }
    else {
        $manifest = @"
apiVersion: v1
kind: Secret
metadata:
  name: grafana-admin
  namespace: $MonitoringNamespace
type: Opaque
stringData:
  admin-user: admin
  admin-password: "$(New-DoksRandomSecret -Bytes 24)"
"@
        Invoke-KubectlManifest -Manifest $manifest -Arguments @('create', '-f', '-')
        Write-Host '  Secret grafana-admin created (random password).' -ForegroundColor Green
    }

    $webhookPlaceholder = 'https://alertmanager-webhook-not-configured.invalid/'
    $webhookUrl = $null
    if (Test-DoksKubectlResource -Kind secret -Name 'alertmanager-webhook' -Namespace $MonitoringNamespace) {
        Write-Host '  Secret alertmanager-webhook exists - left untouched.'
        try {
            $encoded = Invoke-Kubectl -Arguments @('-n', $MonitoringNamespace, 'get', 'secret', 'alertmanager-webhook', '-o', 'jsonpath={.data.webhook-url}')
            if ($encoded) { $webhookUrl = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($encoded -join '').Trim())) }
        }
        catch { }
    }
    else {
        if ($AlertWebhookUrl) {
            $webhookUrl = $AlertWebhookUrl
        }
        elseif (-not $NoAlertInbox) {
            $webhookUrl = New-DoksAlertInbox
        }
        if (-not $webhookUrl) { $webhookUrl = $webhookPlaceholder }
        $manifest = @"
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-webhook
  namespace: $MonitoringNamespace
type: Opaque
stringData:
  webhook-url: "$webhookUrl"
"@
        Invoke-KubectlManifest -Manifest $manifest -Arguments @('create', '-f', '-')
        if ($webhookUrl -eq $webhookPlaceholder) {
            Write-Warning 'alertmanager-webhook holds a placeholder that never delivers. Replace the Secret (bootstrap/README.md step 2) to receive notifications.'
        }
        else {
            Write-Host '  Secret alertmanager-webhook created (notification channel configured).' -ForegroundColor Green
        }
    }
    $alertInboxView = $null
    if ($webhookUrl -match '^https://webhook\.site/([0-9a-f-]{36})$') {
        $alertInboxView = "https://webhook.site/#!/view/$($Matches[1])"
        if (-not $AlertWebhookUrl) {
            try { Start-Process $alertInboxView } catch { Write-Host "  Open the alert inbox yourself: $alertInboxView" }
        }
    }

    # --- 3. ArgoCD (dedicated namespace) ----------------------------------
    $selfManaged = $false
    try { $selfManaged = Test-DoksKubectlResource -Kind application -Name argocd -Namespace argocd } catch { }
    if ($selfManaged) {
        Write-Host 'ArgoCD already manages itself (Application argocd exists) - change bootstrap/argocd-values.yaml via PR instead.' -ForegroundColor DarkGray
    }
    else {
        Write-Host "Installing ArgoCD (chart $ArgoCdChartVersion) ..." -ForegroundColor Cyan
        Invoke-Helm -Arguments @('repo', 'add', 'argo', 'https://argoproj.github.io/argo-helm', '--force-update') | Out-Null
        Invoke-Helm -Arguments @('repo', 'update', 'argo') | Out-Null
        Invoke-Helm -Arguments @(
            'upgrade', '--install', 'argocd', 'argo/argo-cd', '--version', $ArgoCdChartVersion,
            '--namespace', 'argocd', '--create-namespace',
            '--values', $argocdValues, '--wait'
        ) -Stream
    }

    # --- 4. Root application (ArgoCD takes over from here) ----------------
    Invoke-Kubectl -Arguments @('apply', '-f', $rootApp) | Out-Null
    Write-Host 'Root application applied - ArgoCD now syncs argocd/ from git.' -ForegroundColor Green

    # --- 5. Cluster facts into the repo: the nip.io hosts -----------------
    $lbIp = $null
    if ($NoHostUpdate) {
        Write-Host 'Host names not updated (-NoHostUpdate): run Sync-DoksHostname once the load balancer has an IP.' -ForegroundColor DarkGray
    }
    else {
        try { $lbIp = Sync-DoksHostname -RepoRoot $RepoRoot -TimeoutSeconds $HostTimeoutSeconds }
        catch { Write-Warning $_.Exception.Message }
    }

    # --- 6. Handover ------------------------------------------------------
    Write-Host ''
    Write-Host 'Bootstrap done. From here the cluster converges on git.' -ForegroundColor Green
    Write-Host '  Commit and push:     terraform/terraform.tfvars, charts/auth-stack/values-staging.yaml, values-prod.yaml, loadtest/job.yaml (the cluster facts this startup wrote; git status shows which changed)' -ForegroundColor Yellow
    Write-Host '  Watch convergence:   kubectl -n argocd get applications -w'
    Write-Host '  All UIs at once:     Connect-DoksPortForward   ->  ArgoCD :8080, Grafana :3000, Prometheus :9090, Alertmanager :9093 on localhost, with user + password per UI; lost forwards reconnect, Ctrl+C ends them'
    Write-Host '  Rotate ArgoCD pw:    argocd login localhost:8080 --plaintext; argocd account update-password; kubectl -n argocd delete secret argocd-initial-admin-secret'
    if ($lbIp) {
        Write-Host "  Environments:        https://auth-staging.$($lbIp -replace '\.', '-').nip.io   https://auth-prod.$($lbIp -replace '\.', '-').nip.io   (after the push; Let's Encrypt staging certificate, not browser-trusted)"
    }
    else {
        Write-Host '  Load balancer IP:    kubectl -n traefik get svc infra-traefik -o jsonpath="{.status.loadBalancer.ingress[0].ip}"  then Sync-DoksHostname writes it into the nip.io hosts'
    }
    if ($webhookUrl -eq $webhookPlaceholder) {
        Write-Host '  Alert channel:       placeholder - nothing is delivered until the alertmanager-webhook Secret is replaced' -ForegroundColor Yellow
    }
    else {
        Write-Host "  Alert channel:       $webhookUrl"
        if ($alertInboxView) {
            Write-Host "  Alert inbox (view):  $alertInboxView   (webhook.site; public to anyone with the link, expires 7 days after the last request)"
        }
    }
}

function New-DoksAlertInbox {
    <#
    .SYNOPSIS
        Creates a throwaway webhook.site inbox and returns its endpoint URL.
    .DESCRIPTION
        POST https://webhook.site/token allocates an inbox without an account. The
        endpoint https://webhook.site/<uuid> accepts any request and shows it live
        at https://webhook.site/#!/view/<uuid>. Returns $null (with a warning) when
        the service is unreachable, so the caller can fall back to a placeholder.
    #>
    [CmdletBinding()]
    param()
    try {
        $token = Invoke-RestMethod -Method Post -Uri 'https://webhook.site/token' -Headers @{ Accept = 'application/json' } -TimeoutSec 20
        if (-not $token.uuid) { throw 'response carries no uuid' }
        $url = "https://webhook.site/$($token.uuid)"
        Write-Host "  webhook.site inbox created as the alert channel: $url" -ForegroundColor Green
        return $url
    }
    catch {
        Write-Warning "Could not create a webhook.site inbox ($($_.Exception.Message)); the alert channel stays a placeholder."
        return $null
    }
}

function Sync-DoksHostname {
    <#
    .SYNOPSIS
        Writes the cluster's load balancer IP into the repo's nip.io host names.

    .DESCRIPTION
        The environments are reached through nip.io names that embed the Traefik
        load balancer IP (auth-staging.<a-b-c-d>.nip.io, auth-prod...), and a new
        cluster gets a new IP. This command waits until the ingress controller's
        LoadBalancer Service has one (ArgoCD deploys Traefik after the bootstrap;
        DigitalOcean needs a few minutes), then rewrites every nip.io host in
        charts/auth-stack/values-staging.yaml, values-prod.yaml and
        loadtest/job.yaml to that IP. Commit and push the result: ArgoCD then
        applies the Ingress hosts and cert-manager issues the certificates.
        Bootstrap-DoksCluster runs this as its last step; standalone it repeats
        the update for a cluster that already exists. Returns the IP.

    .PARAMETER RepoRoot
        Repository root. Default: the folder above this module.

    .PARAMETER TimeoutSeconds
        How long to wait for the load balancer IP. Default: 900.

    .EXAMPLE
        Sync-DoksHostname
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [string]$RepoRoot,
        [ValidateRange(0, 7200)][int]$TimeoutSeconds = 900,
        [string]$IngressNamespace = 'traefik',
        [string]$ServiceName = 'infra-traefik'
    )
    if (-not $env:KUBECONFIG) { throw 'No KUBECONFIG in this window - run Use-DoksCluster <name> first.' }
    if (-not $RepoRoot) { $RepoRoot = Split-Path -Path $PSScriptRoot -Parent }
    $RepoRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepoRoot)
    $files = @('charts/auth-stack/values-staging.yaml', 'charts/auth-stack/values-prod.yaml', 'loadtest/job.yaml') |
        ForEach-Object { Join-Path -Path $RepoRoot -ChildPath $_ } | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    if ($files.Count -eq 0) { throw "No values-*.yaml / loadtest/job.yaml under $RepoRoot - pass -RepoRoot pointing at the ops repository." }

    Write-Host "Waiting for the load balancer IP of $IngressNamespace/$ServiceName (ArgoCD deploys Traefik; DigitalOcean provisions the balancer) ..." -ForegroundColor Cyan
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $ip = $null
    do {
        try {
            $ip = (@(Invoke-Kubectl -Arguments @('-n', $IngressNamespace, 'get', 'svc', $ServiceName, '-o', 'jsonpath={.status.loadBalancer.ingress[0].ip}')) -join '').Trim()
        }
        catch { $ip = $null }
        if ($ip -match '^\d{1,3}(\.\d{1,3}){3}$') { break }
        $ip = $null
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSeconds) { break }
        Start-Sleep -Seconds 10
    } while ($true)
    if (-not $ip) { throw "No load balancer IP after $TimeoutSeconds s. Check 'kubectl -n argocd get applications' (infra-traefik must be Synced/Healthy) and re-run Sync-DoksHostname." }
    Write-Host "Load balancer IP: $ip (after $([int]$watch.Elapsed.TotalSeconds) s)" -ForegroundColor Green

    $dashed = $ip -replace '\.', '-'
    $pattern = '(?<=[.-])\d{1,3}-\d{1,3}-\d{1,3}-\d{1,3}(?=\.nip\.io)'
    $changed = @()
    foreach ($file in $files) {
        $content = [System.IO.File]::ReadAllText($file)
        $updated = [regex]::Replace($content, $pattern, $dashed)
        $relative = $file.Substring($RepoRoot.Length).TrimStart('\', '/')
        if ($updated -eq $content) {
            Write-Host "  $relative already uses $dashed.nip.io."
            continue
        }
        if ($PSCmdlet.ShouldProcess($relative, "nip.io hosts -> $dashed.nip.io")) {
            [System.IO.File]::WriteAllText($file, $updated)
            $hosts = @([regex]::Matches($updated, '[a-z0-9-]+\.' + [regex]::Escape($dashed) + '\.nip\.io') | ForEach-Object { $_.Value } | Sort-Object -Unique)
            Write-Host "  $relative -> $($hosts -join ', ')" -ForegroundColor Green
            $changed += $relative
        }
    }
    if ($changed.Count -gt 0) {
        Write-Host 'Commit and push these files: ArgoCD applies the Ingress hosts and cert-manager issues the certificates for them.' -ForegroundColor Yellow
    }
    $ip
}

# Every UI of interest inside the cluster, forwarded to localhost by
# Connect-DoksPortForward. Names and ports match bootstrap/README.md.
$script:PortForwardTargets = @(
    @{ Name = 'ArgoCD';       Namespace = 'argocd';     Target = 'svc/argocd-server';                          Ports = '8080:80';   Url = 'http://localhost:8080'; Note = 'user: admin' }
    @{ Name = 'Grafana';      Namespace = 'monitoring'; Target = 'svc/monitoring-grafana';                     Ports = '3000:80';   Url = 'http://localhost:3000'; Note = 'user: admin' }
    @{ Name = 'Prometheus';   Namespace = 'monitoring'; Target = 'svc/monitoring-kube-prometheus-prometheus';  Ports = '9090:9090'; Url = 'http://localhost:9090'; Note = 'targets, alerts, rules' }
    @{ Name = 'Alertmanager'; Namespace = 'monitoring'; Target = 'svc/monitoring-kube-prometheus-alertmanager'; Ports = '9093:9093'; Url = 'http://localhost:9093'; Note = 'grouped + delivered alerts' }
)
$script:PortForwards = @()

function Connect-DoksPortForward {
    <#
    .SYNOPSIS
        Forwards every UI of interest in the cluster to localhost with one command.

    .DESCRIPTION
        Starts one 'kubectl port-forward' per target (ArgoCD 8080, Grafana 3000,
        Prometheus 9090, Alertmanager 9093) against the cluster this window points
        at ($env:KUBECONFIG) and prints one line per UI: local URL, user name and
        password (read from the argocd-initial-admin-secret and grafana-admin
        Secrets; Prometheus and Alertmanager have no login). The forwards stay
        attached to this window: a lost forward (a pod restart ends it) is
        reported and retried every 10 seconds until it is back, which is reported
        too; Ctrl+C ends all of them. With -Background the forwards keep running
        after the command returns without reconnects; Disconnect-DoksPortForward
        ends them. Each forward's output goes to a log under the temp folder.

    .PARAMETER Background
        Return immediately and leave the forwards running without reconnects
        (Disconnect-DoksPortForward stops them).

    .EXAMPLE
        Connect-DoksPortForward
        Forwards everything; Ctrl+C ends the forwards.

    .EXAMPLE
        Connect-DoksPortForward -Background; Disconnect-DoksPortForward
    #>
    [CmdletBinding()]
    param([switch]$Background)

    if (-not $env:KUBECONFIG) { throw 'No KUBECONFIG in this window - run Use-DoksCluster <name> first.' }
    Disconnect-DoksPortForward -Quiet
    $kubectl = Get-DoksTool -Name kubectl
    $logDir = Join-Path ([IO.Path]::GetTempPath()) 'doks-port-forward'
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null

    $secret = {
        param([string]$Namespace, [string]$Name, [string]$Key)
        try {
            $encoded = Invoke-Kubectl -Arguments @('-n', $Namespace, 'get', 'secret', $Name, '-o', "jsonpath={.data.$Key}")
            if ($encoded) { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(($encoded -join '').Trim())) }
        }
        catch { }
        $null
    }
    $start = {
        param($Forward)
        $Forward.Process = Start-Process -FilePath $kubectl -PassThru -NoNewWindow `
            -ArgumentList @('-n', $Forward.Namespace, 'port-forward', $Forward.Target, $Forward.Ports) `
            -RedirectStandardOutput $Forward.Log -RedirectStandardError $Forward.Error
    }

    foreach ($t in $script:PortForwardTargets) {
        $user = $null; $password = $null
        switch ($t.Name) {
            'ArgoCD' {
                $user = 'admin'
                $password = & $secret 'argocd' 'argocd-initial-admin-secret' 'password'
                if (-not $password) { $password = '(rotated: argocd-initial-admin-secret is deleted)' }
            }
            'Grafana' {
                $user = & $secret 'monitoring' 'grafana-admin' 'admin-user'
                $password = & $secret 'monitoring' 'grafana-admin' 'admin-password'
                if (-not $user) { $user = 'admin' }
                if (-not $password) { $password = '(Secret grafana-admin not found)' }
            }
        }
        $f = [pscustomobject]@{
            Name = $t.Name; Namespace = $t.Namespace; Target = $t.Target; Ports = $t.Ports; Url = $t.Url; Note = $t.Note
            User = $user; Password = $password; Process = $null; Down = $false; NextAttempt = [datetime]::MinValue
            Log = (Join-Path $logDir "$($t.Name.ToLower()).log"); Error = (Join-Path $logDir "$($t.Name.ToLower()).err")
        }
        & $start $f
        $script:PortForwards += $f
    }
    Start-Sleep -Milliseconds 1500
    Write-Host 'Port-forwards (this window, cluster from KUBECONFIG):' -ForegroundColor Cyan
    foreach ($f in $script:PortForwards) {
        $up = -not $f.Process.HasExited
        $login = if ($f.User) { "user: $($f.User)   password: $($f.Password)" } else { 'user: -   password: -   (no login)' }
        Write-Host ("  {0,-13} {1,-23} {2}" -f $f.Name, $f.Url, $login) -ForegroundColor $(if ($up) { 'Green' } else { 'Red' })
        if (-not $up) {
            $f.Down = $true; $f.NextAttempt = [datetime]::UtcNow.AddSeconds(10)
            Get-Content -Path $f.Error -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
        }
    }
    if ($Background) {
        Write-Host 'Running in the background (no reconnects) - Disconnect-DoksPortForward ends them.' -ForegroundColor DarkGray
        return
    }
    Write-Host 'Lost forwards are retried every 10 s. Ctrl+C ends all forwards.' -ForegroundColor DarkGray
    try {
        while ($true) {
            Start-Sleep -Seconds 2
            $now = [datetime]::UtcNow
            foreach ($f in $script:PortForwards) {
                if (-not $f.Down -and $f.Process.HasExited) {
                    $f.Down = $true
                    $f.NextAttempt = $now.AddSeconds(10)
                    $reason = @(Get-Content -Path $f.Error -ErrorAction SilentlyContinue | Where-Object { $_.Trim() } | Select-Object -Last 1) -join ''
                    Write-Host ("{0:HH:mm:ss}  {1}: connection lost{2} - retrying every 10 s" -f [datetime]::Now, $f.Name, $(if ($reason) { " ($reason)" } else { '' })) -ForegroundColor Yellow
                }
                elseif ($f.Down -and $now -ge $f.NextAttempt) {
                    & $start $f
                    Start-Sleep -Milliseconds 1500
                    if ($f.Process.HasExited) {
                        $f.NextAttempt = [datetime]::UtcNow.AddSeconds(10)
                    }
                    else {
                        $f.Down = $false
                        Write-Host ("{0:HH:mm:ss}  {1}: reconnected - {2}" -f [datetime]::Now, $f.Name, $f.Url) -ForegroundColor Green
                    }
                }
            }
        }
    }
    finally {
        Disconnect-DoksPortForward
    }
}

function Disconnect-DoksPortForward {
    <#
    .SYNOPSIS
        Ends the port-forwards started by Connect-DoksPortForward.
    #>
    [CmdletBinding()]
    param([switch]$Quiet)
    $stopped = 0
    foreach ($f in $script:PortForwards) {
        if (-not $f.Process.HasExited) {
            try { Stop-Process -Id $f.Process.Id -Force -ErrorAction Stop; $stopped++ } catch { }
        }
    }
    $script:PortForwards = @()
    if (-not $Quiet) { Write-Host "Port-forwards ended ($stopped stopped)." -ForegroundColor DarkGray }
}

function Test-DoksSetup {
    [CmdletBinding()]
    param()
    $rows = New-Object System.Collections.Generic.List[object]
    $add = {
        param($Check, $Ok, $Detail)
        $rows.Add([pscustomobject]@{ Check = $Check; Status = $(if ($Ok) { 'OK' } else { 'MISSING' }); Detail = $Detail })
    }

    foreach ($tool in 'doctl', 'kubectl', 'helm', 'terraform') {
        try {
            $path = Get-DoksTool -Name $tool
            $ver = ''
            try {
                if ($tool -eq 'doctl') { $ver = @(Invoke-Doctl -Arguments @('version'))[0] }
                elseif ($tool -eq 'helm') { $ver = "helm $(@(Invoke-Helm -Arguments @('version', '--short'))[0])" }
                elseif ($tool -eq 'terraform') { $ver = @(& $path version)[0] }
                else {
                    $v = Invoke-Kubectl -Arguments @('version', '--client') -Json
                    if ($v -and $v.clientVersion) { $ver = "kubectl $($v.clientVersion.gitVersion)" }
                }
            } catch { $ver = '(version check failed)' }
            & $add $tool $true "$path  $ver".Trim()
        }
        catch { & $add $tool $false $_.Exception.Message }
    }

    $tokenSource = $null
    if ($env:DIGITALOCEAN_ACCESS_TOKEN) { $tokenSource = '$env:DIGITALOCEAN_ACCESS_TOKEN is set in this session' }
    try {
        $stored = Read-DoksStoredToken
        if ($stored) {
            $detail = "$(Get-DoksTokenStoreName) (user: $($stored.User))"
            if ($tokenSource) { $detail += "; $tokenSource" }
            $tokenSource = $detail
        }
    } catch { & $add 'Token store' $false $_.Exception.Message }
    if ($tokenSource) { & $add 'API token' $true $tokenSource }
    else { & $add 'API token' $false "none stored - run Set-DoksToken (doctl's own config is tried as a fallback)" }

    try {
        $script:AuthVerified = $false
        $account = Connect-DoksAccount -Quiet
        & $add 'DigitalOcean API' $true "authenticated as $($account.email)"
    }
    catch { & $add 'DigitalOcean API' $false $_.Exception.Message }

    try {
        $dir = Get-DoksKubeconfigDir
        $probe = Join-Path -Path $dir -ChildPath ".doks-write-test-$PID"
        [System.IO.File]::WriteAllText($probe, 'ok')
        Remove-Item -LiteralPath $probe -Force
        & $add 'Kubeconfig folder' $true $dir
    }
    catch { & $add 'Kubeconfig folder' $false $_.Exception.Message }

    if ($env:KUBECONFIG) {
        $ctx = ''
        try { $ctx = @(Invoke-Kubectl -Arguments @('config', 'current-context')) -join '' } catch { $ctx = '(unreadable)' }
        & $add 'Session KUBECONFIG' $true "$env:KUBECONFIG -> context $ctx"
    }
    else { & $add 'Session KUBECONFIG' $true 'not set (kubectl uses its normal config)' }

    $sources = 'built-in only'
    if ($script:DefaultSources.Count -gt 0) { $sources = "built-in, then " + ($script:DefaultSources -join ', ') }
    & $add 'Defaults' $true "$sources; module folder $PSScriptRoot"

    $rows
}

# ---------------------------------------------------------------------------
# Verification: Start-DoksLoadTest (loadtest/) and Test-DoksStack (the checks
# of bootstrap/README.md and loadtest/README.md, in order)
# ---------------------------------------------------------------------------

function Get-DoksCurl {
    # curl.exe (Windows ships one under System32, Git for Windows another) - not
    # the Invoke-WebRequest alias of Windows PowerShell.
    if ($script:ToolPaths['curl']) { return $script:ToolPaths['curl'] }
    $cmd = Get-Command -Name 'curl.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) { $cmd = Get-Command -Name 'curl' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $cmd) { throw "curl was not found on PATH (Windows 10 and later ship C:\Windows\System32\curl.exe)." }
    $script:ToolPaths['curl'] = $cmd.Source
    $cmd.Source
}

function Invoke-DoksHttp {
    # One HTTP call through curl: -k because the environments carry Let's Encrypt
    # staging certificates, the body via stdin so credentials never reach a
    # command line. Never throws on HTTP errors; Code is 0 when nothing answered.
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$Method = 'GET',
        [hashtable]$Headers = @{},
        [string]$Body,
        [string]$BasicAuth,
        [int]$TimeoutSeconds = 30
    )
    $curl = Get-DoksCurl
    $headerFile = [IO.Path]::GetTempFileName()
    $bodyFile = [IO.Path]::GetTempFileName()
    try {
        $arguments = @('-sk', '-m', "$TimeoutSeconds", '-o', $bodyFile, '-D', $headerFile, '-w', '%{http_code}', '-X', $Method)
        foreach ($name in $Headers.Keys) { $arguments += @('-H', "${name}: $($Headers[$name])") }
        if ($BasicAuth) { $arguments += @('-u', $BasicAuth) }
        $hasBody = $PSBoundParameters.ContainsKey('Body')
        if ($hasBody) { $arguments += @('-H', 'Content-Type: application/json', '--data-binary', '@-') }
        $arguments += $Url
        $ErrorActionPreference = 'Continue'
        if ($hasBody) { $code = @($Body | & $curl @arguments 2>$null) -join '' }
        else { $code = @(& $curl @arguments 2>$null) -join '' }
        $responseHeaders = @{}
        foreach ($line in @(Get-Content -Path $headerFile -ErrorAction SilentlyContinue)) {
            if ($line -match '^HTTP/') { $responseHeaders = @{}; continue }
            if ($line -match '^([^:]+):\s*(.*)$') { $responseHeaders[$Matches[1].Trim().ToLowerInvariant()] = $Matches[2].Trim() }
        }
        $content = ''
        if (Test-Path -LiteralPath $bodyFile) { $content = [System.IO.File]::ReadAllText($bodyFile) }
        [pscustomobject]@{ Code = [int]("0$code" -replace '[^0-9]', ''); Headers = $responseHeaders; Body = $content }
    }
    finally {
        Remove-Item -LiteralPath $headerFile, $bodyFile -Force -ErrorAction SilentlyContinue
    }
}

function ConvertFrom-DoksJsonBody {
    param([string]$Text)
    if (-not $Text -or -not $Text.Trim()) { return $null }
    try { ConvertFrom-Json -InputObject $Text } catch { $null }
}

function Get-DoksSecretValue {
    param([Parameter(Mandatory)][string]$Namespace, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Key)
    try {
        $encoded = @(Invoke-DoksKubectlProbe -Arguments @('-n', $Namespace, 'get', 'secret', $Name, '-o', "jsonpath={.data.$Key}")) -join ''
        if ($encoded.Trim()) { return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded.Trim())) }
    }
    catch { }
    $null
}

function Invoke-DoksKubectlProbe {
    # Invoke-Kubectl with three attempts: a verification must not fail on a
    # transient DNS or connection error of the workstation.
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Json)
    $attempt = 0
    while ($true) {
        $attempt++
        try { return (Invoke-Kubectl -Arguments $Arguments -Json:$Json) }
        catch {
            if ($attempt -ge 3 -or $_.Exception.Message -notmatch 'no such host|Unable to connect to the server|connection refused|i/o timeout|TLS handshake timeout|EOF') { throw }
            Start-Sleep -Seconds 3
        }
    }
}

function Get-DoksEnvironmentHost {
    # The public host of an environment: the frontend Ingress carries it.
    param([Parameter(Mandatory)][string]$Namespace)
    $hostName = (@(Invoke-DoksKubectlProbe -Arguments @('-n', $Namespace, 'get', 'ingress', 'auth-frontend', '-o', 'jsonpath={.spec.rules[0].host}')) -join '').Trim()
    if (-not $hostName) { throw "Ingress auth-frontend in $Namespace has no host - Sync-DoksHostname, committed and synced?" }
    $hostName
}

function Invoke-DoksPrometheusQuery {
    # Instant query through the API server's service proxy: no port-forward, no
    # login (Prometheus has none). Returns the result vector.
    param([Parameter(Mandatory)][string]$Query)
    $path = '/api/v1/namespaces/monitoring/services/monitoring-kube-prometheus-prometheus:9090/proxy/api/v1/query?query=' + [Uri]::EscapeDataString($Query)
    $raw = (@(Invoke-DoksKubectlProbe -Arguments @('get', '--raw', $path)) -join "`n").Trim()
    $answer = ConvertFrom-Json -InputObject $raw
    if ($answer.status -ne 'success') { throw "Prometheus answered $($answer.status): $($answer.error)" }
    @($answer.data.result)
}

function Start-DoksProbeForward {
    # A port-forward on a free local port for the duration of one check
    # (Grafana needs its login header, Alertmanager a POST - neither goes
    # through the API server proxy).
    param([Parameter(Mandatory)][string]$Namespace, [Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][int]$RemotePort)
    $kubectl = Get-DoksTool -Name kubectl
    $log = [IO.Path]::GetTempFileName()
    $err = [IO.Path]::GetTempFileName()
    $process = Start-Process -FilePath $kubectl -PassThru -NoNewWindow `
        -ArgumentList @('-n', $Namespace, 'port-forward', $Target, ":$RemotePort") `
        -RedirectStandardOutput $log -RedirectStandardError $err
    $port = 0
    for ($i = 0; $i -lt 80; $i++) {
        Start-Sleep -Milliseconds 250
        $line = @(Get-Content -Path $log -ErrorAction SilentlyContinue | Where-Object { $_ -match 'Forwarding from 127\.0\.0\.1:(\d+)' } | Select-Object -First 1) -join ''
        if ($line -match 'Forwarding from 127\.0\.0\.1:(\d+)') { $port = [int]$Matches[1]; break }
        if ($process.HasExited) { break }
    }
    if (-not $port) {
        $reason = @(Get-Content -Path $err -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }) -join ' '
        try { Stop-Process -Id $process.Id -Force -ErrorAction Stop } catch { }
        Remove-Item -LiteralPath $log, $err -Force -ErrorAction SilentlyContinue
        throw "port-forward to $Namespace/$Target did not come up: $reason"
    }
    [pscustomobject]@{ Process = $process; Port = $port; Url = "http://127.0.0.1:$port"; Log = $log; Error = $err }
}

function Stop-DoksProbeForward {
    param($Forward)
    if (-not $Forward) { return }
    if (-not $Forward.Process.HasExited) { try { Stop-Process -Id $Forward.Process.Id -Force -ErrorAction Stop } catch { } }
    Remove-Item -LiteralPath $Forward.Log, $Forward.Error -Force -ErrorAction SilentlyContinue
}

function Initialize-DoksTestUserSecret {
    # The load test's account (loadtest/README.md step 1): namespace + Secret
    # with a random password, created once, never printed. Returns the email.
    param([Parameter(Mandatory)][string]$Namespace, [Parameter(Mandatory)][string]$SecretName, [string]$Email = 'k6-loadtest@example.com')
    if (-not (Test-DoksKubectlResource -Kind namespace -Name $Namespace)) {
        Invoke-DoksKubectlProbe -Arguments @('create', 'namespace', $Namespace) | Out-Null
    }
    $existing = Get-DoksSecretValue -Namespace $Namespace -Name $SecretName -Key email
    if ($existing) { return $existing }
    $password = New-DoksRandomSecret -Bytes 24
    $manifest = @"
apiVersion: v1
kind: Secret
metadata:
  name: $SecretName
  namespace: $Namespace
type: Opaque
stringData:
  email: "$Email"
  password: "$password"
"@
    Invoke-KubectlManifest -Manifest $manifest -Arguments @('create', '-f', '-')
    Write-Host "  Secret $Namespace/$SecretName created: $Email with a random password (registered on first use; the first user registered in an environment becomes ADMIN)." -ForegroundColor DarkGray
    $Email
}

function Get-DoksLoadTestManifest {
    # kustomize output of loadtest/ with the Job pointed at the environment's
    # host (TARGET_URL) and, when given, the plateau (PEAK_VUS).
    param([Parameter(Mandatory)][string]$LoadDir, [Parameter(Mandatory)][string]$HostName, [int]$PeakVus)
    $rendered = (@(Invoke-DoksKubectlProbe -Arguments @('kustomize', $LoadDir)) -join "`n")
    $rendered = [regex]::Replace($rendered, '(?m)(- name: TARGET_URL\r?\n\s+value: )\S+', ('${1}https://' + $HostName))
    if ($PeakVus -gt 0) { $rendered = [regex]::Replace($rendered, '(?m)(- name: PEAK_VUS\r?\n\s+value: )"?\d+"?', ('${1}"' + $PeakVus + '"')) }
    $rendered
}

function Start-DoksLoadTest {
    <#
    .SYNOPSIS
        Starts the k6 load test of loadtest/ against an environment and follows it to the end.

    .DESCRIPTION
        loadtest/README.md as one command: makes sure the test account's Secret
        exists (namespace loadtest, Secret k6-test-user, random password),
        renders loadtest/ with kustomize, points the Job at the environment's
        public host (the frontend Ingress of auth-<environment>), replaces a
        previous Job and applies it. Then it follows the run: every 30 seconds
        one line with the backend HPA (CPU against its target, replicas) and the
        k6 pod's phase, until the Job is Complete (thresholds held) or Failed
        (a threshold was breached - that is the result). The k6 threshold
        lines are printed at the end; the k6 metrics stay in Prometheus under
        testid = the pod name (Grafana: k6 load test).
        The account is registered by k6 on first use. The first user ever
        registered in an environment becomes ADMIN (seed SQL): register your
        own admin before the first run against a fresh environment.

    .PARAMETER Environment
        staging (default) or prod.

    .PARAMETER PeakVus
        Virtual users at the plateau. Default: the value in loadtest/job.yaml (5).

    .PARAMETER RepoRoot
        Repository root containing loadtest/. Default: the folder above this module.

    .PARAMETER NoWait
        Return right after the Job is created; follow it with
        kubectl -n loadtest logs -f job/k6-user-mgmt-service.

    .EXAMPLE
        Start-DoksLoadTest
        Staging, 5 virtual users, followed to the end.

    .EXAMPLE
        Start-DoksLoadTest -Environment prod -PeakVus 8 -NoWait
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('staging', 'prod')][string]$Environment = 'staging',
        [ValidateRange(1, 200)][int]$PeakVus,
        [string]$RepoRoot,
        [switch]$NoWait,
        [string]$Namespace = 'loadtest',
        [string]$SecretName = 'k6-test-user',
        [string]$JobName = 'k6-user-mgmt-service'
    )
    if (-not $env:KUBECONFIG) { throw 'No KUBECONFIG in this window - run Use-DoksCluster <name> first.' }
    if (-not $RepoRoot) { $RepoRoot = Split-Path -Path $PSScriptRoot -Parent }
    $RepoRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepoRoot)
    $loadDir = Join-Path -Path $RepoRoot -ChildPath 'loadtest'
    if (-not (Test-Path -LiteralPath (Join-Path -Path $loadDir -ChildPath 'kustomization.yaml') -PathType Leaf)) { throw "No loadtest/kustomization.yaml under $RepoRoot - pass -RepoRoot pointing at the ops repository." }
    $ns = "auth-$Environment"
    $hostName = Get-DoksEnvironmentHost -Namespace $ns
    $email = Initialize-DoksTestUserSecret -Namespace $Namespace -SecretName $SecretName
    $manifest = Get-DoksLoadTestManifest -LoadDir $loadDir -HostName $hostName -PeakVus $PeakVus
    $peak = [regex]::Match($manifest, '(?m)- name: PEAK_VUS\r?\n\s+value: "?(\d+)"?').Groups[1].Value
    if (-not $PSCmdlet.ShouldProcess("$Namespace/$JobName", "k6 against https://$hostName, peak $peak VUs, account $email")) { return }
    try { Invoke-DoksKubectlProbe -Arguments @('-n', $Namespace, 'delete', 'job', $JobName, '--ignore-not-found', '--wait=true') | Out-Null } catch { }
    Invoke-KubectlManifest -Manifest $manifest -Arguments @('apply', '-f', '-')
    Write-Host "k6 Job $Namespace/$JobName -> https://$hostName as $email, peak $peak VUs (9 minutes: ramp, plateau, ramp down)." -ForegroundColor Cyan
    if ($NoWait) {
        Write-Host "  Follow it: kubectl -n $Namespace logs -f job/$JobName   (HPA: kubectl -n $ns get hpa auth-backend -w)" -ForegroundColor DarkGray
        return [pscustomobject]@{ Environment = $Environment; Host = $hostName; PeakVus = [int]$peak; Result = 'Started'; Minutes = 0; MinReplicas = $null; MaxReplicas = $null; TestId = $null }
    }
    Write-Host "  Every 30 s: the backend HPA of $ns and the k6 pod." -ForegroundColor DarkGray
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    $maxReplicas = 0; $minReplicas = [int]::MaxValue; $phase = 'Pending'; $result = 'Timeout'; $testId = $null; $misses = 0
    while ($watch.Elapsed.TotalMinutes -lt 25) {
        Start-Sleep -Seconds 30
        try { $job = Invoke-DoksKubectlProbe -Arguments @('-n', $Namespace, 'get', 'job', $JobName) -Json; $misses = 0 }
        catch {
            $misses++
            $reason = ($_.Exception.Message -replace '\s+', ' '); if ($reason.Length -gt 120) { $reason = $reason.Substring(0, 120) + '...' }
            Write-Host ("  {0:mm\:ss}  kubectl unreachable ({1}) - the Job keeps running, retrying" -f $watch.Elapsed, $reason) -ForegroundColor Yellow
            if ($misses -ge 8) { throw "kubectl unreachable for $misses polls in a row: $reason" }
            continue
        }
        $hpaText = 'no HPA'
        try {
            $hpa = Invoke-DoksKubectlProbe -Arguments @('-n', $ns, 'get', 'hpa', 'auth-backend') -Json
            $current = [int]$hpa.status.currentReplicas
            $utilisation = @($hpa.status.currentMetrics | ForEach-Object { $_.resource.current.averageUtilization } | Where-Object { $null -ne $_ })
            if ($current -gt $maxReplicas) { $maxReplicas = $current }
            if ($current -lt $minReplicas) { $minReplicas = $current }
            $hpaText = "backend cpu $(if ($utilisation.Count) { "$($utilisation[0])%" } else { '?' })/$($hpa.spec.metrics[0].resource.target.averageUtilization)%, replicas $current (desired $($hpa.status.desiredReplicas))"
        }
        catch { }
        $pods = @()
        try { $pods = @((Invoke-DoksKubectlProbe -Arguments @('-n', $Namespace, 'get', 'pods', '-l', "job-name=$JobName") -Json).items) } catch { }
        if ($pods.Count -gt 0) { $phase = $pods[-1].status.phase; $testId = $pods[-1].metadata.name }
        Write-Host ("  {0:mm\:ss}  {1}  k6 pod {2}" -f $watch.Elapsed, $hpaText, $phase) -ForegroundColor DarkGray
        if ([int]$job.status.succeeded -ge 1) { $result = 'Complete'; break }
        if ([int]$job.status.failed -ge 1) { $result = 'Failed'; break }
    }
    $summary = @()
    try { $summary = @(Invoke-DoksKubectlProbe -Arguments @('-n', $Namespace, 'logs', "job/$JobName", '--tail=80')) } catch { }
    foreach ($line in @($summary | Where-Object { $_ -match 'http_req_failed|http_req_duration|checks|thresholds|setup:' })) { Write-Host "    $($line.TrimEnd())" -ForegroundColor DarkGray }
    $replicas = if ($maxReplicas -gt 0) { "backend replicas $minReplicas to $maxReplicas" } else { 'HPA not read' }
    switch ($result) {
        'Complete' { Write-Host "k6 Complete after $([int]$watch.Elapsed.TotalMinutes) min: every threshold held; $replicas. Metrics: Grafana > auth-stack > k6 load test, testid=$testId." -ForegroundColor Green }
        'Failed' { Write-Host "k6 Failed after $([int]$watch.Elapsed.TotalMinutes) min: a threshold was breached (the lines above); $replicas. Metrics: testid=$testId." -ForegroundColor Red }
        default { Write-Host "k6 did not finish within 25 minutes (pod $phase): kubectl -n $Namespace describe job $JobName" -ForegroundColor Red }
    }
    [pscustomobject]@{ Environment = $Environment; Host = $hostName; PeakVus = [int]$peak; Result = $result; Minutes = [int]$watch.Elapsed.TotalMinutes; MinReplicas = $(if ($maxReplicas -gt 0) { $minReplicas } else { $null }); MaxReplicas = $(if ($maxReplicas -gt 0) { $maxReplicas } else { $null }); TestId = $testId }
}

function Invoke-DoksUserStorm {
    # Parallel user sessions against one environment: every interaction a user
    # or an API client performs (sign-up, login, profile, module list, module
    # assignment and removal, logout, a wrong password), repeated by N sessions
    # for a number of seconds. Mode 'distinct' gives every session its own
    # account (k6-loadtest+<n>@...), 'shared' lets every session use the test
    # account - the two together separate throughput from per-user contention.
    # Returns one row per interaction type: calls, errors, avg, p95, max seconds.
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$Email,
        [Parameter(Mandatory)][string]$Password,
        [ValidateSet('distinct', 'shared')][string]$Mode = 'distinct',
        [ValidateRange(1, 64)][int]$Sessions = 8,
        [ValidateRange(5, 600)][int]$Seconds = 45
    )
    $curl = Get-DoksCurl
    $worker = {
        param([string]$Curl, [string]$HostName, [string]$Email, [string]$Password, [int]$Seconds, [int]$Session, [string]$Mode)
        $results = New-Object System.Collections.Generic.List[object]
        $temp = [IO.Path]::GetTempPath()
        $jar = Join-Path $temp ("doks-storm-{0}-{1}.cookies" -f $PID, $Session)
        function Invoke-Call {
            param([string]$Type, [string]$Method, [string]$Url, [string]$Body, [string]$Token, [switch]$Cookies, [int[]]$Expect)
            $bodyFile = Join-Path $temp ("doks-storm-{0}-{1}.body" -f $PID, $Session)
            $headerFile = Join-Path $temp ("doks-storm-{0}-{1}.headers" -f $PID, $Session)
            $arguments = @('-sk', '-m', '60', '-o', $bodyFile, '-D', $headerFile, '-w', '%{http_code} %{time_total}', '-X', $Method, '-H', 'Content-Type: application/json')
            if ($Token) { $arguments += @('-H', "Authorization: Bearer $Token") }
            if ($Cookies) { $arguments += @('-b', $jar, '-c', $jar) }
            if ($Body) { $arguments += @('--data-binary', '@-') }
            $arguments += $Url
            $ErrorActionPreference = 'Continue'
            if ($Body) { $out = @($Body | & $Curl @arguments 2>$null) -join '' } else { $out = @(& $Curl @arguments 2>$null) -join '' }
            $parts = $out.Trim() -split '\s+'
            $code = 0; $seconds = 0.0
            if ($parts.Count -ge 1) { $code = [int]("0" + ($parts[0] -replace '[^0-9]', '')) }
            if ($parts.Count -ge 2) { $seconds = [double]::Parse($parts[1], [Globalization.CultureInfo]::InvariantCulture) }
            $content = ''; $auth = ''
            if (Test-Path -LiteralPath $bodyFile) { $content = [IO.File]::ReadAllText($bodyFile) }
            if (Test-Path -LiteralPath $headerFile) {
                $line = @(Get-Content -Path $headerFile | Where-Object { $_ -match '^[Aa]uthorization:\s*Bearer\s+(\S+)' } | Select-Object -Last 1) -join ''
                if ($line -match 'Bearer\s+(\S+)') { $auth = $Matches[1] }
            }
            $results.Add([pscustomobject]@{ Type = $Type; Code = $code; Seconds = $seconds; Ok = ($Expect -contains $code) })
            [pscustomobject]@{ Code = $code; Body = $content; Token = $auth }
        }
        $account = $Email
        if ($Mode -eq 'distinct') { $account = $Email -replace '@', "+s$Session@" }
        $credentials = '{"email":"' + $account + '","password":"' + ($Password -replace '"', '\"') + '"}'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $first = $true
        while ($watch.Elapsed.TotalSeconds -lt $Seconds) {
            Remove-Item -LiteralPath $jar -Force -ErrorAction SilentlyContinue
            if ($first -and $Mode -eq 'distinct') {
                # 201 new, 409 exists; the backend answers a duplicate with 500 today
                Invoke-Call -Type 'signup' -Method POST -Url "https://$HostName/api/signup" -Body ('{"firstName":"storm","lastName":"session' + $Session + '","email":"' + $account + '","password":"' + ($Password -replace '"', '\"') + '"}') -Expect @(201, 409, 500) | Out-Null
            }
            $first = $false
            $login = Invoke-Call -Type 'login' -Method POST -Url "https://$HostName/users/login" -Body $credentials -Expect @(200)
            $token = $login.Token
            if (-not $token) { Start-Sleep -Milliseconds 500; continue }
            $me = Invoke-Call -Type 'profile' -Method GET -Url "https://$HostName/users/me" -Token $token -Expect @(200)
            $userId = ''
            try { $userId = (ConvertFrom-Json -InputObject $me.Body).id } catch { }
            $modules = Invoke-Call -Type 'modules' -Method GET -Url "https://$HostName/modules" -Token $token -Expect @(200)
            $moduleId = ''
            try { $list = @(ConvertFrom-Json -InputObject $modules.Body); if ($list.Count -gt 0) { $moduleId = $list[0].id } } catch { }
            if ($userId -and $moduleId) {
                Invoke-Call -Type 'assign' -Method POST -Url "https://$HostName/users/$userId/modules/$moduleId" -Token $token -Expect @(200) | Out-Null
                Invoke-Call -Type 'unassign' -Method DELETE -Url "https://$HostName/users/$userId/modules/$moduleId" -Token $token -Expect @(200) | Out-Null
            }
            Invoke-Call -Type 'login (frontend)' -Method POST -Url "https://$HostName/api/login" -Body $credentials -Cookies -Expect @(200) | Out-Null
            Invoke-Call -Type 'profile (frontend)' -Method GET -Url "https://$HostName/api/me" -Cookies -Expect @(200) | Out-Null
            Invoke-Call -Type 'logout (frontend)' -Method POST -Url "https://$HostName/api/logout" -Cookies -Expect @(200, 204) | Out-Null
            Invoke-Call -Type 'wrong password' -Method POST -Url "https://$HostName/users/login" -Body ('{"email":"' + $account + '","password":"not-the-password"}') -Expect @(401, 403) | Out-Null
        }
        Remove-Item -LiteralPath $jar, (Join-Path $temp ("doks-storm-{0}-{1}.body" -f $PID, $Session)), (Join-Path $temp ("doks-storm-{0}-{1}.headers" -f $PID, $Session)) -Force -ErrorAction SilentlyContinue
        $results
    }
    $jobs = @()
    for ($n = 1; $n -le $Sessions; $n++) {
        $jobs += Start-Job -ScriptBlock $worker -ArgumentList $curl, $HostName, $Email, $Password, $Seconds, $n, $Mode
    }
    $null = Wait-Job -Job $jobs -Timeout ($Seconds + 180)
    $samples = @()
    foreach ($job in $jobs) {
        if ($job.State -eq 'Completed') { $samples += @(Receive-Job -Job $job) }
        else { Write-Verbose "storm session $($job.Id) ended in state $($job.State)" }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
    $order = @('signup', 'login', 'profile', 'modules', 'assign', 'unassign', 'login (frontend)', 'profile (frontend)', 'logout (frontend)', 'wrong password')
    $rows = @()
    foreach ($type in $order) {
        $set = @($samples | Where-Object { $_.Type -eq $type })
        if ($set.Count -eq 0) { continue }
        $sorted = @($set | ForEach-Object { [double]$_.Seconds } | Sort-Object)
        $p95 = $sorted[[Math]::Min($sorted.Count - 1, [Math]::Floor(0.95 * $sorted.Count))]
        $sum = 0.0; foreach ($v in $sorted) { $sum += $v }
        $rows += [pscustomobject]@{
            Type = $type; Calls = $set.Count; Errors = @($set | Where-Object { -not $_.Ok }).Count
            Avg = [Math]::Round($sum / $sorted.Count, 2); P95 = [Math]::Round($p95, 2); Max = [Math]::Round($sorted[-1], 2)
            Codes = (@($set | Group-Object Code | Sort-Object Count -Descending | ForEach-Object { "$($_.Name) x$($_.Count)" }) -join ' ')
        }
    }
    $rows
}

function Test-DoksStack {
    <#
    .SYNOPSIS
        Runs the platform's verification steps in order against the connected cluster.

    .DESCRIPTION
        The checks of bootstrap/README.md and loadtest/README.md as one command,
        in the order the stack is built. One row per check (Step, Check, Status
        OK / FAIL / SKIP, Detail), printed as it completes and returned at the end:
          1. cluster      every node Ready
          2. gitops       every ArgoCD Application Synced and Healthy
          3. workloads    per environment: Deployments available, seed Jobs
                          succeeded, the HPA reads its metric
          4. tls          the environment's Certificate is Ready (step 7)
          5. front door   the public host answers: / redirects to the login
                          page, /api/me and /users refuse anonymous callers
          6. policies     ClusterPolicies ready; charts/policies/tests/violations.yaml
                          is denied by the admission webhook with nothing
                          created; no failed policy report in the application
                          namespaces (step 11)
          7. monitoring   Prometheus scrapes every component of every
                          environment and every platform job, the environments'
                          PrometheusRules exist, Grafana answers a query through
                          its Prometheus datasource and carries the repository's
                          dashboards, Alertmanager accepts a synthetic alert and
                          routes it to the webhook receiver (step 10; the
                          delivery itself shows up in the channel's inbox)
          8. end to end   log in as the test account, list the modules through
                          the module service, assign one, get 404 for an unknown
                          one, read the assignment back, unassign it (step 12)
          9. parallel     every user interaction (sign-up, login, profile,
             users        module list, assign and remove a module, the
                          frontend's login/profile/logout, a wrong password)
                          from -ParallelSessions sessions at once for
                          -ParallelSeconds, first with one account per session,
                          then all on the shared test account; per interaction
                          calls, errors, average, p95 and maximum; FAIL when a
                          p95 exceeds the load test's thresholds (login and
                          modules 2 s, profile 1 s) or more than 5 % fail
         10. load test    with -LoadTest: Start-DoksLoadTest per environment -
                          the thresholds decide, the HPA replicas are reported
        Steps 8 to 10 need the load test's account (Secret k6-test-user in
        namespace loadtest). Without it, or when it cannot log in, they are
        SKIP: Start-DoksLoadTest creates and registers it, -CreateTestUser does
        the same here. The first user ever registered in an environment becomes
        ADMIN (seed SQL), so register your own admin first. Step 9 registers
        one extra account per session (k6-loadtest+s<n>@..., same password).

    .PARAMETER Environment
        Environments to verify: staging, prod (namespace auth-<name>). Default: both.

    .PARAMETER RepoRoot
        Repository root (charts/policies/tests/violations.yaml, loadtest/,
        charts/monitoring/files/dashboards/). Default: the folder above this module.

    .PARAMETER LoadTest
        Run the k6 load test (about 10 minutes per environment) after the other checks.

    .PARAMETER PeakVus
        Virtual users at the plateau of the load test. Default: the value in loadtest/job.yaml (5).

    .PARAMETER CreateTestUser
        Create the test account's Secret if missing and register the account in
        an environment where it cannot log in yet.

    .PARAMETER SkipAlertTest
        Do not send the synthetic alert (the notification channel receives it otherwise).

    .PARAMETER ParallelSessions
        Sessions of the parallel-users step (default 8); 0 skips the step.

    .PARAMETER ParallelSeconds
        Duration of each parallel-users phase in seconds (default 45).

    .EXAMPLE
        Test-DoksStack
        Everything except the load test, both environments.

    .EXAMPLE
        Test-DoksStack -Environment staging -LoadTest
        Staging including the k6 run; watch the HPA lines while it runs.

    .EXAMPLE
        Test-DoksStack | Where-Object Status -ne OK
        Only what needs attention.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [ValidateSet('staging', 'prod')][string[]]$Environment = @('staging', 'prod'),
        [string]$RepoRoot,
        [switch]$LoadTest,
        [ValidateRange(1, 200)][int]$PeakVus,
        [switch]$CreateTestUser,
        [switch]$SkipAlertTest,
        [ValidateRange(0, 64)][int]$ParallelSessions = 8,
        [ValidateRange(5, 600)][int]$ParallelSeconds = 45,
        [string]$TestUserNamespace = 'loadtest',
        [string]$TestUserSecret = 'k6-test-user'
    )
    if (-not $env:KUBECONFIG) { throw 'No KUBECONFIG in this window - run Use-DoksCluster <name> first.' }
    if (-not $RepoRoot) { $RepoRoot = Split-Path -Path $PSScriptRoot -Parent }
    $RepoRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepoRoot)
    $rows = New-Object System.Collections.Generic.List[object]
    $add = {
        param([string]$Step, [string]$Check, [string]$Status, [string]$Detail)
        $rows.Add([pscustomobject]@{ Step = $Step; Check = $Check; Status = $Status; Detail = $Detail })
        $color = switch ($Status) { 'OK' { 'Green' } 'FAIL' { 'Red' } default { 'Yellow' } }
        Write-Host ("  [{0,-4}] {1,-46} {2}" -f $Status, $Check, $Detail) -ForegroundColor $color
    }
    $header = { param([string]$Text) Write-Host $Text -ForegroundColor Cyan }
    $short = {
        param([string]$Text)
        $t = ($Text -replace '\s+', ' ').Trim()
        if ($t.Length -gt 160) { $t = $t.Substring(0, 160) + '...' }
        $t
    }

    # ---- 1. cluster ---------------------------------------------------------
    & $header 'Cluster'
    try {
        $nodes = @((Invoke-DoksKubectlProbe -Arguments @('get', 'nodes') -Json).items)
        $notReady = @($nodes | Where-Object { -not (@($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count) })
        $context = @(Invoke-DoksKubectlProbe -Arguments @('config', 'current-context')) -join ''
        if ($notReady.Count -eq 0) { & $add 'cluster' 'nodes Ready' 'OK' "$($nodes.Count) node(s), context $context" }
        else { & $add 'cluster' 'nodes Ready' 'FAIL' "not Ready: $(@($notReady | ForEach-Object { $_.metadata.name }) -join ', ')" }
    }
    catch { & $add 'cluster' 'nodes Ready' 'FAIL' (& $short $_.Exception.Message) }

    # ---- 2. gitops ----------------------------------------------------------
    & $header 'GitOps (ArgoCD)'
    try {
        $apps = @((Invoke-DoksKubectlProbe -Arguments @('-n', 'argocd', 'get', 'applications') -Json).items)
        $bad = @($apps | Where-Object { $_.status.sync.status -ne 'Synced' -or $_.status.health.status -ne 'Healthy' })
        if ($apps.Count -eq 0) { & $add 'gitops' 'Applications Synced and Healthy' 'FAIL' 'no Application in namespace argocd - Bootstrap-DoksCluster first' }
        elseif ($bad.Count -eq 0) { & $add 'gitops' 'Applications Synced and Healthy' 'OK' "$($apps.Count) applications" }
        else { & $add 'gitops' 'Applications Synced and Healthy' 'FAIL' (@($bad | ForEach-Object { "$($_.metadata.name): $($_.status.sync.status)/$($_.status.health.status)" }) -join ', ') }
    }
    catch { & $add 'gitops' 'Applications Synced and Healthy' 'FAIL' (& $short $_.Exception.Message) }

    # ---- 3.-5. per environment: workloads, tls, front door --------------------
    $hosts = @{}
    foreach ($envName in $Environment) {
        $ns = "auth-$envName"
        & $header "Environment $envName ($ns)"
        try {
            $deployments = @((Invoke-DoksKubectlProbe -Arguments @('-n', $ns, 'get', 'deployments') -Json).items)
            $unavailable = @($deployments | Where-Object { [int]$_.status.availableReplicas -lt [int]$_.spec.replicas })
            if ($deployments.Count -eq 0) { & $add $envName 'Deployments available' 'FAIL' "no Deployment in $ns" }
            elseif ($unavailable.Count -eq 0) { & $add $envName 'Deployments available' 'OK' (@($deployments | ForEach-Object { "$($_.metadata.name) $($_.status.availableReplicas)/$($_.spec.replicas)" }) -join ', ') }
            else { & $add $envName 'Deployments available' 'FAIL' (@($unavailable | ForEach-Object { "$($_.metadata.name) $([int]$_.status.availableReplicas)/$($_.spec.replicas)" }) -join ', ') }
        }
        catch { & $add $envName 'Deployments available' 'FAIL' (& $short $_.Exception.Message) }
        try {
            $jobs = @((Invoke-DoksKubectlProbe -Arguments @('-n', $ns, 'get', 'jobs') -Json).items | Where-Object { $_.metadata.name -match 'seed' })
            if ($jobs.Count -eq 0) { & $add $envName 'seed Jobs succeeded' 'SKIP' 'no seed Job present (hook already cleaned up)' }
            else {
                $failed = @($jobs | Where-Object { [int]$_.status.succeeded -lt 1 })
                if ($failed.Count -eq 0) { & $add $envName 'seed Jobs succeeded' 'OK' (@($jobs | ForEach-Object { $_.metadata.name }) -join ', ') }
                else { & $add $envName 'seed Jobs succeeded' 'FAIL' (@($failed | ForEach-Object { "$($_.metadata.name): succeeded=$([int]$_.status.succeeded) failed=$([int]$_.status.failed)" }) -join ', ') }
            }
        }
        catch { & $add $envName 'seed Jobs succeeded' 'FAIL' (& $short $_.Exception.Message) }
        try {
            $hpas = @((Invoke-DoksKubectlProbe -Arguments @('-n', $ns, 'get', 'hpa') -Json).items)
            if ($hpas.Count -eq 0) { & $add $envName 'HPA reads its metric' 'SKIP' 'no HorizontalPodAutoscaler' }
            else {
                $blind = @($hpas | Where-Object { -not @($_.status.currentMetrics | Where-Object { $null -ne $_.resource.current.averageUtilization }).Count })
                $text = @($hpas | ForEach-Object {
                    $u = @($_.status.currentMetrics | ForEach-Object { $_.resource.current.averageUtilization } | Where-Object { $null -ne $_ })
                    "$($_.metadata.name): cpu $(if ($u.Count) { "$($u[0])%" } else { '<unknown>' })/$($_.spec.metrics[0].resource.target.averageUtilization)%, $($_.status.currentReplicas) of $($_.spec.minReplicas)-$($_.spec.maxReplicas) replicas"
                }) -join '; '
                if ($blind.Count -eq 0) { & $add $envName 'HPA reads its metric' 'OK' $text } else { & $add $envName 'HPA reads its metric' 'FAIL' $text }
            }
        }
        catch { & $add $envName 'HPA reads its metric' 'FAIL' (& $short $_.Exception.Message) }
        try {
            $certificates = @((Invoke-DoksKubectlProbe -Arguments @('-n', $ns, 'get', 'certificates') -Json).items)
            $notReady = @($certificates | Where-Object { -not @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count })
            if ($certificates.Count -eq 0) { & $add $envName 'TLS certificate Ready' 'FAIL' 'no Certificate - are the Ingress hosts set (Sync-DoksHostname, committed)?' }
            elseif ($notReady.Count -eq 0) { & $add $envName 'TLS certificate Ready' 'OK' (@($certificates | ForEach-Object { "$($_.metadata.name) for $($_.spec.dnsNames -join ', ')" }) -join '; ') }
            else { & $add $envName 'TLS certificate Ready' 'FAIL' (@($notReady | ForEach-Object { "$($_.metadata.name): $(@($_.status.conditions | Where-Object { $_.type -eq 'Ready' } | ForEach-Object { $_.message }) -join ' ')" }) -join '; ') }
        }
        catch { & $add $envName 'TLS certificate Ready' 'FAIL' (& $short $_.Exception.Message) }
        try {
            $hostName = Get-DoksEnvironmentHost -Namespace $ns
            $hosts[$envName] = $hostName
            $attempt = 0
            do {
                $attempt++
                $root = Invoke-DoksHttp -Url "https://$hostName/"
                $me = Invoke-DoksHttp -Url "https://$hostName/api/me"
                $users = Invoke-DoksHttp -Url "https://$hostName/users"
                if ((@($root.Code, $me.Code, $users.Code) -contains 0) -and $attempt -lt 3) { Start-Sleep -Seconds 3 } else { break }
            } while ($true)
            $detail = "https://$hostName : / $($root.Code), /api/me $($me.Code), /users $($users.Code)"
            if ((@(200, 302) -contains $root.Code) -and $me.Code -eq 401 -and $users.Code -eq 403) { & $add $envName 'front door (LB, Traefik, frontend, backend)' 'OK' $detail }
            else { & $add $envName 'front door (LB, Traefik, frontend, backend)' 'FAIL' "$detail (expected 302 or 200, 401, 403)" }
        }
        catch { & $add $envName 'front door (LB, Traefik, frontend, backend)' 'FAIL' (& $short $_.Exception.Message) }
    }

    # ---- 6. policies ----------------------------------------------------------
    & $header 'Policies (Kyverno)'
    try {
        $policies = @((Invoke-DoksKubectlProbe -Arguments @('get', 'clusterpolicies') -Json).items)
        $notReady = @($policies | Where-Object { -not ("$($_.status.ready)" -eq 'True' -or @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0) })
        if ($policies.Count -eq 0) { & $add 'policies' 'ClusterPolicies ready' 'FAIL' 'no ClusterPolicy (infra-policies not synced?)' }
        elseif ($notReady.Count -eq 0) { & $add 'policies' 'ClusterPolicies ready' 'OK' (@($policies | ForEach-Object { $_.metadata.name }) -join ', ') }
        else { & $add 'policies' 'ClusterPolicies ready' 'FAIL' "not ready: $(@($notReady | ForEach-Object { $_.metadata.name }) -join ', ')" }
    }
    catch { & $add 'policies' 'ClusterPolicies ready' 'FAIL' (& $short $_.Exception.Message) }
    $fixture = Join-Path -Path $RepoRoot -ChildPath 'charts/policies/tests/violations.yaml'
    if (-not (Test-Path -LiteralPath $fixture -PathType Leaf)) { & $add 'policies' 'violations.yaml denied' 'SKIP' "$fixture not found - pass -RepoRoot" }
    else {
        try {
            $expected = @([regex]::Matches([System.IO.File]::ReadAllText($fixture), '(?m)^kind: Deployment\s*$')).Count
            $denied = 0; $message = ''
            try {
                Invoke-DoksKubectlProbe -Arguments @('apply', '-f', $fixture) | Out-Null
                $message = 'kubectl apply succeeded'
            }
            catch {
                $message = $_.Exception.Message
                $denied = @([regex]::Matches($message, 'denied the request')).Count
            }
            $created = @(Invoke-DoksKubectlProbe -Arguments @('get', 'deployments', '-A', '-l', 'app.kubernetes.io/instance=violations', '-o', 'jsonpath={range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}') | Where-Object { $_.Trim() })
            foreach ($item in $created) {
                $parts = $item.Trim() -split '/'
                try { Invoke-DoksKubectlProbe -Arguments @('-n', $parts[0], 'delete', 'deployment', $parts[1], '--ignore-not-found') | Out-Null } catch { }
            }
            if ($denied -eq $expected -and $created.Count -eq 0) { & $add 'policies' 'violations.yaml denied' 'OK' "$denied of $expected Deployments denied by the admission webhook, nothing created" }
            else { & $add 'policies' 'violations.yaml denied' 'FAIL' "$denied of $expected denied, $($created.Count) created (removed again): $(& $short $message)" }
        }
        catch { & $add 'policies' 'violations.yaml denied' 'FAIL' (& $short $_.Exception.Message) }
    }
    foreach ($envName in $Environment) {
        $ns = "auth-$envName"
        try {
            $reports = @((Invoke-DoksKubectlProbe -Arguments @('-n', $ns, 'get', 'policyreports') -Json).items)
            $fails = 0; foreach ($r in $reports) { $fails += [int]$r.summary.fail }
            if ($reports.Count -eq 0) { & $add 'policies' "policy reports $ns" 'SKIP' 'no PolicyReport yet (background scan pending)' }
            elseif ($fails -eq 0) { & $add 'policies' "policy reports $ns" 'OK' "$($reports.Count) reports, 0 failed" }
            else { & $add 'policies' "policy reports $ns" 'FAIL' "$fails failed result(s): kubectl -n $ns get policyreport -o yaml | grep -B3 -A6 'result: fail'" }
        }
        catch { & $add 'policies' "policy reports $ns" 'FAIL' (& $short $_.Exception.Message) }
    }

    # ---- 7. monitoring --------------------------------------------------------
    & $header 'Monitoring'
    foreach ($envName in $Environment) {
        $ns = "auth-$envName"
        try {
            $jobs = @(Invoke-DoksPrometheusQuery -Query "count by (job) (up{namespace=`"$ns`"})")
            $down = @(Invoke-DoksPrometheusQuery -Query "count by (job) (up{namespace=`"$ns`"} == 0)")
            $names = @($jobs | ForEach-Object { "$($_.metric.job) x$($_.value[1])" })
            if ($jobs.Count -lt 3) { & $add 'monitoring' "Prometheus scrapes $ns" 'FAIL' "targets: $($names -join ', ') (expected backend, frontend, modules)" }
            elseif ($down.Count -eq 0) { & $add 'monitoring' "Prometheus scrapes $ns" 'OK' ($names -join ', ') }
            else { & $add 'monitoring' "Prometheus scrapes $ns" 'FAIL' "down: $(@($down | ForEach-Object { $_.metric.job }) -join ', ')" }
        }
        catch { & $add 'monitoring' "Prometheus scrapes $ns" 'FAIL' (& $short $_.Exception.Message) }
        try {
            $rules = @(Invoke-DoksKubectlProbe -Arguments @('-n', $ns, 'get', 'prometheusrules', '-o', 'name') | Where-Object { $_.Trim() })
            if ($rules.Count -gt 0) { & $add 'monitoring' "PrometheusRules $ns" 'OK' ($rules -join ', ') } else { & $add 'monitoring' "PrometheusRules $ns" 'FAIL' 'none' }
        }
        catch { & $add 'monitoring' "PrometheusRules $ns" 'FAIL' (& $short $_.Exception.Message) }
    }
    try {
        $platformJobs = 'traefik|cert-manager|cainjector|webhook|argocd-.*-metrics|kyverno-.*|kube-state-metrics|node-exporter|kubelet|apiserver'
        $present = @(Invoke-DoksPrometheusQuery -Query "count by (job) (up{job=~`"$platformJobs`"})")
        $down = @(Invoke-DoksPrometheusQuery -Query "count by (job) (up{job=~`"$platformJobs`"} == 0)")
        $required = @('traefik', 'cert-manager', 'argocd-application-controller-metrics', 'kube-state-metrics', 'node-exporter', 'kubelet')
        $missing = @($required | Where-Object { $name = $_; -not @($present | Where-Object { $_.metric.job -eq $name }).Count })
        if ($missing.Count -eq 0 -and $down.Count -eq 0) { & $add 'monitoring' 'Prometheus scrapes the platform' 'OK' (@($present | ForEach-Object { $_.metric.job }) -join ', ') }
        else { & $add 'monitoring' 'Prometheus scrapes the platform' 'FAIL' "missing: $($missing -join ', '); down: $(@($down | ForEach-Object { $_.metric.job }) -join ', ')" }
    }
    catch { & $add 'monitoring' 'Prometheus scrapes the platform' 'FAIL' (& $short $_.Exception.Message) }

    $forward = $null
    try {
        $user = Get-DoksSecretValue -Namespace monitoring -Name grafana-admin -Key admin-user
        $password = Get-DoksSecretValue -Namespace monitoring -Name grafana-admin -Key admin-password
        if (-not $user) { $user = 'admin' }
        if (-not $password) { throw 'Secret monitoring/grafana-admin not found' }
        $forward = Start-DoksProbeForward -Namespace monitoring -Target 'svc/monitoring-grafana' -RemotePort 80
        $auth = "${user}:$password"
        $health = Invoke-DoksHttp -Url "$($forward.Url)/api/health"
        $sources = @(ConvertFrom-DoksJsonBody -Text (Invoke-DoksHttp -Url "$($forward.Url)/api/datasources" -BasicAuth $auth).Body)
        $prometheusSource = @($sources | Where-Object { $_.type -eq 'prometheus' })
        if ($health.Code -ne 200) { throw "Grafana /api/health answered $($health.Code)" }
        if ($prometheusSource.Count -eq 0) { throw 'Grafana has no Prometheus datasource' }
        $queryBody = '{"queries":[{"refId":"A","datasource":{"type":"prometheus","uid":"' + $prometheusSource[0].uid + '"},"expr":"count(up)","instant":true,"intervalMs":30000,"maxDataPoints":100}],"from":"now-5m","to":"now"}'
        $answer = Invoke-DoksHttp -Url "$($forward.Url)/api/ds/query" -Method POST -Body $queryBody -BasicAuth $auth
        $result = ConvertFrom-DoksJsonBody -Text $answer.Body
        $frames = 0; $value = $null
        if ($result -and $result.results -and $result.results.A) {
            $frames = @($result.results.A.frames).Count
            if ($frames -gt 0) { $value = $result.results.A.frames[0].data.values[1][0] }
        }
        if ($answer.Code -eq 200 -and $frames -gt 0 -and $value) { & $add 'monitoring' 'Grafana queries Prometheus' 'OK' "datasource $($prometheusSource[0].name) (uid $($prometheusSource[0].uid)): count(up) = $value" }
        else { & $add 'monitoring' 'Grafana queries Prometheus' 'FAIL' "HTTP $($answer.Code), $frames frame(s): $(& $short $answer.Body)" }

        $dashboardDir = Join-Path -Path $RepoRoot -ChildPath 'charts/monitoring/files/dashboards'
        $expectedUids = @()
        if (Test-Path -LiteralPath $dashboardDir -PathType Container) {
            foreach ($file in Get-ChildItem -Path $dashboardDir -Filter '*.json' -Recurse) {
                try { $uid = (ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($file.FullName))).uid; if ($uid) { $expectedUids += $uid } } catch { }
            }
        }
        $found = @(ConvertFrom-DoksJsonBody -Text (Invoke-DoksHttp -Url "$($forward.Url)/api/search?type=dash-db&limit=500" -BasicAuth $auth).Body)
        $foundUids = @($found | ForEach-Object { $_.uid })
        $missing = @($expectedUids | Where-Object { $foundUids -notcontains $_ })
        if ($expectedUids.Count -eq 0) { & $add 'monitoring' 'Grafana dashboards provisioned' 'SKIP' "$dashboardDir not found - pass -RepoRoot; Grafana lists $($found.Count) dashboards" }
        elseif ($missing.Count -eq 0) { & $add 'monitoring' 'Grafana dashboards provisioned' 'OK' "all $($expectedUids.Count) dashboards of the repository among $($found.Count) in Grafana" }
        else { & $add 'monitoring' 'Grafana dashboards provisioned' 'FAIL' "missing uid(s): $($missing -join ', ')" }
    }
    catch { & $add 'monitoring' 'Grafana queries Prometheus' 'FAIL' (& $short $_.Exception.Message) }
    finally { Stop-DoksProbeForward -Forward $forward; $forward = $null }

    try {
        $forward = Start-DoksProbeForward -Namespace monitoring -Target 'svc/monitoring-kube-prometheus-alertmanager' -RemotePort 9093
        $status = Invoke-DoksHttp -Url "$($forward.Url)/api/v2/status"
        if ($status.Code -ne 200) { throw "Alertmanager /api/v2/status answered $($status.Code)" }
        if ($SkipAlertTest) { & $add 'monitoring' 'Alertmanager alert path' 'SKIP' 'reachable; synthetic alert not sent (-SkipAlertTest)' }
        else {
            $probe = "Test-DoksStack-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"
            $alert = '[{"labels":{"alertname":"UserMgmtServiceHighErrorRate","service":"user-mgmt-service","severity":"critical","namespace":"auth-staging","probe":"' + $probe + '"},"annotations":{"summary":"notification channel test (Test-DoksStack)"}}]'
            $posted = Invoke-DoksHttp -Url "$($forward.Url)/api/v2/alerts" -Method POST -Body $alert
            if ($posted.Code -ne 200) { throw "POST /api/v2/alerts answered $($posted.Code): $(& $short $posted.Body)" }
            Start-Sleep -Seconds 2
            $listed = @(ConvertFrom-DoksJsonBody -Text (Invoke-DoksHttp -Url ("$($forward.Url)/api/v2/alerts?filter=" + [Uri]::EscapeDataString("probe=`"$probe`""))).Body)
            $receivers = @($listed | ForEach-Object { $_.receivers } | ForEach-Object { $_.name } | Sort-Object -Unique)
            if ($listed.Count -gt 0 -and $receivers -contains 'webhook') { & $add 'monitoring' 'Alertmanager alert path' 'OK' 'synthetic UserMgmtServiceHighErrorRate accepted and routed to receiver webhook; the delivery is in the channel inbox (Bootstrap-DoksCluster printed its URL), it resolves itself after 5 minutes' }
            else { & $add 'monitoring' 'Alertmanager alert path' 'FAIL' "alert accepted but listed with receivers: $($receivers -join ', ')" }
        }
    }
    catch { & $add 'monitoring' 'Alertmanager alert path' 'FAIL' (& $short $_.Exception.Message) }
    finally { Stop-DoksProbeForward -Forward $forward; $forward = $null }

    # ---- 8. end to end (module assignment) ----------------------------------
    & $header 'End to end (module assignment through the module service)'
    $accountReady = @{}
    $email = $null; $testPassword = $null
    $hint = "no test account (Secret $TestUserNamespace/$TestUserSecret): Start-DoksLoadTest creates and registers it, or run with -CreateTestUser - after registering your own admin (the first user becomes ADMIN)"
    try {
        if (Test-DoksKubectlResource -Kind secret -Name $TestUserSecret -Namespace $TestUserNamespace) {
            $email = Get-DoksSecretValue -Namespace $TestUserNamespace -Name $TestUserSecret -Key email
            $testPassword = Get-DoksSecretValue -Namespace $TestUserNamespace -Name $TestUserSecret -Key password
        }
        elseif ($CreateTestUser) {
            $email = Initialize-DoksTestUserSecret -Namespace $TestUserNamespace -SecretName $TestUserSecret
            $testPassword = Get-DoksSecretValue -Namespace $TestUserNamespace -Name $TestUserSecret -Key password
        }
    }
    catch { & $add 'end-to-end' 'test account Secret' 'FAIL' (& $short $_.Exception.Message) }
    foreach ($envName in $Environment) {
        $hostName = $hosts[$envName]
        $accountReady[$envName] = $false
        if (-not $hostName) { & $add $envName 'module assignment end to end' 'SKIP' 'no host (front door check failed)'; continue }
        if (-not $email -or -not $testPassword) { & $add $envName 'module assignment end to end' 'SKIP' $hint; continue }
        try {
            $sequence = [System.Diagnostics.Stopwatch]::StartNew()
            $credentials = '{"email":"' + $email + '","password":"' + ($testPassword -replace '"', '\"') + '"}'
            $login = Invoke-DoksHttp -Url "https://$hostName/users/login" -Method POST -Body $credentials
            if ($login.Code -ne 200) {
                if (-not $CreateTestUser) {
                    & $add $envName 'module assignment end to end' 'SKIP' "login as $email answers $($login.Code): not registered in $envName yet - Start-DoksLoadTest registers it, or -CreateTestUser (the first user registered becomes ADMIN)"
                    continue
                }
                $signup = Invoke-DoksHttp -Url "https://$hostName/api/signup" -Method POST -Body ('{"firstName":"doks","lastName":"test","email":"' + $email + '","password":"' + ($testPassword -replace '"', '\"') + '"}')
                $login = Invoke-DoksHttp -Url "https://$hostName/users/login" -Method POST -Body $credentials
                if ($login.Code -ne 200) { throw "signup answered $($signup.Code), login still answers $($login.Code)" }
                Write-Host "  registered $email in $envName (signup HTTP $($signup.Code))" -ForegroundColor DarkGray
            }
            $token = $login.Headers['authorization']
            if ($token -match '^Bearer\s+(\S+)') { $token = $Matches[1] } else { throw 'login answered 200 without an Authorization: Bearer header' }
            $bearer = @{ Authorization = "Bearer $token" }
            $modules = Invoke-DoksHttp -Url "https://$hostName/modules" -Headers $bearer
            $moduleList = @(ConvertFrom-DoksJsonBody -Text $modules.Body)
            if ($modules.Code -ne 200 -or $moduleList.Count -eq 0) { throw "GET /modules answered $(if ($modules.Code) { "HTTP $($modules.Code)" } else { 'nothing within 30 s' }) with $($moduleList.Count) module(s) after $([int]$sequence.Elapsed.TotalSeconds) s (module service, MySQL)" }
            $meResponse = Invoke-DoksHttp -Url "https://$hostName/users/me" -Headers $bearer
            $me = ConvertFrom-DoksJsonBody -Text $meResponse.Body
            if (-not $me.id) { throw "GET /users/me answered $(if ($meResponse.Code) { "HTTP $($meResponse.Code)" } else { 'nothing within 30 s' }) without an id after $([int]$sequence.Elapsed.TotalSeconds) s: $(& $short $meResponse.Body)" }
            $roles = @(@($me.roles) + @($me.role) | Where-Object { $_ } | ForEach-Object { "$_" })
            $moduleId = $moduleList[0].id
            $assigned = Invoke-DoksHttp -Url "https://$hostName/users/$($me.id)/modules/$moduleId" -Method POST -Headers $bearer
            $unknown = Invoke-DoksHttp -Url "https://$hostName/users/$($me.id)/modules/00000000-0000-0000-0000-000000000000" -Method POST -Headers $bearer
            $after = ConvertFrom-DoksJsonBody -Text (Invoke-DoksHttp -Url "https://$hostName/users/me" -Headers $bearer).Body
            $listed = @($after.moduleIds) -contains $moduleId
            $removed = Invoke-DoksHttp -Url "https://$hostName/users/$($me.id)/modules/$moduleId" -Method DELETE -Headers $bearer
            $detail = "$($moduleList.Count) modules via the module service; assign $($moduleList[0].code): $($assigned.Code), unknown module: $($unknown.Code), read back: $(if ($listed) { 'listed' } else { 'missing' }), unassign: $($removed.Code); account roles: $(if ($roles.Count) { $roles -join '/' } else { '-' }); $([int]$sequence.Elapsed.TotalSeconds) s for the sequence"
            if ($assigned.Code -eq 200 -and $unknown.Code -eq 404 -and $listed -and $removed.Code -eq 200) { & $add $envName 'module assignment end to end' 'OK' $detail; $accountReady[$envName] = $true }
            else { & $add $envName 'module assignment end to end' 'FAIL' "$detail (expected 200, 404, listed, 200)" }
        }
        catch { & $add $envName 'module assignment end to end' 'FAIL' (& $short $_.Exception.Message) }
    }

    # ---- 9. parallel users ----------------------------------------------------
    if ($ParallelSessions -gt 0) {
        & $header "Parallel users ($ParallelSessions sessions, $ParallelSeconds s per phase)"
        $limits = @{ 'login' = 2.0; 'login (frontend)' = 2.0; 'profile' = 1.0; 'profile (frontend)' = 1.0; 'modules' = 2.0; 'assign' = 2.0; 'unassign' = 2.0; 'logout (frontend)' = 1.0; 'wrong password' = 2.0; 'signup' = 5.0 }
        foreach ($envName in $Environment) {
            $hostName = $hosts[$envName]
            if (-not $hostName -or -not $email -or -not $testPassword -or -not ($accountReady[$envName] -or $CreateTestUser)) { & $add $envName 'parallel users' 'SKIP' 'needs a working test account (see the end-to-end row)'; continue }
            foreach ($mode in 'distinct', 'shared') {
                try {
                    Write-Host "  $mode accounts ..." -ForegroundColor DarkGray
                    $stats = @(Invoke-DoksUserStorm -HostName $hostName -Email $email -Password $testPassword -Mode $mode -Sessions $ParallelSessions -Seconds $ParallelSeconds)
                    if ($stats.Count -eq 0) { throw 'no sample collected (the sessions produced no result)' }
                    foreach ($row in $stats) { Write-Host ("    {0,-20} {1,5} calls {2,4} errors  avg {3,6:N2}s  p95 {4,6:N2}s  max {5,6:N2}s  {6}" -f $row.Type, $row.Calls, $row.Errors, $row.Avg, $row.P95, $row.Max, $row.Codes) -ForegroundColor DarkGray }
                    $slow = @($stats | Where-Object { $limits.ContainsKey($_.Type) -and $_.P95 -gt $limits[$_.Type] } | ForEach-Object { "$($_.Type) p95 $($_.P95) s" })
                    $calls = 0; $errors = 0; foreach ($row in $stats) { $calls += $row.Calls; $errors += $row.Errors }
                    $rate = if ($calls) { 100.0 * $errors / $calls } else { 100.0 }
                    $detail = "$mode accounts: $calls calls, $errors errors ($([Math]::Round($rate, 1)) %)" + $(if ($slow.Count) { "; over the threshold: $($slow -join ', ')" } else { '; every p95 within the thresholds' })
                    if ($slow.Count -eq 0 -and $rate -le 5) { & $add $envName "parallel users ($mode accounts)" 'OK' $detail } else { & $add $envName "parallel users ($mode accounts)" 'FAIL' $detail }
                }
                catch { & $add $envName "parallel users ($mode accounts)" 'FAIL' (& $short $_.Exception.Message) }
            }
        }
    }

    # ---- 10. load test --------------------------------------------------------
    if ($LoadTest) {
        & $header 'Load test (k6, loadtest/)'
        foreach ($envName in $Environment) {
            if (-not $accountReady[$envName] -and -not $CreateTestUser) { & $add $envName 'k6 load test' 'SKIP' "no registered test account in $envName (see the end-to-end row); Start-DoksLoadTest -Environment $envName registers it (the first user becomes ADMIN)"; continue }
            try {
                $loadParameters = @{ Environment = $envName; RepoRoot = $RepoRoot; Confirm = $false }
                if ($PeakVus -gt 0) { $loadParameters.PeakVus = $PeakVus }
                $run = Start-DoksLoadTest @loadParameters
                $replicas = if ($null -ne $run.MaxReplicas) { "backend replicas $($run.MinReplicas) to $($run.MaxReplicas)" } else { 'HPA not read' }
                switch ($run.Result) {
                    'Complete' { & $add $envName 'k6 load test' 'OK' "thresholds held after $($run.Minutes) min at $($run.PeakVus) VUs; $replicas; testid=$($run.TestId)" }
                    'Failed' { & $add $envName 'k6 load test' 'FAIL' "a threshold was breached at $($run.PeakVus) VUs - that is the result (k6 load test dashboard, testid=$($run.TestId)); $replicas" }
                    default { & $add $envName 'k6 load test' 'FAIL' "the Job did not finish: kubectl -n $TestUserNamespace describe job k6-user-mgmt-service" }
                }
            }
            catch { & $add $envName 'k6 load test' 'FAIL' (& $short $_.Exception.Message) }
        }
    }

    $ok = @($rows | Where-Object { $_.Status -eq 'OK' }).Count
    $fail = @($rows | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skip = @($rows | Where-Object { $_.Status -eq 'SKIP' }).Count
    Write-Host ("{0} checks: {1} OK, {2} FAIL, {3} SKIP" -f $rows.Count, $ok, $fail, $skip) -ForegroundColor $(if ($fail) { 'Red' } else { 'Green' })
    $rows
}

# ---------------------------------------------------------------------------
# Load configuration layers 2-4 (project file, user file, environment)
# ---------------------------------------------------------------------------

Import-DoksDefaultsFile -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Doks.defaults.psd1') -Label 'project'
Import-DoksDefaultsFile -Path (Join-Path -Path $script:UserDir -ChildPath 'defaults.psd1') -Label 'user'
Import-DoksDefaultsFromEnv

Export-ModuleMember -Function @(
    'New-DoksCluster', 'Remove-DoksCluster', 'Get-DoksCluster', 'Use-DoksCluster', 'Disconnect-DoksCluster',
    'Wait-DoksNodeReady', 'Get-DoksOption', 'Initialize-DoksCluster',
    'Set-DoksToken', 'Remove-DoksToken', 'Connect-DoksAccount', 'Disconnect-DoksAccount', 'Get-DoksAccount',
    'Get-DoksDefault', 'Set-DoksDefault', 'Test-DoksSetup', 'Test-DoksStack', 'Start-DoksLoadTest',
    'Sync-DoksTerraform', 'Sync-DoksHostname', 'Connect-DoksPortForward', 'Disconnect-DoksPortForward'
) -Alias @('Bootstrap-DoksCluster')
