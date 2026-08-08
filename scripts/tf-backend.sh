#!/usr/bin/env bash
# Init (and optionally migrate) a stack onto the S3 backend.
# Usage:
#   ./scripts/tf-backend.sh bootstrap-global     # first apply with local state
#   ./scripts/tf-backend.sh migrate global|dev|prod
#   ./scripts/tf-backend.sh init global|dev|prod
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMD="${1:-}"
STACK="${2:-}"

die() { echo "$*" >&2; exit 1; }

account_id() {
  aws sts get-caller-identity --query Account --output text
}

write_backend_hcl() {
  local stack="$1"
  local bucket="popo-tfstate-$(account_id)"
  local key="${stack}/terraform.tfstate"
  mkdir -p "$ROOT/infra/backends"
  cat >"$ROOT/infra/backends/${stack}.hcl" <<EOF
bucket       = "${bucket}"
key          = "${key}"
region       = "eu-west-1"
encrypt      = true
use_lockfile = true
EOF
  echo "Wrote infra/backends/${stack}.hcl (bucket=${bucket})"
}

stack_dir() {
  case "$1" in
    global) echo "$ROOT/infra/global" ;;
    dev)    echo "$ROOT/infra/environments/dev" ;;
    prod)   echo "$ROOT/infra/environments/prod" ;;
    *) die "Unknown stack: $1 (global|dev|prod)" ;;
  esac
}

case "$CMD" in
  bootstrap-global)
    cd "$ROOT/infra/global"
    terraform init -backend=false
    terraform apply
    write_backend_hcl global
    echo ""
    echo "Next: migrate global state to S3:"
    echo "  ./scripts/tf-backend.sh migrate global"
    echo "Then copy name_servers into Namecheap:"
    echo "  cd infra/global && terraform output name_servers"
    ;;

  migrate)
    [[ -n "$STACK" ]] || die "Usage: $0 migrate global|dev|prod"
    write_backend_hcl "$STACK"
    DIR="$(stack_dir "$STACK")"
    cd "$DIR"
    terraform init -backend-config="$ROOT/infra/backends/${STACK}.hcl" -migrate-state -force-copy
    echo "Migrated $STACK → s3://popo-tfstate-$(account_id)/${STACK}/terraform.tfstate"
    echo "You may delete local terraform.tfstate* in $DIR"
    ;;

  init)
    [[ -n "$STACK" ]] || die "Usage: $0 init global|dev|prod"
    write_backend_hcl "$STACK"
    DIR="$(stack_dir "$STACK")"
    cd "$DIR"
    terraform init -backend-config="$ROOT/infra/backends/${STACK}.hcl"
    ;;

  *)
    die "Usage: $0 bootstrap-global | migrate <stack> | init <stack>"
    ;;
esac
