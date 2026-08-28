terraform {
  backend "s3" {
    # bucket / key / region come from -backend-config, because the bucket name is
    # decided by the bootstrap stack and the key is per environment:
    #
    #   terraform init \
    #     -backend-config="bucket=$TF_STATE_BUCKET" \
    #     -backend-config="key=env/$ENV/terraform.tfstate" \
    #     -backend-config="region=$AWS_REGION"
    #
    # One state per environment, so environments are created and destroyed
    # independently. The legacy stack used a single key from CodeBuild and a
    # different one from Actions, against the same bucket.
    use_lockfile = true
    encrypt      = true
  }
}
