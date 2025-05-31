# Docker

## File System

Pull docker image.

```bash
docker pull ghcr.io/therepos/pdfai:latest
```

Access docker via bash command.

```bash
docker exec -it <container_name> /bin/bash
```

List Docker container content.

```bash
ls -lah /
```

Export folder from docker service to destination folder.

```bash
docker cp pdfai:/app /mnt/sec/apps/pdfai/export/app
```

## Debug

Show log by keyword DEBUG.

```bash
docker logs pdfai 2>&1 | grep "DEBUG"
```

Show log by keyword ERROR.

```bash
docker logs -f pdfai 2>&1 | grep ERROR
```

```bash
docker logs -f pdfai | grep -E 'ERROR|SyntaxError|Traceback'
```

Show log with less.

```bash
docker logs pdfai | less
```

## Others

Print video format using ffmpeg docker.

```bash
docker exec -it ffmpeg \
  ffprobe -v error \
  -show_format -show_streams \
  -i "/config/file.mp4" \
  > /mnt/sec/media/videos/file_info.txt
```


