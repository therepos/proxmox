#!/bin/bash
set -e

# Ensure Pyenv is loaded
export PYENV_ROOT="/home/coder/.pyenv"
export PATH="$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH"
eval "$(pyenv init --path)"

# Start Jupyter Notebook
mkdir -p /root/.jupyter
jupyter notebook --generate-config -y
sed -i "/c.ServerApp.password =/d" /root/.jupyter/jupyter_server_config.py
sed -i "/c.ServerApp.token =/d" /root/.jupyter/jupyter_server_config.py
HASHED_PASS=$(python3 -c "from jupyter_server.auth import passwd; print(passwd(\"${JUPYTER_PASSWORD}\"))")
echo "c.ServerApp.password = \"$HASHED_PASS\"" >> /root/.jupyter/jupyter_server_config.py
echo "c.ServerApp.token = \"\"" >> /root/.jupyter/jupyter_server_config.py

# Start Jupyter Notebook
jupyter notebook --config=/root/.jupyter/jupyter_server_config.py --ip=0.0.0.0 --port=3024 --no-browser --allow-root --notebook-dir=/workspace
