#!/bin/bash
set -e  # Exit if any command fails

# Install dependencies
apt update && apt install -y git curl make build-essential libssl-dev zlib1g-dev \
    libbz2-dev libreadline-dev libsqlite3-dev wget llvm libncursesw5-dev xz-utils tk-dev \
    libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev

# Ensure Pyenv is installed in the correct directory
if [ ! -d "${PYENV_ROOT}" ]; then
    git clone https://github.com/pyenv/pyenv.git "${PYENV_ROOT}"
else
    cd "${PYENV_ROOT}" && git pull
fi

# Set up Pyenv environment variables
echo "export PYENV_ROOT=${PYENV_ROOT}" >> /home/coder/.bashrc
echo "export PATH=${PYENV_ROOT}/bin:${PYENV_ROOT}/shims:$PATH" >> /home/coder/.bashrc
echo "eval \"\$(pyenv init --path)\"" >> /home/coder/.bashrc
source /home/coder/.bashrc

# Find the latest stable Python version
LATEST_PYTHON_VERSION=$(pyenv install --list | grep -E "^\s*3\.[0-9]+\.[0-9]+$" | tail -1 | tr -d ' ')

echo "Latest Python version detected: ${LATEST_PYTHON_VERSION}"

# Install the latest Python version if not already installed
if [ ! -d "${PYENV_ROOT}/versions/${LATEST_PYTHON_VERSION}" ]; then
    pyenv install "${LATEST_PYTHON_VERSION}"
fi

# Set the global Python version
pyenv global "${LATEST_PYTHON_VERSION}"

# Set up Jupyter Notebook
mkdir -p /root/.jupyter
jupyter notebook --generate-config -y
sed -i "/c.ServerApp.password =/d" /root/.jupyter/jupyter_server_config.py
sed -i "/c.ServerApp.token =/d" /root/.jupyter/jupyter_server_config.py
HASHED_PASS=$(python3 -c "from jupyter_server.auth import passwd; print(passwd(\"${JUPYTER_PASSWORD}\"))")
echo "c.ServerApp.password = \"$HASHED_PASS\"" >> /root/.jupyter/jupyter_server_config.py
echo "c.ServerApp.token = \"\"" >> /root/.jupyter/jupyter_server_config.py

# Start Jupyter Notebook
jupyter notebook --config=/root/.jupyter/jupyter_server_config.py --ip=0.0.0.0 --port=3024 --no-browser --allow-root --notebook-dir=/workspace &
exec bash
