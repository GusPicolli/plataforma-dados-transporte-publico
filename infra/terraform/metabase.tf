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

  # Sem regra de entrada por padrao: a variavel vem vazia, e o
  # "make metabase-aws-ligar" preenche com o SEU IP do momento.
  #
  # Metabase na porta 3000 aberto pra internet e conta de administrador e
  # pedido de invasao -- e ele enxerga todo o data lake.
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
        # LER o Parquet da silver/gold.
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.dados.arn,
          "${aws_s3_bucket.dados.arn}/*",
        ]
      },
      {
        # GRAVAR o resultado da consulta. Esquecer este bloco faz TODA
        # consulta falhar -- o Athena grava o resultado antes de devolver.
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = "${aws_s3_bucket.dados.arn}/athena-results/*"
      },
    ]
  })
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

  user_data = <<-SCRIPT
    #!/bin/bash
    set -euxo pipefail
    dnf install -y docker
    systemctl enable --now docker
    mkdir -p /opt/metabase-dados

    # --restart unless-stopped: o container volta sozinho quando a instancia
    # e religada, sem precisar rodar nada. O user_data so executa na criacao.
    #
    # -Xmx1g deixa folga pro sistema nos 2 GB da t4g.small; sem limite a JVM
    # tenta usar ~75% da memoria e o OOM killer derruba o container.
    docker run -d --name metabase --restart unless-stopped \
      -p 3000:3000 \
      -v /opt/metabase-dados:/metabase-dados \
      -e MB_DB_FILE=/metabase-dados/metabase.db \
      -e JAVA_OPTS="-Xmx1g" \
      metabase/metabase:latest
  SCRIPT

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
  description = "Endereco do Metabase enquanto a instancia estiver ligada."
  value       = var.metabase_ligado ? "http://${aws_instance.metabase.public_ip}:3000" : "(desligado -- make metabase-aws-ligar)"
}
