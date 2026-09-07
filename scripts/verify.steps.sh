# The gates CI runs (.github/workflows/terraform-validate.yml), in order. `step "<name>" <command...>`
# stops at the first failure. Keep this identical to the workflow; the receipt is only as honest as the list.
step "terraform fmt"  terraform fmt -recursive -check

for dir in . prereq modules/*; do
  step "terraform init ($dir)"      terraform -chdir="$dir" init -backend=false -input=false
  step "terraform validate ($dir)"  terraform -chdir="$dir" validate
done

if command -v tflint >/dev/null 2>&1; then
  step "tflint --init"  tflint --init
  step "tflint"         tflint --recursive --minimum-failure-severity=warning
else
  echo; echo "▷ tflint is not installed — skipped here; CI's lint job still runs it (brew install tflint)."
fi

# The app repo sits beside the *primary* checkout; from a worktree under .claude/worktrees/ a plain
# ../cvhome points nowhere. APP_REPO overrides (the orchestrator sets it when reviewing a branch).
APP_REPO="${APP_REPO:-$(cd "$(git rev-parse --git-common-dir)/../.." && pwd)/cvhome}"
step "catalog drift against $APP_REPO"  python3 scripts/check-catalog-drift.py --app-repo "$APP_REPO"

if command -v cfn-lint >/dev/null 2>&1; then
  step "cfn-lint bootstrap"  cfn-lint bootstrap/bootstrap.yaml
else
  echo; echo "▷ cfn-lint is not installed — skipped here; CI's cloudformation job runs it and cfn-guard (pip install cfn-lint)."
fi
