# Override when the alpine tag can't be pulled, e.g.
#   docker build --build-arg BASE=nginx:latest .
ARG BASE=nginx:1.27-alpine
FROM ${BASE}

# Served under /user/ so a single Ingress can path-route to both sites
# without any URL rewriting (relative asset links keep working).
COPY index.html style.css /usr/share/nginx/html/user/

EXPOSE 80
