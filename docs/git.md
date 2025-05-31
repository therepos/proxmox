# Git

- Clone GitHub repo.

```git
git clone https://github.com/yourname/repo.git
cd repo
```

- Set Git identity in terminal.

```git
git config --global user.name <Your Name>
git config --global user.email <you@example.com>
```

- Stage and commit.

```git
git add .
git commit -m "Your message"
```

- Push to GitHub.

```git
git push
```

- Push to GHCR.

    GitHub > Settings > Developer Settings > Personal Access Tokens > Classic Token.

```bash
echo <PAT> | docker login ghcr.io -u therepos --password-stdin
docker tag therepos/pdfai ghcr.io/therepos/pdfai:latest
docker push ghcr.io/therepos/pdfai:latest

docker logout ghcr.io
docker login ghcr.io --username therepos

docker build -t ghcr.io/therepos/pdfai:latest .
echo <PAT> | docker login ghcr.io -u therepos --password-stdin
docker push ghcr.io/therepos/pdfai:latest
```