# metrics-server bootstrap

EKS does not install `metrics-server` by default. All CPU/memory HPAs depend on
the `metrics.k8s.io` API served by this component.

Install from the current official release manifest:

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
kubectl rollout status deployment/metrics-server -n kube-system
kubectl top nodes
```

If kubelet TLS validation fails in this demo cluster, patch metrics-server with
`--kubelet-insecure-tls` and record that in the worksheet.

