# Digests pinned 2026-08-09 (multi-arch index). Refresh periodically via registry HEAD.
FROM node:20-alpine@sha256:fb4cd12c85ee03686f6af5362a0b0d56d50c58a04632e6c0fb8363f609372293 AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY index.html vite.config.ts tsconfig.json tsconfig.node.json ./
COPY src ./src

# Baked at image build (Compose/EC2 passes these from Terraform-written .env)
ARG VITE_COGNITO_REGION=
ARG VITE_COGNITO_USER_POOL_ID=
ARG VITE_COGNITO_CLIENT_ID=
ARG VITE_COGNITO_DOMAIN=
ARG VITE_API_BASE_URL=
ARG VITE_INVITE_ONLY=
ENV VITE_COGNITO_REGION=$VITE_COGNITO_REGION \
    VITE_COGNITO_USER_POOL_ID=$VITE_COGNITO_USER_POOL_ID \
    VITE_COGNITO_CLIENT_ID=$VITE_COGNITO_CLIENT_ID \
    VITE_COGNITO_DOMAIN=$VITE_COGNITO_DOMAIN \
    VITE_API_BASE_URL=$VITE_API_BASE_URL \
    VITE_INVITE_ONLY=$VITE_INVITE_ONLY

RUN npm run build

FROM nginxinc/nginx-unprivileged:1.27-alpine@sha256:65e3e85dbaed8ba248841d9d58a899b6197106c23cb0ff1a132b7bfe0547e4c0 AS runner
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
