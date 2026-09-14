# The API token never enters the repository: either export DIGITALOCEAN_TOKEN
# (the provider reads it itself) or pass -var do_token=... / TF_VAR_do_token
# for one invocation. A tfvars file holding it must stay git-ignored.
provider "digitalocean" {
  token = var.do_token
}
