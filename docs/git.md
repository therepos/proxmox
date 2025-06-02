# Git

## General

### Clone GitHub repo

```
git clone https://github.com/yourname/repo.git
cd repo
```

### Set Git identity in terminal

```
git config --global user.name "github-actions"
git config --global user.email "github-actions@github.com"
```

### Stage and commit

```
git add .
git commit -m "Your message"
git push origin master
```

### Push to GHCR

1. GitHub > Settings > Developer Settings > Personal Access Tokens > Classic Token.

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

## GitLab

### Setup GitLab

1. Deploy GitLab [docker compose](https://raw.githubusercontent.com/therepos/proxmox/main/docker/gitlab-docker-compose.yml). 
2. Wait 3-5 minutes for database setup (important).
3. Login with username (root) and password (initial_root_password).
    ```
    docker exec gitlab cat /etc/gitlab/initial_root_password
    ```

### Setup Runner

1. GitLab > Admin > CI/CD > Create Instance Runner.
2. Create a tag > Create Runner.
    ```
    docker exec -it gitlab-runner bash
    gitlab-runner register  --url http://gitlab:80  --token glrt-<token>
    ```
    ```
    url:          http://gitlab:80
    description:  gitlab-runner
    executor:     docker
    image:        alpine
    ```

3. **Info**: Configuration file is located at `/etc/gitlab-runner/config.toml`

### Update Default Email

1. Enter the container.
    ```
    docker exec -it gitlab bash
    ```

2. Enter the Rails console.
    ```
    gitlab-rails console
    ```

3. You’ll see a Ruby prompt like this:
    ```
    irb(main):001:0>
    ```

4. Change username and email.
    ```
    user = User.find_by_username('username')
    user.email = 'email@gmail.com'
    user.skip_reconfirmation!
    user.save!
    ```

5. To exit Ruby `exit`.

6. Restart GitLab
    ```
    docker exec -it gitlab gitlab-ctl restart
    ```

### GitLab Web IDE

GitLab > Admin > Applications > GitLab Web IDE > Change to https.

### Disable Auto DevOps

Settings > CI/CD > Auto DevOps.

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

    Profile Icon → Edit Profile → SSH Keys

5. Configure Git Identity on Your Local Machine
    ```
    git config --global user.name "Your Name"
    git config --global user.email "your_email@example.com"
    ```

6. Clone the GitLab Project via SSH
    ```
    git clone git@gitlab.example.com:your-username/your-project.git
    cd your-project
    ```
