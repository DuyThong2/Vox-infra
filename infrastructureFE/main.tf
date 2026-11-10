provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_s3_bucket" "spa" {
  bucket = "${var.name}-spa-${replace(var.domain_name, ".", "-")}"
}

resource "aws_s3_bucket_versioning" "spa" {
  bucket = aws_s3_bucket.spa.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "spa" {
  bucket = aws_s3_bucket.spa.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "spa" {
  name                              = "${var.name}-spa-oac"
  description                       = "OAC for SPA S3 origin"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_acm_certificate" "spa" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  subject_alternative_names = ["www.${var.domain_name}"]
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "spa_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.spa.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.this.zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 60
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "spa" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.spa.arn
  validation_record_fqdns = [for r in aws_route53_record.spa_cert_validation : r.fqdn]
}

resource "aws_cloudfront_distribution" "spa" {
  provider = aws.us_east_1

  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  aliases = [
    var.domain_name,
    "www.${var.domain_name}",
  ]

  origin {
    domain_name = aws_s3_bucket.spa.bucket_regional_domain_name
    origin_id   = "spa-s3-origin"

    origin_access_control_id = aws_cloudfront_origin_access_control.spa.id
  }

  

  default_cache_behavior {
    target_origin_id       = "spa-s3-origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["GET", "HEAD", "OPTIONS"]
    cached_methods  = ["GET", "HEAD"]

    compress = true

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }
  }

  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }


  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.spa.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  depends_on = [aws_acm_certificate_validation.spa]
}

resource "aws_s3_bucket_policy" "spa" {
  bucket = aws_s3_bucket.spa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipalReadOnly"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.spa.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.spa.arn
          }
        }
      }
    ]
  })
}

resource "aws_route53_record" "root" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.spa.domain_name
    zone_id                = aws_cloudfront_distribution.spa.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.this.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.spa.domain_name
    zone_id                = aws_cloudfront_distribution.spa.hosted_zone_id
    evaluate_target_health = false
  }
}

# CORS cho bucket chứa tài nguyên câu hỏi (ảnh/audio/video).
#
# Trình duyệt PUT thẳng lên S3 bằng presigned URL, không đi qua backend -- nên chính S3 phải trả
# Access-Control-Allow-Origin, không có chỗ nào khác chen vào được. URL được ký kèm content-type
# (X-Amz-SignedHeaders=content-type;host) nên request luôn là "non-simple" và luôn có preflight
# OPTIONS: thiếu luật này thì upload hỏng ngay ở preflight, chưa từng chạm tới byte nào.
#
# Bucket được tạo tay từ trước, không nằm trong state của bất kỳ stack nào (Helm values chỉ tham
# chiếu theo tên). aws_s3_bucket_cors_configuration quản đúng một subresource nên trỏ thẳng theo
# tên là đủ, không phải import cả bucket.
#
# Đặt ở stack FE vì luật này nói về ORIGIN của trình duyệt, mà chỉ stack này biết domain đã dựng.
resource "aws_s3_bucket_cors_configuration" "question_assets_uploads" {
  bucket = var.uploads_bucket_name

  cors_rule {
    # Ký tên miền deploy và cả localhost trong cùng một luật: máy dev chạy Vite ở cổng 5173 gọi
    # thẳng lên đúng bucket này, nên nếu chỉ khai domain thật thì upload chỉ chạy sau khi deploy.
    allowed_origins = concat(
      [
        "https://${var.domain_name}",
        "https://www.${var.domain_name}",
      ],
      var.uploads_local_dev_origins,
    )

    # PUT để upload, GET/HEAD để đọc lại tệp bằng fetch (thẻ <img> thì không cần CORS).
    allowed_methods = ["GET", "HEAD", "PUT"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}
