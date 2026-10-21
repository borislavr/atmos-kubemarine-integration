terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region = var.region
  # cost allocation on every resource (incl. root volumes); activate the tag in Billing -> Cost allocation tags
  default_tags {
    tags = { "cost-usage" = var.stage }
  }
}

data "aws_availability_zones" "this" {
  state = "available"
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-jammy-22.04-amd64-server-*"]
  }
}


locals {
  admin_cidrs = compact([var.admin_cidr, var.ci_cidr])
}

# --- network ---

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_hostnames = true
  tags                 = { Name = "vpc-${var.stage}" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "igw-${var.stage}" }
}

resource "aws_subnet" "this" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.cidr
  availability_zone       = data.aws_availability_zones.this.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "subnet-${var.stage}" }
}

resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "rtb-${var.stage}" }
}

resource "aws_route_table_association" "this" {
  subnet_id      = aws_subnet.this.id
  route_table_id = aws_route_table.this.id
}

resource "aws_security_group" "this" {
  name   = "sg-${var.stage}"
  vpc_id = aws_vpc.this.id
  tags   = { Name = "sg-${var.stage}" }
  ingress {
    description = "intra-cluster"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.cidr]
  }
  dynamic "ingress" {
    for_each = var.admin_ports
    content {
      description = "admin"
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = local.admin_cidrs
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- compute ---

module "nodes" {
  source     = "../modules/nodes"
  sizes      = var.sizes
  node_types = var.node_types
  nodes      = var.nodes
}

resource "aws_key_pair" "this" {
  key_name   = "kp-${var.stage}"
  public_key = file(pathexpand(var.ssh_public_key_file))
}

resource "aws_instance" "node" {
  for_each               = module.nodes.nodes
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = each.value.size
  subnet_id              = aws_subnet.this.id
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.this.id]
  root_block_device {
    volume_size = each.value.disk_size
    tags        = { Name = "vol-${var.stage}-${each.key}" }
  }
  tags = { Name = "${var.stage}-${each.key}" }
}
