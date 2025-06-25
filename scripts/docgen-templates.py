# purpose: auto-generate listing of scripts in specified folders 
# note: generates documentation via templates.md upon changes in specified folders

import os

OUTPUT_MD = 'docs/templates.md'

def extract_purpose(filepath):
    try:
        with open(filepath, 'r') as f:
            for _ in range(3):
                line = f.readline()
                if line.lower().startswith("# purpose:"):
                    text = line.split(":", 1)[1].strip()
                    text = text[0].upper() + text[1:] if text else ""
                    if not text.endswith("."):
                        text += "."
                    return text
    except Exception:
        pass
    return None

def format_entry(label, url, purpose=None):
    entry = f"- [{label}]({url})"
    if purpose:
        entry += f" – {purpose}"
    return entry + "  \n"

def generate_section(title, folder, file_filter, label_fn, url_base):
    lines = [f"\n## {title}\n"]
    for filename in sorted(os.listdir(folder)):
        if not file_filter(filename):
            continue
        filepath = os.path.join(folder, filename)
        purpose = extract_purpose(filepath)
        label = label_fn(filename)
        url = f"{url_base}/{filename}"
        lines.append(format_entry(label, url, purpose))
    return lines

def generate_templates():
    lines = ['# Templates\n']

    # Docker
    # GITHUB_VIEW_BASE = "https://github.com/therepos/proxmox/blob/main/apps/docker"
    # GITHUB_RAW_BASE = "https://raw.githubusercontent.com/therepos/proxmox/main/apps/docker"
    docker_base = "https://github.com/therepos/proxmox/blob/main/apps/docker"
    lines += generate_section(
        "Docker",
        "apps/docker",
        lambda f: f.endswith('-docker-compose.yml'),
        lambda f: f.split('-')[0].capitalize(),
        docker_base
    )

    # Installers
    apps_base = "https://github.com/therepos/proxmox/blob/main/apps/installers"
    lines += generate_section(
        "Installers",
        "apps/installers",
        lambda f: f.startswith('install-') and f.endswith('.sh'),
        lambda f: f.replace('install-', '').replace('.sh', '').capitalize() + " Installer",
        apps_base
    )

    # Tools
    tools_base = "https://github.com/therepos/proxmox/blob/main/apps/tools"
    lines += generate_section(
        "Tools",
        "apps/tools",
        lambda f: os.path.isfile(os.path.join("apps/tools", f)),
        lambda f: f,
        tools_base
    )

    with open(OUTPUT_MD, 'w') as out:
        out.write(''.join(lines))

if __name__ == "__main__":
    generate_templates()


