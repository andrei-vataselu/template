# syntax=docker/dockerfile:1

FROM node:20-alpine AS build
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
ENV VITE_COGNITO_REGION=$VITE_COGNITO_REGION \
    VITE_COGNITO_USER_POOL_ID=$VITE_COGNITO_USER_POOL_ID \
    VITE_COGNITO_CLIENT_ID=$VITE_COGNITO_CLIENT_ID \
    VITE_COGNITO_DOMAIN=$VITE_COGNITO_DOMAIN

RUN npm run build

FROM nginxinc/nginx-unprivileged:1.27-alpine AS runner
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
