#!/usr/bin/env bash
set -euxo pipefail

############################################
# Basic system setup
############################################

export DEBIAN_FRONTEND=noninteractive

sudo apt-get update -y
sudo apt-get upgrade -y

############################################
# Core build + debugging tools
############################################

sudo apt-get install -y \
  build-essential \
  git curl wget \
  gdb \
  python3 python3-pip python-is-python3 \
  linux-tools-common linux-tools-generic \
  cmake ninja-build pkg-config \
  libssl-dev \
  libcurl4-openssl-dev \
  liblzma-dev \
  zlib1g-dev \
  libbz2-dev \
  libsnappy-dev \
  libzstd-dev \
  libpcap-dev

############################################
# Python dependencies required by MongoDB
############################################

pip3 install --user --no-cache-dir \
  scons \
  psutil \
  cheetah3 \
  regex

############################################
# perf permissions (important)
############################################

# Allow perf to run without sudo (recommended for experiments)
echo 1 | sudo tee /proc/sys/kernel/perf_event_paranoid
echo 0 | sudo tee /proc/sys/kernel/kptr_restrict

############################################
# FlameGraph
############################################

mkdir -p ~/tools
if [ ! -d ~/tools/FlameGraph ]; then
  git clone https://github.com/brendangregg/FlameGraph.git ~/tools/FlameGraph
fi

############################################
# Workspace layout
############################################

mkdir -p ~/work
mkdir -p ~/work/build
mkdir -p ~/work/results

############################################
# Helpful shell aliases
############################################

cat <<'EOF' >> ~/.bashrc

# MongoDB debugging helpers
alias ll='ls -alF'
alias mongo-work='cd ~/work'
alias flamegraph='~/tools/FlameGraph/flamegraph.pl'
alias stackcollapse='~/tools/FlameGraph/stackcollapse-perf.pl'

EOF

############################################
# Completion message
############################################

cat <<'MSG'

=================================================
 MongoDB debugging environment setup complete
=================================================

Next steps:

1) Clone MongoDB:
   cd ~/work
   git clone https://github.com/mongodb/mongo.git

2) Build MongoDB 4.2.1:
   cd mongo
   git checkout r4.2.1
   python3 buildscripts/scons.py \
     --disable-warnings-as-errors \
     -j $(nproc) \
     mongod

3) perf + FlameGraph workflow:
   perf record -F 99 -g -- ./mongod ...
   perf script | stackcollapse | flamegraph > flame.svg

=================================================

MSG
