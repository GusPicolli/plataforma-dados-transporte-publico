# Metabase numa EC2 que liga e desliga sob demanda.
#
# POR QUE EC2 E NAO FARGATE: no Fargate o container pode ser substituido a
# qualquer momento, entao o banco de metadados do Metabase (dashboards,
# usuarios, conexoes) precisaria de RDS -- ~US$ 13/mes que NAO desligam,
# porque a AWS religa um RDS parado depois de 7 dias. Aqui o H2 mora num
# disco EBS comum, que persiste no stop e custa centavos.
#
# Tentar H2 sobre EFS no Fargate seria pedir corrupcao: o H2 depende de lock
# de arquivo, e NFS nao garante isso.
#
# POR QUE t4g (Graviton): ~20% mais barato que x86, e a imagem oficial do
# Metabase publica arm64 (verificado no manifesto).
#
# CUSTO, ligando so no horario comercial (~220h/mes):
#   t4g.small   US$ 0,0168/h x 220h  = US$ 3,70
#   EBS 20 GB gp3                    = US$ 1,60   (cobrado mesmo parado)
#   IPv4 publico x 220h              = US$ 1,10   (devolvido no stop)
#                                      ----------
#                                      ~US$ 6,40/mes
# Sempre ligado seriam ~US$ 17.

data "aws_ssm_parameter" "ami_al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_vpc" "padrao" {
  default = true
}

