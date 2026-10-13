#!/bin/bash
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# Prerequisites for Docker's apt repository and the AWS CLI installer.
apt-get update
apt-get install -y ca-certificates curl gnupg lsb-release unzip

# Install the AWS CLI v2 (used by the deploy script to log in to ECR).
case "$(uname -m)" in
  x86_64) AWSCLI_ARCH="x86_64" ;;
  aarch64) AWSCLI_ARCH="aarch64" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWSCLI_ARCH}.zip" \
  -o /tmp/awscliv2.zip
unzip -q /tmp/awscliv2.zip -d /tmp
/tmp/aws/install

# Add Docker's official GPG key and apt repository.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
  > /etc/apt/sources.list.d/docker.list

# Docker Engine and Compose V2 (docker compose) from the official repository only.
apt-get update
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable docker
systemctl start docker

usermod -aG docker ubuntu
