# Git

## GitHub

### Branching

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
    ```bash
    docker exec -it gitlab-runner bash
    gitlab-runner register  --url http://gitlab:80  --token glrt-<token>
    ```
    Use default settings:
    ```bash
    url:          http://ip:3028
    description:  gitlab-runner
    executor:     docker
    image:        docker:latest
    ```

3. Edit configuration at `/etc/gitlab-runner/config.toml`.
    ```bash
    [runners.docker]
    image = "docker:latest"
    privileged = true
    volumes = ["/var/run/docker.sock:/var/run/docker.sock"]
    ```

5. Restart runner.
    ```bash
    docker restart gitlab-runner
    ```

### Update Default Email

1. Enter the Rails console.
    ```bash
    docker exec -it gitlab bash
    gitlab-rails console
    ```

2. Change username and email

    ```ruby
    user = User.find_by_username('username')
    user.email = 'email@gmail.com'
    user.skip_reconfirmation!
    user.save!
    ```

3. Restart GitLab

    ```bash
    docker exec -it gitlab gitlab-ctl restart
    ```

### GitLab Web IDE

_GitLab > Admin > Applications > GitLab Web IDE > Change to_ **https**.

### Disable Auto DevOps

_Settings > CI/CD >_ **Auto DevOps : Turn Off**.

### Pull from Container Registry

    ```
    docker login gitlabregistry.threeminuteslab.com
    ```
    ```
    docker pull gitlabregistry.threeminuteslab.com/therepos/codeserver:latest
    ```
