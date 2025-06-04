# Git

## GitHub

### Best Practice

Branching:
- Use `main` branch for production-ready stable codes.
- Use `dev` branch for work-in-progress and versioning.
- Use `github-pages` branch for static site publishing.

### Clone repo

Clone a repository to local machine.

```
git clone https://github.com/yourname/repo.git
cd repo
```

### Set Git identity

Create a mandatory Git identity.

```
git config --global user.name "github-actions"
git config --global user.email "github-actions@github.com"
```

### Stage and commit

Push changes from local machine to GitHub.

```
git add .
git commit -m "Your message"
git push origin master
```

### Create branch

Create a branch from `main` on local machine.

```
git checkout main
git pull
git checkout -b dev
```

If on github.dev: **Create branch** > _dev from main_

### Merge changes

Merge changes in `dev` to `main` on local machine.

```
git checkout main
git merge dev
git push origin main
```

If on github.dev: _Pull Request > dev → main_ > **Merge**.


### Push to GHCR

_GitHub > Settings > Developer Settings > Personal Access Tokens >_ **Classic Token**.

    ```
    echo <PAT> | docker login ghcr.io -u therepos --password-stdin
    docker tag therepos/pdfai ghcr.io/therepos/pdfai:latest
    docker push ghcr.io/therepos/pdfai:latest

    docker logout ghcr.io
    docker login ghcr.io --username therepos

    docker build -t ghcr.io/therepos/pdfai:latest .
    echo <PAT> | docker login ghcr.io -u therepos --password-stdin
    docker push ghcr.io/therepos/pdfai:latest
    ```

### github.dev

Useful keyboard shortcuts:
- Search entire repository  : <kbd>Shift</kbd> + <kbd>Ctrl</kbd> + <kbd>F</kbd>
- Replace text              : <kbd>Ctrl</kbd> + <kbd>H</kbd>

## GitLab

### Setup GitLab

1. Deploy GitLab [docker compose](https://raw.githubusercontent.com/therepos/proxmox/main/docker/gitlab-docker-compose.yml). 

2. Wait 3-5 minutes for database setup (important).

3. Login with username (root) and password (initial_root_password).
    ```
    docker exec gitlab cat /etc/gitlab/initial_root_password
    ```

### Setup Runner

1. _GitLab > Admin > CI/CD >_ **Create Instance Runner**.
2. Create a tag > Create Runner.
    ```
    docker exec -it gitlab-runner bash
    gitlab-runner register  --url http://gitlab:80  --token glrt-<token>
    ```
    ```
    url:          http://gitlab:80
    description:  gitlab-runner
    executor:     docker
    image:        docker:latest
    ```

3. **Info**: Configuration file is located at `/etc/gitlab-runner/config.toml`

### Update Default Email

1. Enter the container.
    ```
    docker exec -it gitlab bash
    ```

2. Enter the Rails console. irb(main):001:0>
    ```
    gitlab-rails console
    ```

    ```bash title="Change username and email."
    user = User.find_by_username('username')
    user.email = 'email@gmail.com'
    user.skip_reconfirmation!
    user.save!
    ```
    ```bash title="Restart GitLab"
    docker exec -it gitlab gitlab-ctl restart
    ```

### GitLab Web IDE

_GitLab > Admin > Applications > GitLab Web IDE > Change to_ **https**.

### Disable Auto DevOps

_Settings > CI/CD >_ **Auto DevOps : Turn Off**.

### Setup SSH

1. Generate an SSH Key on local machine.
    ```
    ssh-keygen -t ed25519 -C "your_email@example.com"
    ```

2. Press Enter to accept the default file location and passphrase (i.e. none).
    ```
    cat ~/.ssh/id_ed25519
    ```

3. Get the public key.
    ```
    Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub
    ```

4. Login to GitLab interface.

    _Profile Icon > Edit Profile >_ **SSH Keys**

5. Configure Git Identity. See above.

6. Clone the GitLab Project via SSH
    ```
    git clone git@gitlab.example.com:your-username/your-project.git
    cd your-project
    ```
