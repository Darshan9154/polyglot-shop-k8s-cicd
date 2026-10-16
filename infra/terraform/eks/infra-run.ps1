$ErrorActionPreference='Continue'
$ctx='arn:aws:eks:eu-north-1:536882095289:cluster/polyglot-shop-dev'
foreach ($c in @('mariadb','postgresql','redis','rabbitmq','dynamodb-local')) {
  Write-Output "=== installing $c ==="
  helm --kube-context $ctx upgrade --install $c "C:\Users\darsh\OneDrive\Documents\deepseek-harness\default-workspace\retail-store-devops-agent\k8s\infra\$c" --namespace data --timeout 8m 2>&1 | Select-Object -Last 4
  Write-Output "helm_exit=$LASTEXITCODE"
}
Write-Output '=== INFRA_DEPLOY_DONE ==='
