# Override when the alpine tag can't be pulled, e.g.
#   docker build --build-arg BASE=nginx:latest .
ARG BASE=nginx:1.27-alpine
FROM ${BASE}

# At root, so hitting a NodePort or LoadBalancer directly shows the site
# instead of nginx's default welcome page. This overwrites that default.
COPY index.html style.css /usr/share/nginx/html/

# And under /user/, so a single Ingress can path-route to both sites
# without any URL rewriting (relative asset links keep working).
COPY index.html style.css /usr/share/nginx/html/user/

EXPOSE 80
