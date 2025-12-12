#!/usr/bin/env bash
set -euxo pipefail

############################################
# MongoDB 4.0.13 dependency setup (Ubuntu)
# Python 2 toolchain REQUIRED
############################################

echo "[+] Updating system"
sudo apt update

echo "[+] Installing system build dependencies"
sudo apt install -y \
  build-essential \
  git \
  curl \
  wget \
  pkg-config \
  libssl-dev \
  libcurl4-openssl-dev \
  liblzma-dev \
  zlib1g-dev \
  libbz2-dev \
  libsnappy-dev \
  libzstd-dev \
  libpcap-dev \
  python2 \
  python2-dev

############################################
# Python 2 pip bootstrap
############################################

echo "[+] Installing pip for Python 2.7"
curl -sS https://bootstrap.pypa.io/pip/2.7/get-pip.py | sudo python2

############################################
# Python 2 packages required by MongoDB 4.0
############################################

echo "[+] Installing Python 2 dependencies for MongoDB 4.0.13"
sudo python2 -m pip install \
  setuptools \
  typing \
  PyYAML \
  Cheetah

############################################
# Sanity check
############################################

echo "[+] Verifying Python 2 environment"
python2 - <<'EOF'
import pkg_resources
import yaml
from Cheetah.Template import Template
from typing import Any
print("MongoDB 4.0.13 Python 2 environment OK")
EOF

echo "[✓] MongoDB 4.0.13 dependencies installed successfully"
