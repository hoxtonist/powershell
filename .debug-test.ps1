param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ExtraArgs
)

$env:ARM_subscription_id = "<subscription_id>"

$env:TF_VAR_environment_name = "test"

$env:BACKEND_RESOURCE_GROUP_NAME = "rg-<rgname>-$($env:TF_VAR_environment_name)"
$env:BACKEND_STORAGE_ACCOUNT_NAME = "<saname>$($env:TF_VAR_environment_name)"
$env:BACKEND_CONTAINER_NAME = "tfstate"
$env:BACKEND_KEY = "devops.$($env:TF_VAR_environment_name).tfstate"

terraform init `
    -backend-config="resource_group_name=$($env:BACKEND_RESOURCE_GROUP_NAME)" `
    -backend-config="storage_account_name=$($env:BACKEND_STORAGE_ACCOUNT_NAME)" `
    -backend-config="container_name=$($env:BACKEND_CONTAINER_NAME)" `
    -backend-config="key=$($env:BACKEND_KEY)" `
    -reconfigure

terraform $ExtraArgs -var-file=".\env\$($env:TF_VAR_environment_name)\$($env:TF_VAR_environment_name).tfvars"

remove-item .\.terraform\terraform.tfstate
