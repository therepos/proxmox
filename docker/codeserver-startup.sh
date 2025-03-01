#!/bin/bash
set -e  # Exit if any command fails

echo "Updating package list..."
sudo apt update

echo "Installing dependencies..."
sudo apt install -y git curl make build-essential libssl-dev zlib1g-dev \
    libbz2-dev libreadline-dev libsqlite3-dev wget llvm libncursesw5-dev \
    xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev

echo "Installing Pyenv..."
curl https://pyenv.run | bash

echo "Configuring Pyenv environment..."
echo 'export PYENV_ROOT="$HOME/.pyenv"' >> ~/.bashrc
echo 'export PATH="$PYENV_ROOT/bin:$PATH"' >> ~/.bashrc
echo 'eval "$(pyenv init --path)"' >> ~/.bashrc
source ~/.bashrc

echo "Checking Pyenv version..."
pyenv --version && echo "✅ Pyenv installed" || echo "❌ Pyenv installation failed"

echo "Finding latest Python version..."
LATEST_PYTHON_VERSION=$(pyenv install --list | grep -E "^\s*3\.[0-9]+\.[0-9]+$" | tail -1 | tr -d ' ')
echo "Installing Python ${LATEST_PYTHON_VERSION}..."
pyenv install "${LATEST_PYTHON_VERSION}"
pyenv global "${LATEST_PYTHON_VERSION}"

echo "Verifying Python installation..."
python --version && echo "✅ Python installed" || echo "❌ Python installation failed"

echo "Installing Jupyter Notebook..."
pip install --upgrade pip
pip install jupyter

echo "Checking Jupyter Notebook version..."
jupyter notebook --version && echo "✅ Jupyter Notebook installed" || echo "❌ Jupyter installation failed"

echo "Setting up Jupyter Notebook password..."
mkdir -p ~/.jupyter
jupyter notebook --generate-config -y

# Hash the password
HASHED_PASS=$(python -c "from jupyter_server.auth import passwd; print(passwd('password'))")

# Ensure only one set of password settings in Jupyter config
sed -i "/c.ServerApp.password =/d" ~/.jupyter/jupyter_server_config.py
sed -i "/c.ServerApp.token =/d" ~/.jupyter/jupyter_server_config.py

echo "Writing new Jupyter password..."
echo "c.ServerApp.password = '${HASHED_PASS}'" >> ~/.jupyter/jupyter_server_config.py
echo "c.ServerApp.token = ''" >> ~/.jupyter/jupyter_server_config.py
echo "✅ Jupyter password set to 'password'"

echo "Setup Complete ✅ You can now start Jupyter Notebook using:"
echo "➡ jupyter notebook --ip=0.0.0.0 --port=3024 --no-browser --allow-root --notebook-dir=/home/coder/workspace"
