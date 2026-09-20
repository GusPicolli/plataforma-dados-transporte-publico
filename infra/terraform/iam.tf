resource "aws_iam_role" "lambda_execucao" {
  name = "${var.project_name}-${var.ambiente}-lambda-execucao"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "logs_basicos" {
  role       = aws_iam_role.lambda_execucao.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "escrita_s3_bronze" {
  name = "escrita-bronze"
  role = aws_iam_role.lambda_execucao.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "${aws_s3_bucket.dados.arn}/bronze/*"
    }]
  })
}

# Uma unica role pra todas as 5 funcoes, por simplicidade -- so as duas de
# SP de fato leem o parametro do SSM. Least-privilege "de verdade" seria
# separar a role de SP, mas pra 5 funcoes internas isso e complexidade sem
# ganho real de seguranca aqui; decisao consciente, nao descuido.
resource "aws_iam_role_policy" "leitura_ssm_token_sptrans" {
  name = "leitura-token-sptrans"
  role = aws_iam_role.lambda_execucao.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameter"]
      Resource = aws_ssm_parameter.sptrans_token.arn
    }]
  })
}
