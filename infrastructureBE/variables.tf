variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "name" {
  type    = string
  default = "voxenta"
}

variable "cluster_name" {
  type    = string
  default = "vox-eks"
}

# Verified against Amazon EKS standard-support versions on 2026-07-19:
# https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html
variable "cluster_version" {
  type    = string
  default = "1.36"
}

variable "vpc_cidr" {
  type    = string
  default = "10.1.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.1.1.0/24", "10.1.2.0/24"]
}

variable "node_instance_type" {
  type = string
  # t3.medium -> t3.large (2026-08-19). Lý do là GIỚI HẠN SỐ POD, không phải CPU/RAM:
  # trên EKS số pod tối đa mỗi node suy ra từ số ENI/IP của loại máy, và t3.medium chỉ
  # cho 17 pod. Đo được ngày 2026-08-18: node này đứng ở đúng 17/17 -- kín tuyệt đối,
  # trong khi hai node t3a.xlarge do Karpenter cấp mới dùng 17/58 và 5/58.
  #
  # Hậu quả đã xảy ra thật, không phải lo xa: một replica Karpenter nằm Pending suốt
  # 3 ngày ("0/3 nodes are available: 1 Too many pods"), và một pod vox không xếp được
  # khi HPA nâng lên 3.
  #
  # Vì sao node này luôn chật: playbook-deploy cài cert-manager (5.1) và ALB controller
  # (5.2) TRƯỚC Karpenter (5.3), nên lúc đó nó là node duy nhất trong cụm và toàn bộ
  # add-ons nền tảng đáp xuống đây. Kubernetes không bao giờ tự cân bằng lại, nên trạng
  # thái đó đóng băng vĩnh viễn. Nới máy là cách rẻ nhất; dồn add-ons sang node Karpenter
  # thì không làm được vì Karpenter tự cấm chạy trên node của chính nó và coturn bị ghim
  # vào node group này để giữ Elastic IP.
  #
  # t3.large = 35 pod, đủ dư cho 17 add-ons hiện có. t3a.large cùng cấu hình và rẻ hơn
  # ~10%, chưa đổi vì chưa cần.
  default = "t3.large"
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 2
}

variable "node_desired_size" {
  type = number
  # GIỮ 1. Đã thử nâng lên 2 rồi hạ lại ngay trong ngày 2026-08-26 -- ghi lại ở đây để lần
  # sau khỏi đề xuất lại mà không biết chuyện đã xảy ra.
  #
  # VẤN ĐỀ CÓ THẬT mà 2 node định chữa: coturn bị ghim
  # `nodeSelector: eks.amazonaws.com/nodegroup=vox-eks-static-ng` vì nó chạy hostNetwork và
  # Elastic IP gắn vào ENI của node đó. Nhãn ấy do EKS managed node group cấp, node Karpenter
  # KHÔNG bao giờ có. Nên tập node hợp lệ của coturn đúng bằng số node tĩnh -- ở đây là MỘT.
  # Đo thật cùng ngày: node tĩnh đầy 1900m/1930m CPU (98%), ArgoCD cuốn lại pod coturn, pod
  # mới đứng `Pending` 24 PHÚT và TURN chết hẳn. Karpenter thấy pod nhưng TỪ CHỐI dựng máy --
  # log: `incompatible requirements, label "eks.amazonaws.com/nodegroup" does not have known
  # values`. Cụm không có cluster-autoscaler, nên KHÔNG thành phần nào có thẩm quyền nới node
  # group này: không người vào dọn chỗ thì nó Pending vĩnh viễn.
  #
  # VÌ SAO VẪN GIỮ 1: giá ~$0.08/giờ (~$60/tháng) cho một máy gần như chỉ để dự phòng, ở quy
  # mô dưới 100 sinh viên và 2-3 người thi đồng thời. Cách chữa rẻ hơn khi lại kẹt là dọn chỗ
  # trên chính node tĩnh -- lần đó chỉ cần `kubectl delete pod` một pod vox-streaming (request
  # 500m) tình cờ đáp xuống đó là coturn vào ngay.
  #
  # ⚠️ NẾU LẦN SAU LẠI NÂNG LÊN 2 RỒI MUỐN HẠ: đừng để ASG tự chọn máy để xoá. Node thứ hai
  # rơi vào AZ 1b, còn node đầu ở 1a giữ EIP + các ổ EBS tái sử dụng (cũng ở 1a). ASG chọn
  # nhầm node 1a là Postgres/Redis không xếp lại được sang 1b và EIP mất chỗ bám. Bật
  # `aws autoscaling set-instance-protection --protected-from-scale-in` cho instance ở 1a
  # TRƯỚC khi hạ, rồi gỡ bảo vệ sau.
  default = 1
}

variable "cluster_endpoint_public_access_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "secret_names" {
  type = set(string)
  # vox/app: SMTP, Google OAuth client secret, sys-admin bootstrap identity,
  # and vox's own S3 exam-upload IAM credential — app-level vox secrets that
  # don't belong under database/jwt (see vox-helm/charts/vox/templates/externalsecret.yaml).
  default = ["vox/database", "vox/jwt", "vox/agents", "vox/coturn", "vox/streaming", "vox/app"]
}

