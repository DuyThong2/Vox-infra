variable "region" {
  type    = string
  default = "ap-southeast-1"
}

variable "domain_name" {
  type        = string
  description = "Root domain cho Route53 zone (vd: voxenta.net) -- phải là zone đã tồn tại (tạo bởi infrastructureFE)."
  default     = "voxenta.net"
}

# Tag mà AWS Load Balancer Controller tự gắn lên ALB, lấy từ
# alb.ingress.kubernetes.io/group.name trên các Ingress (vox/vox-streaming/
# agents/argocd đều dùng chung group.name này -> chung 1 ALB). Xác nhận thật
# qua `aws elbv2 describe-tags` trên ALB đang chạy: tag key
# "ingress.k8s.aws/stack" = "vox-backend".
variable "alb_stack_tag" {
  type    = string
  default = "vox-backend"
}

# Danh sách subdomain cần trỏ vào ALB backend dùng chung. Không gồm
# domain_name/www -- 2 cái đó trỏ CloudFront, do infrastructureFE quản lý.
variable "backend_subdomains" {
  type    = list(string)
  default = ["api", "stream", "agents", "argocd"]
}

# Tag mà AWS Load Balancer Controller gắn lên NLB do Service:LoadBalancer sinh ra.
# Khác key với ALB ("ingress.k8s.aws/stack") vì nguồn khác nhau: ALB đến từ Ingress,
# NLB đến từ Service. Giá trị là "<namespace>/<service>".
#
# PHẢI lọc chính xác: cụm còn một NLB nữa của coturn, nên data source không có bộ
# lọc này sẽ khớp nhiều hơn một và Terraform báo lỗi.
variable "postgres_nlb_stack_tag" {
  type    = string
  default = "vox/vox-postgresql"
}

# Subdomain trỏ thẳng vào Postgres.
#
# ĐÁNH ĐỔI ĐÃ CÂN NHẮC, không phải mặc định vô ý. Được: pgAdmin/DBeaver cấu hình một
# lần, hostname NLB đổi sau mỗi lần dựng lại cụm cũng không phải sửa. Mất: hostname
# NLB vốn là chuỗi ngẫu nhiên, bot muốn tìm phải quét cả dải AWS -- đặt tên dễ đoán
# là công bố công khai vị trí DB.
#
# Điều đó CHỈ chấp nhận được vì đây là môi trường demo. Cổng 5432 hiện mở ra Internet
# không giới hạn IP (xem chú thích postgresql.primary.service trong
# vox-helm/charts/vox/values.yaml), nên thứ duy nhất đứng chắn là mật khẩu. Trước khi
# có dữ liệu học sinh thật, phải siết loadBalancerSourceRanges hoặc bỏ bản ghi này.
variable "db_subdomain" {
  type    = string
  default = "db"
}
