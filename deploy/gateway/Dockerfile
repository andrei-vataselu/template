# Unprivileged nginx: master runs as non-root, listens on 8080
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY nginx.conf.template /etc/nginx/templates/default.conf.template
ENV ORIGIN_HEADER_VALUE=changeme
ENV SKIP_ORIGIN_CHECK=0
EXPOSE 8080
