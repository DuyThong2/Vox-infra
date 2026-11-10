# Vox / Voxenta Infrastructure

Hạ tầng AWS + Kubernetes cho Voxenta (nền tảng thi/giám sát thi online có AI
proctoring). Gồm nhiều Terraform project độc lập (state riêng) và một bộ
manifest bootstrap cho cụm EKS, được apply theo thứ tự nhất định.

## Tổng quan hệ thống đang chạy

| Thư mục | Công cụ | Đang quản lý gì |
|---|---|---|
| [`ecr/`](ecr/) | Terraform | 3 ECR repo (`vox-app`, `vox-streaming`, `vox-agents`) chứa image Docker cho backend Java, streaming Go, agents Python. Lifecycle policy tự xoá image untagged sau 3 ngày và chỉ giữ 5 image tagged gần nhất. |
| [`ci-iam-users/`](ci-iam-users/) | Terraform | 2 IAM user dùng cho GitHub Actions CI (push ECR, deploy FE lên S3/CloudFront). Không có quyền `eks:*` — deploy backend đi theo GitOps qua ArgoCD, không qua IAM. |
| [`infrastructureBE/`](infrastructureBE/) | Terraform | VPC, EKS cluster (`vox-eks`), node group tĩnh, OIDC/IRSA cho ALB Controller, Karpenter, EBS CSI, External Secrets; KMS key + AWS Secrets Manager (`vox/database`, `vox/jwt`, `vox/agents`, `vox/coturn`, `vox/streaming`, `vox/app`); Elastic IP + security group rule cho coturn (TURN server) chạy `hostNetwork`. Đây là phần hay bị destroy/recreate giữa các vòng test để tiết kiệm chi phí GPU. |
| [`cluster-bootstrap/`](cluster-bootstrap/) | Helm/kubectl (thủ công) | Cài add-on vào cụm EKS sau khi `infrastructureBE` apply xong: cert-manager, AWS LB Controller, Karpenter (NodePool CPU + GPU), NVIDIA device plugin, metrics-server, storage class gp3, kube-prometheus-stack, dcgm-exporter, prometheus-adapter, External Secrets Operator, coturn, ArgoCD. Xem thứ tự chi tiết trong [`cluster-bootstrap/README.md`](cluster-bootstrap/README.md). |
| [`infrastructureFE/`](infrastructureFE/) | Terraform | SPA frontend: S3 bucket (chặn truy cập public, chỉ CloudFront qua OAC), CloudFront distribution, ACM certificate (us-east-1), Route53 record cho domain root + `www`, và CORS cho bucket `vox-exam-uploads` (ảnh/audio/video câu hỏi, upload thẳng từ browser qua presigned URL). |
| [`infrastructureDNS/`](infrastructureDNS/) | Terraform | Route53 A record (alias) cho các subdomain backend (`api`, `stream`, `agents`, `argocd`) trỏ vào ALB do AWS LB Controller tự tạo từ Ingress, và `db.<domain>` trỏ vào NLB của Postgres. Phải apply SAU khi ArgoCD đã sync ứng dụng (ALB/NLB phải tồn tại trước). |

Ứng dụng thực tế (Helm charts, ArgoCD Application) nằm ở repo khác
(`vox-helm`), không nằm trong repo này — các thư mục ở đây chỉ là hạ tầng
nền (AWS resources + cluster bootstrap), việc deploy app đi qua GitOps.

## Thứ tự apply (từ đầu, trên tài khoản AWS mới)

1. `ecr/` — tạo ECR repo trước vì `ci-iam-users` cần tên repo để scope quyền IAM.
2. `ci-iam-users/` — cần `fe_domain_name` khớp với `domain_name` sẽ dùng ở `infrastructureFE`.
3. `infrastructureBE/` — VPC + EKS + IAM/IRSA + Secrets Manager.
4. `cluster-bootstrap/` — cài add-on thủ công theo thứ tự trong README của thư mục này (cần output của bước 3: VPC ID, cluster name/endpoint, các IRSA role ARN...).
5. Deploy app qua ArgoCD (repo `vox-helm`, không nằm ở đây) — tạo ra ALB/NLB mà bước 6 cần.
6. `infrastructureFE/` — SPA + CloudFront, có thể làm song song/độc lập với BE.
7. `infrastructureDNS/` — chỉ apply được sau bước 5, vì nó đọc ALB/NLB có sẵn qua tag (`ingress.k8s.aws/stack`, `service.k8s.aws/stack`), không tự tạo.

Mỗi Terraform project có state riêng trên S3 (`voxenta-terraform-state-be`,
region `ap-southeast-1`), key khác nhau theo từng stack — xem `backend.tf`
trong từng thư mục.

## Chạy Terraform

Mỗi thư mục Terraform là một project độc lập:

```bash
cd infrastructureBE   # hoặc ecr / ci-iam-users / infrastructureFE / infrastructureDNS
terraform init
terraform plan
terraform apply
```

Cần tự tạo `terraform.tfvars` cho từng project (không commit — xem
[`.gitignore`](.gitignore)) với tối thiểu các biến không có default, ví dụ
`domain_name` (`infrastructureFE`, `infrastructureDNS`) và `fe_domain_name`
(`ci-iam-users`). Yêu cầu AWS credentials có quyền tương ứng và quyền đọc/ghi
bucket state ở trên.

## Vì sao nhiều file bị `.gitignore`

`.terraform/`, `*.tfstate*`, `*.tfvars`, `tfplan*` chứa thông tin hạ tầng
thật (resource ID, ARN, state đầy đủ của tài khoản AWS) và có thể chứa giá
trị nhạy cảm — không commit. Chi tiết xem [`.gitignore`](.gitignore).
