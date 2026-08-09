# Digests pinned 2026-08-09 (multi-arch index). Refresh periodically via registry HEAD.
# Unprivileged nginx: master runs as non-root, listens on 8080
FROM nginxinc/nginx-unprivileged:1.27-alpine@sha256:65e3e85dbaed8ba248841d9d58a899b6197106c23cb0ff1a132b7bfe0547e4c0

# One image, three roles. The entrypoint renders the template dir selected by
# NGINX_ENVSUBST_TEMPLATE_DIR (compose sets it from GATEWAY_MODE):
#   templates-api  -> API instance   (proxies only the backend)
#   templates-web  -> web instance   (proxies only the frontend)
#   templates-all  -> local/combined (both, original single-box layout)
COPY nginx.api.conf.template /etc/nginx/templates-api/default.conf.template
COPY nginx.web.conf.template /etc/nginx/templates-web/default.conf.template
COPY nginx.all.conf.template /etc/nginx/templates-all/default.conf.template

ENV ORIGIN_HEADER_VALUE=changeme
ENV ORIGIN_HEADER_VALUE_PREV=__none__
ENV SKIP_ORIGIN_CHECK=0
ENV NGINX_ENVSUBST_TEMPLATE_DIR=/etc/nginx/templates-all
EXPOSE 8080
