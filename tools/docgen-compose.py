# purpose: this script auto-generate list of docker compose in /docker folder as listcompose.md

import os
import yaml

DOCKER_DIR = 'docker'
OUTPUT_MD = 'docs/listcompose.md'  # adjust if needed

def extract_services(filepath):
    with open(filepath, 'r') as f:
        try:
            content = yaml.safe_load(f)
            return list(content.get('services', {}).keys())
        except Exception:
            return []

def generate_index():
    lines = ['# Docker Compose Templates\n']
    for filename in sorted(os.listdir(DOCKER_DIR)):
        if filename.endswith('-docker-compose.yml'):
            filepath = os.path.join(DOCKER_DIR, filename)
            services = extract_services(filepath)
            lines.append(f"## `{filename}`")
            lines.append(f"- **Services**: {', '.join(services) if services else 'None found'}\n")

    with open(OUTPUT_MD, 'w') as out:
        out.write('\n'.join(lines))

if __name__ == "__main__":
    generate_index()
