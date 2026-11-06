resource "aws_ecr_repository" "lambda" {
  name = "${var.project_name}-lambda"
  # Mesma logica do bucket: sem isto o destroy falha porque ha imagem
  # publicada no repositorio.
  force_delete = var.permitir_destruir_dados

  image_tag_mutability = "MUTABLE" # "latest" precisa poder ser sobrescrita a cada push

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Sem isso a lista de imagens cresce pra sempre (mesma logica da politica de
# ciclo de vida do bucket em s3.tf -- custo que se acumula sozinho se
# ninguem cuidar). Mantem as 10 mais recentes com tag, apaga untagged com
# mais de 1 dia (sobra de builds intermediarios).
resource "aws_ecr_lifecycle_policy" "lambda" {
  repository = aws_ecr_repository.lambda.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Manter so as 10 imagens com tag mais recentes"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["latest"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Apagar imagem sem tag (sobra de build) com mais de 1 dia"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      }
    ]
  })
}
