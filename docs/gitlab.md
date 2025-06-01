# GitLab

Generate an SSH Key on local machine.

```
ssh-keygen -t ed25519 -C "your_email@example.com"
```
Press Enter to accept the default file location and passphrase (i.e. none).


cat ~/.ssh/id_ed25519

Get-Content $env:USERPROFILE\.ssh\id_ed25519.pub


Login to GitLab interface.

Profile Icon → Edit Profile → SSH Keys

Configure Git Identity on Your Local Machine

git config --global user.name "Your Name"
git config --global user.email "your_email@example.com"

Clone the GitLab Project via SSH

git clone git@gitlab.example.com:your-username/your-project.git
cd your-project


git add README.md
git commit -m "Initial commit"
git push origin master



# Update Default Email

Enter the container

docker exec -it gitlab bash

Enter the Rails console

gitlab-rails console

You’ll see a Ruby prompt like this:

irb(main):001:0>

```
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
```
docker exec -it gitlab gitlab-ctl restart
```

# Admin Console

GitLab > Admin > Applications > GitLab Web IDE

Change to https.


# Disable Auto DevOps

Settings → CI/CD → Auto DevOps

