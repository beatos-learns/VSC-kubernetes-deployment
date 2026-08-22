#Requires -Version 5.1
<#
.SYNOPSIS
    Doks - DigitalOcean Kubernetes (DOKS) clusters from PowerShell.

.DESCRIPTION

    ONE-TIME SETUP
        Import-Module E:\temp\digitalOcean\Doks.psm1
        Set-DoksToken                      # paste the API token once -> Credential Manager
        Test-DoksSetup                     # doctl/kubectl/token/API all green?

    DAILY USE
        New-DoksCluster                    # create (fra1, 1x s-2vcpu-2gb, autoscale 1-5), wait, connect
        kubectl get nodes                  # this window now talks to the new cluster
        Get-DoksCluster                    # what is running (= what is billing) right now
        Use-DoksCluster k8s-test-fra1      # point this window at an existing cluster
        Bootstrap-DoksCluster              # GitOps handover: namespaces+secrets, ArgoCD, root app (Get-Help Bootstrap-DoksCluster)
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
    Count            = 1
    MinNodes         = 1
    MaxNodes         = 5
    Version          = 'latest'
    Tag              = 'doks-temp'
    KubeconfigDir    = (Join-Path -Path $PSScriptRoot -ChildPath 'kubeconfig')
    CredentialTarget = 'Doks/DigitalOcean-API-Token'
}
$script:DefaultSources = New-Object System.Collections.Generic.List[string]

