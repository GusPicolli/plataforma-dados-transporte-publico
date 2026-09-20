resource "aws_ssm_parameter" "sptrans_token" {
  name        = "/${var.project_name}/${var.ambiente}/sptrans-token"
  description = "Token da API Olho Vivo (SPTrans). So as funcoes de SP leem isso -- Rio e Fortaleza nao precisam de token."
  type        = "SecureString"
  value       = var.sptrans_token
}
