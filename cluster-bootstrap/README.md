# Vox cluster bootstrap

These files are one-time cluster bootstrap config, applied manually after
`infrastructure/infrastructureBE` has been applied.

Apply order:

1. `cert-manager/` via Helm with `--set installCRDs=true`.
2. `alb-controller/values.yaml`.
3. `karpenter/values.yaml`, then all `karpenter/*.yaml`.
4. `nvidia-device-plugin/values.yaml`.
5. `metrics-server/README.md`.
6. `storage/storageclass-gp3.yaml`.
7. `kube-prometheus-stack/values.yaml`.
8. `dcgm-exporter/values.yaml`.
9. `prometheus-adapter/values.yaml`.
10. `external-secrets/values.yaml`, then `external-secrets/cluster-secret-store.yaml`.
11. `coturn/values.yaml`.
12. `argocd/values.yaml`, then `vox-helm/argocd/*`.

Replace all placeholders before installing:

- `<TF_OUTPUT:vpc_id>`: `terraform output -raw vpc_id`
- `<TF_OUTPUT:cluster_name>`: `terraform output -raw cluster_name`
- `<TF_OUTPUT:cluster_endpoint>`: `terraform output -raw cluster_endpoint`
- `<TF_OUTPUT:alb_irsa_role_arn>`: `terraform output -raw alb_irsa_role_arn`
- `<TF_OUTPUT:karpenter_irsa_role_arn>`: `terraform output -raw karpenter_irsa_role_arn`
- `<TF_OUTPUT:node_instance_profile_name>`: `terraform output -raw node_instance_profile_name`
- `<TF_OUTPUT:eso_irsa_role_arn>`: `terraform output -raw eso_irsa_role_arn`

Notes:

- `coturn` chart repository from the original plan (`https://small-hack.github.io/coturn-chart/`) 404'd on 2026-07-19. That repo was renamed to `open-engineering-nl/coturn-chart`; its GitHub Pages index (`https://open-engineering-nl.github.io/coturn-chart/index.yaml`) does still resolve, but the repo itself is archived/unmaintained. `vox-helm/charts/coturn` instead depends on the actively-maintained, verified-working `pschichtel/helm-charts` "coturn" chart (`https://schich.tel/helm-charts`, see `vox-helm/charts/coturn/Chart.yaml` for why — the other Artifact Hub alternative, `jaconi/coturn`, was tried first but its secret-injection feature was confirmed broken via `helm template`). Install that chart with this values file.
- GPU time-slicing is set to 4 and must stay aligned with `vox-helm/charts/agents/values.yaml` `autoscaling.maxReplicas`.
