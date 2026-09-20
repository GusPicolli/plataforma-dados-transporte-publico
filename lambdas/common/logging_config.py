from aws_lambda_powertools import Logger


def criar_logger(servico):
    """Logger estruturado (JSON) do AWS Lambda Powertools. Cada linha vira
    um objeto JSON no CloudWatch, com request_id/cold_start/etc injetados
    automaticamente quando o handler usa @logger.inject_lambda_context."""
    return Logger(service=servico)