resource "aws_security_group" "metabase" {
  name        = "${var.project_name}-${var.ambiente}-metabase"
  description = "Acesso ao Metabase"
  vpc_id      = data.aws_vpc.padrao.id

  # NENHUMA entrada por padrao, e com o Cloudflare Tunnel nem e preciso
  # abrir: o container faz uma conexao de SAIDA ate a Cloudflare, e o
  # trafego chega por ela, com HTTPS de ponta a ponta.
  #
  # A variavel existe como alternativa pra quem nao usar o tunel. Mas atencao:
  # o Metabase escuta em 127.0.0.1:3000 dentro da instancia, entao abrir a
  # porta aqui SOZINHO nao basta -- e proposital, pra nao expor por engano.
  dynamic "ingress" {
    for_each = var.metabase_cidr_liberado == "" ? [] : [var.metabase_cidr_liberado]

    content {
      description = "Metabase"
      from_port   = 3000
      to_port     = 3000
      protocol    = "tcp"
      cidr_blocks = [ingress.value]
    }
  }

  egress {
    description = "Saida liberada (Athena, S3, Docker Hub)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ---------------------------------------------------------------------------
# Credencial: instance profile, nao chave de acesso
# ---------------------------------------------------------------------------
# Esta e a diferenca principal em relacao ao Metabase local. La a cadeia de
# credenciais nao funcionou e foi preciso guardar access key no banco do
# proprio Metabase. Aqui a EC2 entrega credencial temporaria pelo IMDS, que o
# SDK Java consome sem problema -- nenhuma chave e digitada nem armazenada.

resource "aws_iam_role" "metabase" {
  name = "${var.project_name}-${var.ambiente}-metabase"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_instance_profile" "metabase" {
  name = "${var.project_name}-${var.ambiente}-metabase"
  role = aws_iam_role.metabase.name
}

# Session Manager: entrar na maquina SEM abrir porta e SEM chave SSH. O
# acesso passa pela API da AWS, com IAM e registro no CloudTrail -- mais
# seguro que SSH, e e o unico jeito de diagnosticar a instancia hoje.
resource "aws_iam_role_policy_attachment" "metabase_ssm" {
  role       = aws_iam_role.metabase.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "metabase_config" {
  name = "le-configuracao"
  role = aws_iam_role.metabase.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["ssm:GetParameter"]
        Resource = [
          aws_ssm_parameter.metabase_versao.arn,
          aws_ssm_parameter.cloudflare_tunnel_token.arn,
        ]
      },
      {
        # Exigido pra ler o SecureString do token.
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.aws_region}.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy" "metabase" {
  name = "consulta-athena"
  role = aws_iam_role.metabase.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "athena:StartQueryExecution",
          "athena:GetQueryExecution",
          "athena:GetQueryResults",
          "athena:StopQueryExecution",
          "athena:GetWorkGroup",
          "athena:ListWorkGroups",
          "athena:ListDataCatalogs",
          "athena:GetDataCatalog",

          # LISTAR o que existe, que e diferente de CONSULTAR.
          #
          # Sem estas quatro, o Metabase conecta, roda SQL nativo e devolve
          # resultado -- mas mostra ZERO TABELA na interface, porque o driver
          # descobre tabela pelas APIs de metadado do Athena, e nao pelo Glue.
          # A falha e silenciosa: a sincronizacao responde "ok" e nao acha
          # nada.
          #
          # Ter glue:GetTables nao substitui: sao caminhos diferentes.
          "athena:ListDatabases",
          "athena:GetDatabase",
          "athena:ListTableMetadata",
          "athena:GetTableMetadata",
        ]
        Resource = "*"
      },
      {
        # O Glue descreve as tabelas -- sem isto o Metabase conecta mas nao
        # enxerga tabela nenhuma.
        Effect = "Allow"
        Action = [
          "glue:GetDatabase",
          "glue:GetDatabases",
          "glue:GetTable",
          "glue:GetTables",
          "glue:GetPartition",
          "glue:GetPartitions",
        ]
        Resource = "*"
      },
      {
        # LER o Parquet da silver/gold, e VERIFICAR o bucket de saida.
        #
        # GetBucketLocation e ListBucketMultipartUploads nao sao opcionais:
        # o driver JDBC do Athena checa o bucket de staging antes da primeira
        # consulta e falha com "Unable to verify/create output bucket" sem
        # eles. Descoberto testando com a role de verdade -- no Metabase
        # local isso passava porque ele usa a chave de administrador, que
        # esconde qualquer furo de permissao.
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:ListBucket",
          "s3:GetBucketLocation",
          "s3:ListBucketMultipartUploads",
        ]
        Resource = [
          aws_s3_bucket.dados.arn,
          "${aws_s3_bucket.dados.arn}/*",
        ]
      },
      {
        # GRAVAR o resultado da consulta. Esquecer este bloco faz TODA
        # consulta falhar -- o Athena grava o resultado antes de devolver.
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.dados.arn}/athena-results/*"
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# Configuracao que a instancia le no boot
# ---------------------------------------------------------------------------
# Versao e token ficam no SSM, e nao no user_data, porque user_data SO RODA
# NA CRIACAO. Se estivessem la, trocar a versao ou o token exigiria recriar a
# instancia -- e isso apaga o disco raiz, onde moram os dashboards.
#
# Assim um reinicio (ou o script rodado via SSM) pega a configuracao nova.

resource "aws_ssm_parameter" "metabase_versao" {
  name        = "/${var.project_name}/${var.ambiente}/metabase-versao"
  description = "Tag da imagem do Metabase que a instancia deve rodar."
  type        = "String"
  value       = var.metabase_versao
}

resource "aws_ssm_parameter" "cloudflare_tunnel_token" {
  name        = "/${var.project_name}/${var.ambiente}/cloudflare-tunnel-token"
  description = "Token do Cloudflare Tunnel. Vazio = sem tunel."
  type        = "SecureString"
  value       = var.cloudflare_tunnel_token == "" ? "nao-configurado" : var.cloudflare_tunnel_token

  # O token real pode ser colocado direto no console sem passar pelo
  # Terraform (e sem ficar no state). Por isso o valor nao e reconciliado.
  lifecycle {
    ignore_changes = [value]
  }
}

# ---------------------------------------------------------------------------
# A instancia
# ---------------------------------------------------------------------------

resource "aws_instance" "metabase" {
  ami           = data.aws_ssm_parameter.ami_al2023_arm.value
  instance_type = "t4g.small"

  iam_instance_profile   = aws_iam_instance_profile.metabase.name
  vpc_security_group_ids = [aws_security_group.metabase.id]

  # IP publico auto-atribuido: e devolvido quando a instancia para, entao
  # nao ha cobranca de IPv4 com ela desligada. Um Elastic IP seria cobrado
  # o tempo todo, inclusive parado.
  associate_public_ip_address = true

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  # IMDSv2 obrigatorio: e por aqui que o container pega a credencial da
  # role, e o hop a mais e necessario porque quem consulta e o Docker.
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  # Em arquivo proprio, e nao heredoc inline: o script tem "$VERSAO" e "$1"
  # do shell, que dentro de um heredoc do HCL brigam com a interpolacao do
  # Terraform. Mesma razao de o ASL do Step Functions viver em JSON separado.
  user_data = templatefile("${path.module}/ec2/metabase-boot.sh.tftpl", {
    regiao        = var.aws_region
    param_versao  = aws_ssm_parameter.metabase_versao.name
    param_token   = aws_ssm_parameter.cloudflare_tunnel_token.name
    versao_padrao = var.metabase_versao
  })

  # user_data so roda na criacao. Mudar o script acima exige recriar a
  # instancia -- e isso apaga os dashboards junto, porque eles moram no
  # disco raiz. Por isso NAO ha "user_data_replace_on_change".
  lifecycle {
    ignore_changes = [
      ami,

      # SEM ISTO, TODO PLAN COM A INSTANCIA PARADA QUER RECRIA-LA.
      #
      # A AWS devolve o IP auto-atribuido quando a instancia para, e o
      # atributo passa a ler "false". O Terraform ve "false -> true" e marca
      # como "forces replacement" -- o que destruiria o disco raiz e, com
      # ele, todos os dashboards.
      #
      # Achado rodando destroy + apply e dando plan com a maquina parada.
      associate_public_ip_address,
    ]
  }

  tags = {
    Name = "${var.project_name}-metabase"
  }
}

# Liga e desliga sem destruir nada. O disco (e os dashboards) persiste.
resource "aws_ec2_instance_state" "metabase" {
  instance_id = aws_instance.metabase.id
  state       = var.metabase_ligado ? "running" : "stopped"
}

output "metabase_url" {
  description = <<-TEXTO
    Como chegar no Metabase.

    NAO e o IP publico da instancia: o container escuta em 127.0.0.1 e o
    security group nao tem regra de entrada. O endereco so existe depois de
    abrir um tunel -- por isso o valor aponta pra localhost.
  TEXTO

  value = var.metabase_ligado ? "http://localhost:3000  (abra o tunel antes: make metabase-aws-tunel)" : "(desligado -- make metabase-aws-ligar)"
}

# O ID serve pro tunel SSM e pros alvos de diagnostico. O IP publico NAO e
# exposto como output de proposito: ele nao leva a lugar nenhum, e publicar
# um endereco que nao responde foi o que gerou confusao antes.
output "metabase_instance_id" {
  description = "ID da instancia, usado pelo tunel SSM e pelos alvos de log."
  value       = aws_instance.metabase.id
}
