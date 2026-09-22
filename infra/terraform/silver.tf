# Camada silver: normaliza bronze -> schema canonico, em Parquet.
# Diferente das 5 funcoes de ingestao, esta NAO e agendada -- ela reage ao
# S3 avisando que a bronze gravou. Sem orquestracao, e a ingestao nem
# precisa saber que a silver existe.

resource "aws_cloudwatch_log_group" "silver" {
  name              = "/aws/lambda/${var.project_name}-silver"
  retention_in_days = 30
}

# Role propria, nao a compartilhada das funcoes de ingestao: as permissoes
# sao genuinamente diferentes (le bronze / escreve silver, contra escreve
# bronze / le o token). Separar evita que um bug na ingestao consiga
# escrever na silver, e que a silver enxergue o token da SPTrans.
resource "aws_iam_role" "silver_execucao" {
  name = "${var.project_name}-${var.ambiente}-silver-execucao"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "silver_logs_basicos" {
  role       = aws_iam_role.silver_execucao.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "silver_le_bronze_escreve_silver" {
  name = "le-bronze-escreve-silver"
  role = aws_iam_role.silver_execucao.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.dados.arn}/bronze/*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.dados.arn}/silver/*"
      }
    ]
  })
}

resource "aws_lambda_function" "silver" {
  function_name = "${var.project_name}-silver"
  role          = aws_iam_role.silver_execucao.arn

  # Maior que as de posicao porque o maior arquivo da bronze (pontos de SP)
  # tem ~96 mil registros. Memoria na Lambda tambem define CPU, entao subir
  # aqui reduz o tempo (e o custo acaba parecido).
  memory_size = 1024
  timeout     = 300

  package_type = "Image"
  image_uri    = "${aws_ecr_repository.lambda.repository_url}:${var.image_tag}"

  image_config {
    command = ["lambdas.silver.handler.lambda_handler"]
  }

  depends_on = [aws_cloudwatch_log_group.silver]
}

resource "aws_lambda_permission" "s3_invoca_silver" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.silver.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.dados.arn
}

resource "aws_s3_bucket_notification" "bronze_para_silver" {
  bucket = aws_s3_bucket.dados.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.silver.arn
    events              = ["s3:ObjectCreated:*"]

    # Os dois filtros sao o que evita loop infinito: sem eles, o Parquet que
    # a silver grava dispararia a propria silver de novo.
    filter_prefix = "bronze/"
    filter_suffix = ".ndjson"
  }

  depends_on = [aws_lambda_permission.s3_invoca_silver]
}
