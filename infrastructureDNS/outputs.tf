output "backend_alb_dns_name" {
  value = data.aws_lb.backend.dns_name
}

output "backend_records" {
  value = [for r in aws_route53_record.backend : r.fqdn]
}

output "postgres_endpoint" {
  description = "Host:port dán thẳng vào pgAdmin/DBeaver."
  value       = "${aws_route53_record.postgres.fqdn}:5432"
}