$script:AuthVerified  = $false
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
    [System.IO.File]::WriteAllText($file, $Token + "`n", [System.Text.UTF8Encoding]::new($false))
    if (Get-Command -Name chmod -CommandType Application -ErrorAction SilentlyContinue) { & chmod 600 $file }
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
    param([Parameter(Mandatory)][ValidateSet('doctl', 'kubectl', 'helm')][string]$Name)
    if ($script:ToolPaths[$Name]) { return $script:ToolPaths[$Name] }
    $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $cmd) {
        $hint = switch ($Name) {
            'doctl'   { 'https://docs.digitalocean.com/reference/doctl/how-to/install/' }
            'kubectl' { 'https://kubernetes.io/docs/tasks/tools/' }
            'helm'    { 'https://helm.sh/docs/intro/install/' }
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
    Invoke-DoksNative -Tool doctl -Arguments $Arguments -Json:$Json -Stream:$Stream
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
        $account = Invoke-DoksWithToken -Token $plain -ScriptBlock { Get-DoksAccountInfo }
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
    if ($Token) {
        $env:DIGITALOCEAN_ACCESS_TOKEN = ConvertFrom-DoksSecureString -SecureString $Token
        $source = 'the -Token parameter (this session only)'
        $setByUs = $true
    }
    elseif ($env:DIGITALOCEAN_ACCESS_TOKEN -and -not $Force) {
        $source = '$env:DIGITALOCEAN_ACCESS_TOKEN'
    }
    else {
        $stored = Read-DoksStoredToken
        if ($stored) {
            $env:DIGITALOCEAN_ACCESS_TOKEN = $stored.Token
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
        if ($setByUs) { Remove-Item -Path Env:DIGITALOCEAN_ACCESS_TOKEN -ErrorAction SilentlyContinue }
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

function Initialize-DoksCluster {
    <#
    .SYNOPSIS
        Bootstraps a DOKS cluster for GitOps: namespaces, secrets, ArgoCD, root application.

    .DESCRIPTION
        Automates the one-time imperative bootstrap documented in bootstrap/README.md.
        After it finishes, the cluster converges on git - ArgoCD pulls; nothing
        deploys via kubectl/helm anymore.

        Steps (in order):
          1. Connect   - point this window at the cluster (-ClusterName), verify access.
          2. Secrets   - per environment namespace: create the namespace, an
                         'auth-stack-secrets' Secret (random db-password + jwt-secret),
                         and optionally a GHCR image pull Secret (-GhcrUsername/-GhcrToken).
          3. ArgoCD    - 'helm upgrade --install' from bootstrap/argocd-values.yaml
                         into the 'argocd' namespace.
          4. Root app  - 'kubectl apply' bootstrap/root-application.yaml; ArgoCD
                         takes over from here (app-of-apps).
          5. Handover  - print how to watch convergence, open the dashboard, and
                         find the load balancer IP for DNS.

        The command is idempotent and safe to re-run: existing Secrets are NEVER
        touched (regenerating db-password would orphan the PostgreSQL PVC, which
        initializes its password on first start), ArgoCD upgrades in place, and
        the root application is applied declaratively.

    .PARAMETER ClusterName
        Cluster to bootstrap. Connects this window to it first (Use-DoksCluster).
        Omit to use whatever cluster this window already points at ($env:KUBECONFIG).

    .PARAMETER Namespace
        Environment namespaces to create and equip with secrets.
        Default: auth-staging, auth-prod (the namespaces argocd/app-*.yaml deploys to).

    .PARAMETER SecretName
        Name of the per-namespace application Secret the chart references via
        'existingSecret'. Default: auth-stack-secrets.

    .PARAMETER GhcrUsername
        GitHub username for the GHCR image pull Secret. Omit if the GHCR packages
        are public (then also remove global.imagePullSecrets from the chart values).

    .PARAMETER GhcrToken
        Fine-grained PAT with read:packages only, as a SecureString.
        Prompted for interactively when -GhcrUsername is given without it.

    .PARAMETER PullSecretName
        Name of the docker-registry pull Secret. Default: ghcr-pull
        (referenced via global.imagePullSecrets in charts/auth-stack/values.yaml).

    .PARAMETER RepoRoot
        Repository root containing bootstrap/argocd-values.yaml and
        bootstrap/root-application.yaml. Default: the folder above this module.

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
        Requires doctl, kubectl, and helm on PATH (Test-DoksSetup checks all three).
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
        [string]$RepoRoot
    )

    if (-not $RepoRoot) { $RepoRoot = Split-Path -Path $PSScriptRoot -Parent }
    $RepoRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RepoRoot)
    $argocdValues = Join-Path -Path $RepoRoot -ChildPath 'bootstrap\argocd-values.yaml'
    $rootApp      = Join-Path -Path $RepoRoot -ChildPath 'bootstrap\root-application.yaml'
    foreach ($required in $argocdValues, $rootApp) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
            throw "Bootstrap file not found: $required. Pass -RepoRoot pointing at the ops repository."
        }
    }
    Get-DoksTool -Name helm | Out-Null

    if ($GhcrUsername -and -not $GhcrToken) {
        $GhcrToken = Read-Host -Prompt "GHCR PAT for $GhcrUsername, read:packages only (input is hidden)" -AsSecureString
    }

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
            Write-Host "  Secret $SecretName exists - left untouched (a new db-password would not match the initialized PostgreSQL PVC)."
        }
        else {
            Invoke-Kubectl -Arguments @(
                '--namespace', $ns, 'create', 'secret', 'generic', $SecretName,
                "--from-literal=db-password=$(New-DoksRandomSecret -Bytes 24)",
                "--from-literal=jwt-secret=$(New-DoksRandomSecret -Bytes 48)"
            ) | Out-Null
            Write-Host "  Secret $SecretName created (random db-password + jwt-secret)." -ForegroundColor Green
        }

        if ($GhcrUsername -and $GhcrToken) {
            if (Test-DoksKubectlResource -Kind secret -Name $PullSecretName -Namespace $ns) {
                Write-Host "  Pull secret $PullSecretName exists - left untouched."
            }
            else {
                Invoke-Kubectl -Arguments @(
                    '--namespace', $ns, 'create', 'secret', 'docker-registry', $PullSecretName,
                    '--docker-server=ghcr.io',
                    "--docker-username=$GhcrUsername",
                    "--docker-password=$(ConvertFrom-DoksSecureString -SecureString $GhcrToken)"
                ) | Out-Null
                Write-Host "  Pull secret $PullSecretName created." -ForegroundColor Green
            }
        }
    }
    if (-not ($GhcrUsername -and $GhcrToken)) {
        Write-Host 'No GHCR pull secret requested - assuming the GHCR packages are public.' -ForegroundColor DarkGray
    }

    # --- 3. ArgoCD (dedicated namespace) ----------------------------------
    Write-Host 'Installing/upgrading ArgoCD ...' -ForegroundColor Cyan
    Invoke-Helm -Arguments @('repo', 'add', 'argo', 'https://argoproj.github.io/argo-helm', '--force-update') | Out-Null
    Invoke-Helm -Arguments @('repo', 'update', 'argo') | Out-Null
    Invoke-Helm -Arguments @(
        'upgrade', '--install', 'argocd', 'argo/argo-cd',
        '--namespace', 'argocd', '--create-namespace',
        '--values', $argocdValues, '--wait'
    ) -Stream

    # --- 4. Root application (ArgoCD takes over from here) ----------------
    Invoke-Kubectl -Arguments @('apply', '-f', $rootApp) | Out-Null
    Write-Host 'Root application applied - ArgoCD now syncs argocd/ from git.' -ForegroundColor Green

    # --- 5. Handover ------------------------------------------------------
    Write-Host ''
    Write-Host 'Bootstrap done. From here the cluster converges on git.' -ForegroundColor Green
    Write-Host '  Watch convergence:   kubectl -n argocd get applications -w'
    Write-Host '  Dashboard password:  kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | %{ [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }'
    Write-Host '  Dashboard:           kubectl -n argocd port-forward svc/argocd-server 8080:80   ->  http://localhost:8080 (user: admin)'
    Write-Host '  Load balancer IP:    kubectl -n traefik get svc traefik -o jsonpath="{.status.loadBalancer.ingress[0].ip}"  (point DNS / nip.io hosts at it)'
}

