provider "aws" {
  region = "us-east-2"
}

variable "ssh_key" {
  description = "filename for deployer's ssh public key"
  type        = string
  default     = "id_rsa.pub"
}

variable "server_private_key_file" {
  description = "filename for server private key"
  type        = string
  default     = "server_prv.key"
}

variable "server_public_key_file" {
  description = "filename for server public key"
  type        = string
  default     = "server_pub.key"
}

variable "client_private_key_file" {
  description = "filename for client private key"
  type        = string
  default     = "client_prv.key"
}

variable "client_public_key_file" {
  description = "filename for client public key"
  type        = string
  default     = "client_pub.key"
}

variable "wireguard_port" {
  type    = number
  default = 51820
}

data "local_file" "ssh_key" {
  filename = "${path.module}/${var.ssh_key}"
}

data "local_file" "server_private_key" {
  filename = "${path.module}/${var.server_private_key_file}"
}

data "local_file" "server_public_key" {
  filename = "${path.module}/${var.server_public_key_file}"
}

data "local_file" "client_private_key" {
  filename = "${path.module}/${var.client_private_key_file}"
}

data "local_file" "client_public_key" {
  filename = "${path.module}/${var.client_public_key_file}"
}

resource "aws_key_pair" "deployer" {
  key_name   = "deployer-key"
  public_key = data.local_file.ssh_key.content
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnet_ids" "all" {
  vpc_id = data.aws_vpc.default.id
}

data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-focal-20.04*"]
  }

  filter {
    name   = "architecture"
    values = ["arm64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_security_group" "allow_wireguard" {
  name        = "allow_wireguard"
  description = "Allow Wireguard inbound traffic"
  vpc_id      = data.aws_vpc.default.id


  # NOTE: SSH via the WG connection
  # ingress {
  #   description = "SSH from Anywhere"
  #   from_port   = 22
  #   to_port     = 22
  #   protocol    = "tcp"
  #   cidr_blocks = ["0.0.0.0/0"]
  # }

  ingress {
    description = "Wireguard from Anywhere"
    from_port   = var.wireguard_port
    to_port     = var.wireguard_port
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_wireguard"
  }
}

locals {
  user_data = <<EOF
#!/bin/sh
apt-get update
apt-get install -y wireguard resolvconf
rm -rf /var/lib/apt/lists/*

export IFACE_NAME=$(ip link show | grep ens | cut -d":" -f 2 | sed -e 's/^[ \t]*//')

ufw allow 22/tcp
ufw allow ${var.wireguard_port}/udp
ufw enable
#ufw disable

sysctl -w net.ipv4.ip_forward=1

cat >/etc/wireguard/wg0.conf <<EOL
[Interface]
Address = 10.0.0.1/32
ListenPort = ${var.wireguard_port}
DNS = 1.1.1.1,8.8.8.8
PrivateKey = ${chomp(data.local_file.server_private_key.content)}
PostUp = iptables -A FORWARD -i wg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $IFACE_NAME -j MASQUERADE
PostDown = iptables -D FORWARD -i wg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $IFACE_NAME -j MASQUERADE

[Peer]
PublicKey = ${chomp(data.local_file.client_public_key.content)}
AllowedIPs = 10.0.0.2/32
EOL

wg-quick up wg0
EOF
}

# AllowedIPs = 0.0.0.0/0

resource "aws_instance" "wireguard" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t4g.nano"
  key_name      = aws_key_pair.deployer.key_name

  subnet_id              = tolist(data.aws_subnet_ids.all.ids)[0]
  vpc_security_group_ids = [aws_security_group.allow_wireguard.id]

  user_data = local.user_data

  tags = {
    Name = "wireguard"
  }
}

output "wireguard_config" {
  value = <<EOF
[Interface]
Address = 10.0.0.2/32
PrivateKey = ${chomp(data.local_file.client_private_key.content)}
ListenPort = ${var.wireguard_port}

[Peer]
PublicKey = ${chomp(data.local_file.server_public_key.content)}
Endpoint = ${aws_instance.wireguard.public_ip}:${var.wireguard_port}
PersistentKeepalive = 25
AllowedIPs = 0.0.0.0/0
EOF
}

output "ssh_command" {
  value = "ssh ubuntu@${aws_instance.wireguard.public_ip}"
}

# output "vpc_subnet_ids" {
#   description = "List of subnet_ids associated with default subnet"
#   value       = tolist(data.aws_subnet_ids.all.ids)
# }
