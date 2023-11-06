provider "aws" {
  region = "us-west-2" # or your preferred region
}

locals {
  common_tags = {
    Owner     = "data-engineering"
    Service   = "streaming-poc"
    ManagedBy = "terraform"
  }
}



# ***** NETWORKING ******

data "http" "myip" {
  url = "http://ipv4.icanhazip.com"
}

data "aws_subnet" "subnet_1" {
  id = "subnet-0b196fcc05bfd0b0b"
}

# us-west-2b
data "aws_subnet" "subnet_2" {
  id = "subnet-0ab32913852640bf3"
}

data "aws_vpc" "aws-vpc" {
  id = "vpc-08fc24d82a6b7e3bc"
}



# ***** RDS ******

# Generate a random password
resource "random_password" "password" {
  length  = 16
  special = false
}

# Store the username in SSM
resource "aws_ssm_parameter" "username" {
  name  = "/database/username"
  type  = "SecureString"
  value = "pocuser"
  tags  = local.common_tags
}

# Store the generated password in SSM
resource "aws_ssm_parameter" "password" {
  name  = "/database/password"
  type  = "SecureString"
  value = random_password.password.result
  tags  = local.common_tags
}

# Store the database name in SSM
resource "aws_ssm_parameter" "db_name" {
  name  = "/database/dbname"
  type  = "String"
  value = "pocdb"
  tags  = local.common_tags
}
resource "aws_db_subnet_group" "rds_subnet_group" {
  name        = "streaming-poc-dev-rds-subnet-group"
  description = "streaming-poc RDS subnet group"
  subnet_ids  = [data.aws_subnet.subnet_1.id, data.aws_subnet.subnet_2.id]
  tags        = local.common_tags
}

# resource "aws_security_group" "service_security_group" {
#   vpc_id = data.aws_vpc.aws-vpc.id

#   ingress {
#     from_port       = 6789
#     to_port         = 6789
#     protocol        = "tcp"
#     cidr_blocks     = ["${chomp(data.http.myip.response_body)}/32"]
#     security_groups = [aws_security_group.rds_sg.id]
#   }

#   egress {
#     from_port        = 0
#     to_port          = 0
#     protocol         = "-1"
#     cidr_blocks      = ["0.0.0.0/0"]
#     ipv6_cidr_blocks = ["::/0"]
#   }

#   tags = local.common_tags
# }

resource "aws_security_group" "rds_sg" {
  name        = "streaming-poc-dev-rds-sg"
  description = "streaming-poc RDS Security Group"
  vpc_id      = data.aws_vpc.aws-vpc.id

  tags = local.common_tags

  // allows traffic from the SG itself
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    self      = true
  }

  //allow traffic for TCP 5432
  ingress {
    from_port = 5432
    to_port   = 5432
    protocol  = "tcp"
  }

  // outbound internet access
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}


resource "aws_db_instance" "rds" {
  identifier             = "streaming-poc-aurora-serverless-v2-cluster"
  allocated_storage      = 20
  engine                 = "postgres"
  engine_version         = "13.10"
  instance_class         = "db.t3.micro"
  multi_az               = false
  username               = aws_ssm_parameter.username.value
  db_name                = aws_ssm_parameter.db_name.value
  password               = aws_ssm_parameter.password.value
  db_subnet_group_name   = aws_db_subnet_group.rds_subnet_group.id
  vpc_security_group_ids = ["${aws_security_group.rds_sg.id}"]
  skip_final_snapshot    = true
  publicly_accessible    = true
  tags                   = local.common_tags
}

resource "aws_ssm_parameter" "db_endpoint" {
  name  = "/database/endpoint"
  type  = "String"
  value = aws_db_instance.rds.endpoint
  tags  = local.common_tags
}

# Store the database port in SSM
resource "aws_ssm_parameter" "db_port" {
  name  = "/database/port"
  type  = "String"
  value = "5432"
  tags  = local.common_tags
}


# ***** DMS ******

# Kinesis Data Stream
resource "aws_kinesis_stream" "example" {
  name             = "example-kinesis-stream"
  shard_count      = 1
  retention_period = 24
  tags             = local.common_tags
}

# DMS Replication Instance
resource "aws_dms_replication_instance" "example" {
  replication_instance_id    = "example"
  replication_instance_class = "dms.t3.small"
  allocated_storage          = 20
  tags                       = local.common_tags
}

# DMS Source Endpoint (Aurora PostgreSQL)
resource "aws_dms_endpoint" "source" {
  endpoint_id   = "example-source-endpoint-id"
  endpoint_type = "source"
  engine_name   = "postgres"
  username      = aws_ssm_parameter.username.value
  password      = aws_ssm_parameter.password.value
  server_name   = aws_db_instance.rds.address
  port          = 5432
  database_name = aws_ssm_parameter.db_name.value
  tags          = local.common_tags
}

# IAM Role for DMS
resource "aws_iam_role" "dms_access_for_endpoint" {
  name = "dms-access-for-endpoint"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Principal = {
          Service = "dms.amazonaws.com"
        },
        Effect = "Allow",
        Sid    = ""
      }
    ]
  })
  tags = local.common_tags
}

resource "aws_iam_policy" "dms_access_for_endpoint" {
  name        = "DMSAccessPolicy"
  description = "Policy for DMS to access required resources"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = [
          "kinesis:DescribeStream",
          "kinesis:PutRecord",
          "kinesis:PutRecords"
        ],
        Effect   = "Allow",
        Resource = aws_kinesis_stream.example.arn
      }
      # Add other necessary permissions as needed
    ]
  })
}

# DMS Target Endpoint (Kinesis)
resource "aws_dms_endpoint" "target" {
  endpoint_id   = "example-target-endpoint-id"
  endpoint_type = "target"
  engine_name   = "kinesis"
  kinesis_settings {
    service_access_role_arn = aws_iam_role.dms_access_for_endpoint.arn
    stream_arn              = aws_kinesis_stream.example.arn
    message_format          = "json"
  }
  tags = local.common_tags
}

# DMS Replication Task
resource "aws_dms_replication_task" "example" {
  replication_task_id       = "example"
  migration_type            = "full-load-and-cdc"
  table_mappings            = file("dms/table-mappings.json")
  replication_task_settings = file("dms/settings.json")
  source_endpoint_arn       = aws_dms_endpoint.source.endpoint_arn
  target_endpoint_arn       = aws_dms_endpoint.target.endpoint_arn
  replication_instance_arn  = aws_dms_replication_instance.example.replication_instance_arn
  tags                      = local.common_tags
}
