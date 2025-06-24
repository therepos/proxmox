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
docker cp <container_name>:/app <destination>
```

Remove stopped containers and unused resources bypassing prompt.
```bash
docker system prune --volumes -f
```

## Debug

Search logs of both error output and standard output by keyword. Use `-f` to follow log stream.

```bash
docker logs -f <container_name> 2>&1 | grep "DEBUG"
```

:::note
  | less  
  | grep -E 'ERROR|SyntaxError|Traceback'
:::

## Updating through Compose

1. Pull the latest image.

    ```bash
    docker-compose pull
    ```

2. Recreate and restart the container.

    ```bash
    docker-compose up -d
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


