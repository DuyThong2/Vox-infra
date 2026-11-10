provider "aws" {
  region = var.region
}

# Zone đã được infrastructureFE tạo (Route53 zone cho voxenta.net) -- stack
# này chỉ đọc, không quản lý zone.
data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = false
}

# ALB được AWS Load Balancer Controller tự tạo khi Ingress (vox/vox-streaming/
# agents/argocd, chung alb.ingress.kubernetes.io/group.name) được apply lần
# đầu -- KHÔNG tồn tại cho tới sau cluster-bootstrap + ArgoCD sync. Vì vậy
# stack này phải apply SAU bước đó, không phải cùng lúc với infrastructureBE.
data "aws_lb" "backend" {
  tags = {
    "ingress.k8s.aws/stack" = var.alb_stack_tag
  }
}

resource "aws_route53_record" "backend" {
  for_each = toset(var.backend_subdomains)

  zone_id = data.aws_route53_zone.this.zone_id
  name    = "${each.value}.${var.domain_name}"
  type    = "A"

  alias {
    name                   = data.aws_lb.backend.dns_name
    zone_id                = data.aws_lb.backend.zone_id
    evaluate_target_health = true
  }
}

# NLB của Postgres, do Service:LoadBalancer trong chart vox sinh ra (không phải Ingress).
# Cùng điều kiện tồn tại như ALB ở trên: chỉ có sau khi ArgoCD sync xong chart vox.
data "aws_lb" "postgres" {
  tags = {
    "service.k8s.aws/stack" = var.postgres_nlb_stack_tag
  }
}

# db.voxenta.net -> NLB Postgres, để pgAdmin/DBeaver cấu hình một lần là xong.
#
# evaluate_target_health = false, KHÁC với bản ghi backend ở trên. NLB này nghe cổng
# 5432 thuần TCP, không có health check kiểu HTTP để Route53 diễn giải; bật lên thì
# Route53 có thể coi target là unhealthy và ngừng trả lời, làm mất kết nối DB dù
# Postgres vẫn chạy bình thường.
resource "aws_route53_record" "postgres" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = "${var.db_subdomain}.${var.domain_name}"
  type    = "A"

  alias {
    name                   = data.aws_lb.postgres.dns_name
    zone_id                = data.aws_lb.postgres.zone_id
    evaluate_target_health = false
  }
}
