FROM nginx:alpine
COPY index.html diet.html parky.html research.html videos.html resources.html contribute.html styles.css /usr/share/nginx/html/
EXPOSE 80
