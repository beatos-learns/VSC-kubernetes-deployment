@{
    RootModule           = 'Doks.psm1'
    ModuleVersion        = '0.0.1'
    GUID                 = '7f3d9b2e-6a1c-4c58-9e2b-0d3f5a8c1e47'
    Author               = 'Beatos Learns'
    Description          = 'Throwaway DigitalOcean Kubernetes (DOKS) clusters from PowerShell: create, connect this window only (KUBECONFIG), list, delete, and bootstrap the GitOps stack (namespaces+secrets, ArgoCD, root application). API token stored per user (Windows Credential Manager / ~/.doks/token). Requires doctl and kubectl on PATH; helm for Bootstrap-DoksCluster. Test-DoksStack verifies the running stack in order, Start-DoksLoadTest runs the k6 load test.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport    = @(
        'New-DoksCluster',
        'Remove-DoksCluster',
        'Get-DoksCluster',
        'Use-DoksCluster',
        'Disconnect-DoksCluster',
        'Wait-DoksNodeReady',
        'Get-DoksOption',
        'Initialize-DoksCluster',
        'Set-DoksToken',
        'Remove-DoksToken',
        'Connect-DoksAccount',
        'Disconnect-DoksAccount',
        'Get-DoksAccount',
        'Get-DoksDefault',
        'Set-DoksDefault',
        'Test-DoksSetup',
        'Test-DoksStack',
        'Start-DoksLoadTest',
        'Sync-DoksTerraform',
        'Sync-DoksHostname',
        'Connect-DoksPortForward',
        'Disconnect-DoksPortForward'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('Bootstrap-DoksCluster')

    FileList             = @('Doks.psd1', 'Doks.psm1', 'Doks.defaults.psd1', 'README.md')

    PrivateData          = @{
        PSData = @{
            Tags         = @('DigitalOcean', 'DOKS', 'Kubernetes', 'doctl', 'kubectl')
            ReleaseNotes = '0.0.1: initial Version'
        }
    }
}
