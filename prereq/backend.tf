terraform {
  backend "s3" {
    #   terraform init \
    #     -backend-config="bucket=$TF_STATE_BUCKET" \
    #     -backend-config="key=prereq/$ENV/terraform.tfstate" \
    #     -backend-config="region=$AWS_REGION"
    use_lockfile = true
    encrypt      = true
  }
}
