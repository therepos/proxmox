#!/bin/bash

# wget --no-cache -qLO - https://github.com/therepos/proxmox/raw/main/install-youtubemp3.sh | bash
# curl -fsSL https://github.com/therepos/proxmox/raw/main/install-youtubemp3.sh | bash

echo $(date)
# Allow user to set the port
PORT=${1:-5000}  # Use the first argument or default to 5000

# Dynamically find the next available container ID
NEXT_ID=$(pvesh get /cluster/nextid)

# Default storage pool and dynamic detection
DEFAULT_STORAGE="local-zfs"
if ! pvesm list $DEFAULT_STORAGE &> /dev/null; then
  DEFAULT_STORAGE=$(pvesm status | awk 'NR>1 {print $1; exit}')
fi

CONTAINER_ID=$NEXT_ID
CONTAINER_NAME="youtubemp3"
TEMPLATE="local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
STORAGE=$DEFAULT_STORAGE
OUTPUT_DIR="/root/output"
PORT=$PORT

echo "=== Creating LXC container with ID $CONTAINER_ID ==="
pct create $CONTAINER_ID $TEMPLATE --storage $STORAGE --hostname $CONTAINER_NAME --cores 2 --memory 2048 --net0 name=eth0,bridge=vmbr0,ip=dhcp

echo "=== Starting container ==="
pct start $CONTAINER_ID

echo "=== Installing dependencies in container ==="
pct exec $CONTAINER_ID -- bash -c "apt update && apt upgrade -y"
pct exec $CONTAINER_ID -- bash -c "apt install -y python3 python3-pip ffmpeg curl nano"
pct exec $CONTAINER_ID -- bash -c "pip3 install flask yt-dlp"

echo "=== Setting up MP3 converter script ==="
pct exec $CONTAINER_ID -- bash -c "mkdir -p $OUTPUT_DIR"

pct exec $CONTAINER_ID -- bash -c "cat > /usr/local/bin/youtubemp3.py" << 'EOF'
from flask import Flask, request, jsonify, send_from_directory
import subprocess
import os
import hashlib

app = Flask(__name__)
OUTPUT_DIR = "/root/output"

# Ensure the output directory exists
os.makedirs(OUTPUT_DIR, exist_ok=True)

# Root endpoint with embedded JavaScript
@app.route('/')
def home():
    return '''
        <html>
        <body>
            <h1>Welcome to the MP3 Converter</h1>
            <form id="convertForm">
                <label for="url">YouTube URL:</label>
                <input type="text" id="url" name="url" required>
                <button type="submit">Convert</button>
            </form>
            <div id="status"></div>
            <div id="download"></div>
            <script>
                document.getElementById('convertForm').onsubmit = async function(event) {
                    event.preventDefault();
                    const urlInput = document.getElementById('url');
                    const statusDiv = document.getElementById('status');
                    const downloadDiv = document.getElementById('download');
                    statusDiv.innerHTML = '<p>Processing... Please wait.</p>';
                    downloadDiv.innerHTML = '';

                    const response = await fetch('/convert', {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify({ url: urlInput.value })
                    });

                    const result = await response.json();
                    if (response.ok) {
                        statusDiv.innerHTML = '<p>Conversion completed!</p>';
                        downloadDiv.innerHTML = `
                            <a href="${result.download_url}" download>
                                <button>Download MP3</button>
                            </a>`;
                    } else {
                        statusDiv.innerHTML = `<p>Error: ${result.error}</p>`;
                    }
                };
            </script>
        </body>
        </html>
    '''

# Serve files for download
@app.route('/download/<filename>')
def download_file(filename):
    try:
        return send_from_directory(OUTPUT_DIR, filename, as_attachment=True)
    except FileNotFoundError:
        return "File not found", 404

# Convert endpoint
@app.route('/convert', methods=['POST'])
def convert():
    data = request.get_json()
    youtube_url = data.get('url')
    if not youtube_url:
        return jsonify({"error": "No URL provided"}), 400

    try:
        # Generate a unique filename based on the YouTube URL
        unique_id = hashlib.md5(youtube_url.encode()).hexdigest()
        output_filename = f"{unique_id}.mp3"
        output_path = os.path.join(OUTPUT_DIR, output_filename)

        # Build the yt-dlp command with the full path
        command = [
            "/usr/local/bin/yt-dlp",  # Full path to yt-dlp
            "-f", "bestaudio",
            "--extract-audio",
            "--audio-format", "mp3",
            "--audio-quality", "320k",
            "-o", output_path,
            youtube_url
        ]

        # Run the command
        subprocess.run(command, check=True)

        # Return JSON response with the download URL
        download_link = f"/download/{output_filename}"
        return jsonify({
            "message": "Conversion completed!",
            "download_url": download_link
        }), 200
    except subprocess.CalledProcessError as e:
        return jsonify({"error": f"Conversion failed: {str(e)}"}), 500

# Run the Flask app
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.getenv('PORT', 5000)))
EOF

pct exec $CONTAINER_ID -- bash -c "echo 'export PATH=/usr/local/bin:\$PATH' >> /root/.bashrc"
pct exec $CONTAINER_ID -- bash -c "source /root/.bashrc"

echo "=== Making script executable ==="
pct exec $CONTAINER_ID -- bash -c "chmod +x /usr/local/bin/youtubemp3.py"
pct exec $CONTAINER_ID -- bash -c "echo 'export PATH=/usr/local/bin:\$PATH' >> /root/.bashrc"
pct exec $CONTAINER_ID -- bash -c "source /root/.bashrc"

echo "=== Running Python script ==="
pct exec $CONTAINER_ID -- bash -c "pip3 install gunicorn"
pct exec $CONTAINER_ID -- bash -c "export PATH=/usr/local/bin:\$PATH && gunicorn -w 4 -b 0.0.0.0:$PORT youtubemp3:app"



