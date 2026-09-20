variable "aws_region" {
  description = "Regiao AWS onde tudo e criado."
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefixo usado no nome de todo recurso (bucket, funcoes, parametro)."
  type        = string
  default     = "onibus-tempo-real"
}

variable "ambiente" {
  description = "dev | prod -- so afeta tags e o sufixo do bucket."
  type        = string
  default     = "dev"
}

variable "sptrans_token" {
  description = "Token da API Olho Vivo. Vai pro SSM Parameter Store (SecureString), nunca pro codigo. Cadastro gratuito em https://www.sptrans.com.br/desenvolvedores/"
  type        = string
  sensitive   = true
}

variable "lambda_memory_mb" {
  description = "Memoria por tipo de funcao. Posicao e leve (1 request); cadastro processa GTFS/varre linhas, precisa de mais."
  type = object({
    posicoes = number
    cadastro = number
  })
  default = {
    posicoes = 256
    cadastro = 512
  }
}

variable "lambda_timeout_segundos" {
  description = "Timeout por tipo de funcao. Fortaleza itera ~540 linhas a ~0.4s cada (~3-4min medidos) -- timeout com folga real, nao um numero redondo chutado."
  type = object({
    posicoes           = number
    cadastro_sp_rio    = number
    cadastro_fortaleza = number
  })
  default = {
    posicoes           = 30
    cadastro_sp_rio    = 60
    cadastro_fortaleza = 420
  }
}

variable "agenda_posicoes" {
  description = "Cron do EventBridge Scheduler pra SP/Rio (posicao). Formato AWS: cron(minuto hora dia-do-mes mes dia-da-semana ano)."
  type        = string
  default     = "cron(0/30 5-21 ? * MON-SAT *)" # a cada 30min, 5h-22h, seg-sab -- ver Proposta_inicial
}

variable "agenda_cadastro" {
  description = "Cron do EventBridge Scheduler pra linhas/pontos (as 3 pracas). 1x/dia."
  type        = string
  default     = "cron(0 5 ? * MON-SAT *)"
}

variable "agendamento_habilitado" {
  description = "Se false, os 5 schedules sobem DESLIGADOS -- criados, mas sem disparar sozinhos. Default false de proposito: ligar automaticamente a coleta recorrente (e o custo/tráfego que vem junto) deve ser uma escolha explicita, nao um efeito colateral do apply."
  type        = bool
  default     = false
}

variable "image_tag" {
  description = "Tag da imagem no ECR que as 5 funcoes devem rodar. Precisa ja existir no repositorio antes do apply -- ver 'deploy em 2 fases' no README."
  type        = string
  default     = "latest"
}
