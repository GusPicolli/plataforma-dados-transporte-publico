output "bucket_dados" {
  description = "Bucket S3 com as camadas bronze/silver/gold."
  value       = aws_s3_bucket.dados.bucket
}

output "ecr_repository_url" {
  description = "URL do repositorio ECR. So depende de aws_ecr_repository.lambda -- funciona logo apos o apply -target da fase 1 do deploy, antes das Lambdas existirem."
  value       = aws_ecr_repository.lambda.repository_url
}

output "funcoes_lambda" {
  description = "Nome de cada funcao Lambda criada."
  value       = { for k, f in aws_lambda_function.funcoes : k => f.function_name }
}

output "log_groups" {
  description = "Log group de cada funcao, pra abrir direto no CloudWatch Logs Insights."
  value       = { for k, g in aws_cloudwatch_log_group.funcoes : k => g.name }
}

output "parametro_token_sptrans" {
  description = "Nome do parametro no SSM (o valor em si e SecureString, nao aparece aqui)."
  value       = aws_ssm_parameter.sptrans_token.name
}

output "agendamentos" {
  description = "Nome de cada schedule no EventBridge Scheduler."
  value       = { for k, s in aws_scheduler_schedule.funcoes : k => s.name }
}
