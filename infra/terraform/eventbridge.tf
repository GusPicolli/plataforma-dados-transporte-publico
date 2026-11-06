resource "aws_iam_role" "scheduler_invocacao" {
  name = "${var.project_name}-${var.ambiente}-scheduler-invoca-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# A politica de invocar as Lambdas de ingestao e os agendamentos por funcao
# sairam daqui: TODAS as fontes passaram a ser disparadas pelo Step Functions
# (orquestracao.tf). Este papel permanece porque o heartbeat ainda e um
# agendamento direto -- ver a politica em heartbeat.tf.
