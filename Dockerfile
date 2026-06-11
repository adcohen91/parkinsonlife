FROM nginx:alpine
COPY index.html diet.html parky.html research.html videos.html resources.html contribute.html blog.html parkinsonlife_intro.html styles.css /usr/share/nginx/html/
COPY articles/ /usr/share/nginx/html/articles/
EXPOSE 80
