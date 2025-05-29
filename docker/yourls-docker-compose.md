services:
  yourls:
    image: yourls:latest
    container_name: yourls
    ports:
      - "3030:80"
    environment:
      YOURLS_SITE: "http://yourls.domain.com"
      YOURLS_USER: "admin"
      YOURLS_PASS: "password"  
      YOURLS_DB_HOST: db
      YOURLS_DB_USER: yourls
      YOURLS_DB_PASS: yourls_pass
      YOURLS_DB_NAME: yourls_db
    depends_on:
      - db
    restart: always

  db:
    image: mysql:5.7
    container_name: yourls-db
    environment:
      MYSQL_ROOT_PASSWORD: root_pass
      MYSQL_DATABASE: yourls_db
      MYSQL_USER: yourls
      MYSQL_PASSWORD: yourls_pass
    volumes:
      - db_data:/var/lib/mysql
    restart: always

volumes:
  db_data:
