#!/usr/bin/env bash
# One-time bootstrap of Argo CD on the dev server, after which everything in
# this repo is applied by Argo CD itself. Idempotent: safe to re-run after an
# Argo CD upgrade or to repair the argocd-cm patch.
#
# Prerequisites on the machine running this:
#   - kubectl pointed at the dev-server cluster
#   - argocd CLI (https://argo-cd.readthedocs.io/en/stable/cli_installation/)
#   - a kubeconfig context for the prod cluster, if it is not registered yet
#
# Steps that need credentials are printed, not executed, so nothing secret
# ever lives in this file.
set -euo pipefail

ARGOCD_VERSION="${ARGOCD_VERSION:-v3.5.1}"   # keep in step with the running cluster
REPO_URL="https://dev.azure.com/edodevops0169/TackYourBudget/_git/app-manifests"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> 1/4 Install or upgrade Argo CD ${ARGOCD_VERSION}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
kubectl -n argocd rollout status deployment/argocd-server --timeout=180s

echo "==> 2/4 Track Endpoints/EndpointSlice (needed for the prod host Postgres)"
kubectl -n argocd patch configmap argocd-cm --type merge --patch-file "${HERE}/argocd-cm.patch.yaml"

echo "==> 3/4 Credentials (manual, printed only)"
cat <<MSG
  Repository credential for ${REPO_URL} (Azure DevOps PAT with Code: Read):
    argocd repo add ${REPO_URL} --username azure --password <PAT>

  Prod cluster (only once; re-run when the prod IP changes):
    argocd cluster add <prod-kubeconfig-context> --name prod
  then make sure spec.destination.server in argocd/apps/budget-app-production.yaml
  equals the server URL of the new cluster Secret.
MSG

echo "==> 4/4 Root Application (app-of-apps); it creates the per-environment apps"
kubectl apply -f "${HERE}/root.yaml"

echo "Done. Watch with: kubectl -n argocd get applications"