function Test-DoksSetup {
    [CmdletBinding()]
    param()
    $rows = New-Object System.Collections.Generic.List[object]
    $add = {
        param($Check, $Ok, $Detail)
        $rows.Add([pscustomobject]@{ Check = $Check; Status = $(if ($Ok) { 'OK' } else { 'MISSING' }); Detail = $Detail })
    }

    foreach ($tool in 'doctl', 'kubectl', 'helm') {
        try {
            $path = Get-DoksTool -Name $tool
            $ver = ''
            try {
                if ($tool -eq 'doctl') { $ver = @(Invoke-Doctl -Arguments @('version'))[0] }
                elseif ($tool -eq 'helm') { $ver = "helm $(@(Invoke-Helm -Arguments @('version', '--short'))[0])" }
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
# Load configuration layers 2-4 (project file, user file, environment)
# ---------------------------------------------------------------------------

Import-DoksDefaultsFile -Path (Join-Path -Path $PSScriptRoot -ChildPath 'Doks.defaults.psd1') -Label 'project'
Import-DoksDefaultsFile -Path (Join-Path -Path $script:UserDir -ChildPath 'defaults.psd1') -Label 'user'
Import-DoksDefaultsFromEnv

Export-ModuleMember -Function @(
    'New-DoksCluster', 'Remove-DoksCluster', 'Get-DoksCluster', 'Use-DoksCluster', 'Disconnect-DoksCluster',
    'Wait-DoksNodeReady', 'Get-DoksOption', 'Initialize-DoksCluster',
    'Set-DoksToken', 'Remove-DoksToken', 'Connect-DoksAccount', 'Disconnect-DoksAccount', 'Get-DoksAccount',
    'Get-DoksDefault', 'Set-DoksDefault', 'Test-DoksSetup'
) -Alias @('Bootstrap-DoksCluster')
