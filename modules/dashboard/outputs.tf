output "name" {
  value = aws_cloudwatch_dashboard.this.dashboard_name
}

output "url" {
  description = "The page in the console, for the README and the QA script."
  value       = "https://${var.region}.console.aws.amazon.com/cloudwatch/home?region=${var.region}#dashboards:name=${aws_cloudwatch_dashboard.this.dashboard_name}"
}

output "body" {
  description = "The rendered dashboard body, for inspecting the widget JSON without the console."
  value       = aws_cloudwatch_dashboard.this.dashboard_body
}
