############################################
# Terraform & Provider
############################################

terraform {
  required_version = ">= 1.4"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  # Uses AWS_PROFILE from environment (SSO)
}

############################################
# Variables
############################################

variable "instance_type" {
  type    = string
  default = "t3.large"
  # 2 vCPU / 8GB RAM → reasonable for MongoDB builds
}

variable "disk_size_gb" {
  type    = number
  default = 120
  # MongoDB source build + objects easily exceed 60GB
}

variable "ssh_allowed_cidr" {
  type    = string
  default = "0.0.0.0/0"
  # You may restrict this later
}
############################################
# Key Pair
############################################
resource "aws_key_pair" "mongo_key" {
  key_name   = "mongo-debug-key"
  public_key = file("~/.ssh/mongo-debug.pub")
}

############################################
# VPC
############################################

resource "aws_vpc" "mongo_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "mongo-debug-vpc"
  }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.mongo_vpc.id

  tags = {
    Name = "mongo-debug-igw"
  }
}

resource "aws_subnet" "public_subnet" {
  vpc_id                  = aws_vpc.mongo_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true

  tags = {
    Name = "mongo-debug-public-subnet"
  }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.mongo_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "mongo-debug-public-rt"
  }
}

resource "aws_route_table_association" "public_assoc" {
  subnet_id      = aws_subnet.public_subnet.id
  route_table_id = aws_route_table.public_rt.id
}

############################################
# Ubuntu 20.04 AMI (Focal)
############################################

data "aws_ami" "ubuntu_2004" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

############################################
# Security Group
############################################

resource "aws_security_group" "mongo_debug_sg" {
  name        = "mongo-debug-sg"
  description = "MongoDB debugging SG"
  vpc_id      = aws_vpc.mongo_vpc.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_allowed_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

############################################
# EC2 Instance
############################################

resource "aws_instance" "mongo_debug" {
  ami                         = data.aws_ami.ubuntu_2004.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public_subnet.id
  vpc_security_group_ids      = [aws_security_group.mongo_debug_sg.id]
  associate_public_ip_address = true
  key_name                    = aws_key_pair.mongo_key.key_name

  root_block_device {
    volume_size = var.disk_size_gb
    volume_type = "gp3"
  }

  user_data = <<-EOF
    #!/bin/bash
    set -eux

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -y
    apt-get upgrade -y

    # Core build + debugging tools
    apt-get install -y \
      build-essential \
      python3 python3-pip python-is-python3 \
      git curl wget \
      gdb \
      linux-tools-common linux-tools-generic \
      cmake ninja-build \
      pkg-config \
      libssl-dev \
      libcurl4-openssl-dev \
      liblzma-dev \
      zlib1g-dev \
      libbz2-dev \
      libsnappy-dev \
      libzstd-dev \
      libpcap-dev

    # Python deps for MongoDB build
    pip3 install --no-cache-dir \
      scons \
      psutil \
      cheetah3 \
      regex

    # FlameGraph
    su - ubuntu -c "git clone https://github.com/brendangregg/FlameGraph.git /home/ubuntu/FlameGraph || true"

    # Create workspace
    mkdir -p /home/ubuntu/work
    chown -R ubuntu:ubuntu /home/ubuntu

    cat <<'MSG' >/home/ubuntu/SETUP_COMPLETE.txt
MongoDB debugging environment ready.

Installed:
- build-essential, scons
- gdb, perf
- Python deps (psutil, cheetah3)
- FlameGraph

Recommended next steps:
1) git clone https://github.com/mongodb/mongo.git
2) git checkout r4.2.1
3) python3 buildscripts/scons.py -j \$(nproc) mongod

MSG

    chown ubuntu:ubuntu /home/ubuntu/SETUP_COMPLETE.txt
  EOF

  tags = {
    Name = "mongo-debug-focal"
    Purpose = "SERVER-44991-debug"
  }
}

############################################
# Outputs
############################################

output "public_ip" {
  value = aws_instance.mongo_debug.public_ip
}

output "ssh_command" {
  value = "ssh ubuntu@${aws_instance.mongo_debug.public_ip}"
}
