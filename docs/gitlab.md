# GitLab

Setup GitLab

# post deploying compose, wait 3-5 minutes for database setup (important)
# login with username (root) and password (initial_root_password)
#   docker exec gitlab cat /etc/gitlab/initial_root_password
# =====
# GitLab > Admin > CI/CD > Create Instance Runner
# Create a tag > Create Runner
#   docker exec -it gitlab-runner bash
#   gitlab-runner register  --url http://gitlab:80  --token glrt-<token>
# url:          http://gitlab:80
# description:  gitlab-runner
# executor:     docker
# image:        alpine
# =====
# config files: /etc/gitlab-runner/config.toml

### Update Default Email

Enter the container.
```
docker exec -it gitlab bash
```
Enter the Rails console.
```
gitlab-rails console
```
You’ll see a Ruby prompt like this:
```ruby
irb(main):001:0>
```
Change username and email.
```ruby
user = User.find_by_username('username')
user.email = 'email@gmail.com'
user.skip_reconfirmation!
user.save!
```

Exit Ruby
```
exit
```

Restart GitLab
```bash
docker exec -it gitlab gitlab-ctl restart
```

### GitLab Web IDE

GitLab > Admin > Applications > GitLab Web IDE > Change to https.

### Disable Auto DevOps

Settings > CI/CD > Auto DevOps.

## Setup SSH

1. Generate an SSH Key on local machine.
```bash
ssh-keygen -t ed25519 -C "your_email@example.com"
```

2. Press Enter to accept the default file location and passphrase (i.e. none).
```
cat ~/.ssh/id_ed25519
```

3. Get the public key.
```powershell
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

## Push Changes

7. Push changes to GitLab
```
git add README.md
git commit -m "Initial commit"
git push origin master
```

