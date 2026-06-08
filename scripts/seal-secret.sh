#!/usr/bin/env bash
set -euo pipefail

CONTROLLER_NAME="${SEALED_SECRETS_CONTROLLER_NAME:-sealed-secrets-controller}"
CONTROLLER_NAMESPACE="${SEALED_SECRETS_CONTROLLER_NAMESPACE:-kube-system}"
KUBESEAL_BIN="${KUBESEAL_BIN:-kubeseal}"

usage() {
  cat <<'EOF'
Uso:
  seal-secret.sh <nome> <namespace> [opções]

Opções:
  --from-literal=KEY=VALUE     Adiciona chave literal (repetível)
  --docker-server=HOST         Cria secret docker-registry
  --docker-username=USER       Usuário do registry
  --docker-password=TOKEN      Token/senha do registry
  --docker-email=EMAIL         E-mail do registry (opcional)
  --output-dir=DIR             Diretório de saída (padrão: secrets/<namespace>)
  -h, --help                   Exibe esta ajuda

Exemplos:
  ./seal-secret.sh app-config ckad-apps \
    --from-literal=API_KEY=abc123

  ./seal-secret.sh gitlab-registry ckad-apps \
    --docker-server=registry.gitlab.com \
    --docker-username=deploy-token \
    --docker-password=glpat-xxx
EOF
}

SECRET_NAME=""
NAMESPACE=""
OUTPUT_DIR=""
DOCKER_SERVER=""
DOCKER_USERNAME=""
DOCKER_PASSWORD=""
DOCKER_EMAIL="deploy@lab.local"
declare -a LITERALS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --from-literal=*)
      LITERALS+=("${1#*=}")
      shift
      ;;
    --docker-server=*)
      DOCKER_SERVER="${1#*=}"
      shift
      ;;
    --docker-username=*)
      DOCKER_USERNAME="${1#*=}"
      shift
      ;;
    --docker-password=*)
      DOCKER_PASSWORD="${1#*=}"
      shift
      ;;
    --docker-email=*)
      DOCKER_EMAIL="${1#*=}"
      shift
      ;;
    --output-dir=*)
      OUTPUT_DIR="${1#*=}"
      shift
      ;;
    --*)
      echo "Opção desconhecida: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -z "$SECRET_NAME" ]]; then
        SECRET_NAME="$1"
      elif [[ -z "$NAMESPACE" ]]; then
        NAMESPACE="$1"
      else
        echo "Argumento inesperado: $1" >&2
        usage >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$SECRET_NAME" || -z "$NAMESPACE" ]]; then
  usage >&2
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl não encontrado no PATH." >&2
  exit 1
fi

if ! command -v "$KUBESEAL_BIN" >/dev/null 2>&1; then
  echo "$KUBESEAL_BIN não encontrado. Instale kubeseal ou defina KUBESEAL_BIN." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/../secrets/${NAMESPACE}}"
OUTPUT_FILE="${OUTPUT_DIR}/${SECRET_NAME}.sealedsecret.yaml"

mkdir -p "$OUTPUT_DIR"

SECRET_MANIFEST="$(mktemp)"
trap 'rm -f "$SECRET_MANIFEST"' EXIT

if [[ -n "$DOCKER_SERVER" ]]; then
  if [[ -z "$DOCKER_USERNAME" || -z "$DOCKER_PASSWORD" ]]; then
    echo "Para docker-registry, informe --docker-username e --docker-password." >&2
    exit 1
  fi

  kubectl create secret docker-registry "$SECRET_NAME" \
    --namespace="$NAMESPACE" \
    --docker-server="$DOCKER_SERVER" \
    --docker-username="$DOCKER_USERNAME" \
    --docker-password="$DOCKER_PASSWORD" \
    --docker-email="$DOCKER_EMAIL" \
    --dry-run=client -o yaml > "$SECRET_MANIFEST"
elif [[ ${#LITERALS[@]} -gt 0 ]]; then
  literal_args=()
  for literal in "${LITERALS[@]}"; do
    literal_args+=(--from-literal="$literal")
  done

  kubectl create secret generic "$SECRET_NAME" \
    --namespace="$NAMESPACE" \
    "${literal_args[@]}" \
    --dry-run=client -o yaml > "$SECRET_MANIFEST"
else
  echo "Informe --from-literal ou opções de docker-registry." >&2
  exit 1
fi

"$KUBESEAL_BIN" \
  --controller-name="$CONTROLLER_NAME" \
  --controller-namespace="$CONTROLLER_NAMESPACE" \
  -o yaml < "$SECRET_MANIFEST" > "$OUTPUT_FILE"

echo "SealedSecret gerado: $OUTPUT_FILE"
echo "Faça commit do arquivo e o ArgoCD sincronizará automaticamente."
