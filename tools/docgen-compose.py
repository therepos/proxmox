# purpose: this script auto-generate list of docker compose in /docker folder as listcompose.md

import os
import yaml

DOCKER_DIR = 'docker'
OUTPUT_MD = 'docs/listcompose.md'  # adjust if needed

def generate_index():
    GITHUB_RAW_BASE = "https://raw.githubusercontent.com/therepos/proxmox/main/docker"
    # GITHUB_VIEW_BASE = "https://github.com/therepos/proxmox/blob/main/docker"

    lines = ['# Templates\n']
    for filename in sorted(os.listdir(DOCKER_DIR)):
        if filename.endswith('-docker-compose.yml'):
            filepath = os.path.join(DOCKER_DIR, filename)
            raw_url = f"{GITHUB_RAW_BASE}/{filename}"
            servicename = filename.split('-')[0].capitalize()
            lines.append(f"- [{servicename}]({raw_url})\n")

    with open(OUTPUT_MD, 'w') as out:
        out.write('\n'.join(lines))

if __name__ == "__main__":
    generate_index()
