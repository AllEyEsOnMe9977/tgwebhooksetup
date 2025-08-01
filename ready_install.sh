#!/usr/bin/env bash
set -euo pipefail

cd /opt
if [[ -d tgwebhooksetup ]]; then
  echo "Removing old /opt/tgwebhooksetup ..."
  sudo rm -rf tgwebhooksetup
fi

echo "Cloning tgwebhooksetup repository..."
git clone https://github.com/AllEyEsOnMe9977/tgwebhooksetup.git

cd tgwebhooksetup
echo "Running main install.sh as root..."
sudo bash install.sh
