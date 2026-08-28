output "repository_urls" {
  description = "Push targets for the image build, keyed by service."
  value       = { for name, repo in aws_ecr_repository.this : name => repo.repository_url }
}

output "repository_count" {
  description = "Must be 15. The legacy template created 11."
  value       = length(aws_ecr_repository.this)
}

output "registry" {
  description = "REGISTRY for ./gradlew bootBuildImage --publishImage."
  value       = split("/", values(aws_ecr_repository.this)[0].repository_url)[0]
}

output "certificate_arn" {
  value = aws_acm_certificate_validation.this.certificate_arn
}

output "domain" {
  value = data.aws_route53_zone.this.name
}
