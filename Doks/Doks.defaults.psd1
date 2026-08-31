@{
    Region        = 'fra1'
    # Two nodes so anti-affinity, PDBs and rolling updates have somewhere to go;
    # 4 GB because prod + staging quotas plus the platform do not fit in 2 GB.
    Size          = 's-2vcpu-4gb'
    Count         = 2
    MinNodes      = 2
    MaxNodes      = 10
    Version       = 'latest'
    Tag           = 'doks-VSC-deploy'
    KubeconfigDir = '..\kubeconfig'
}
