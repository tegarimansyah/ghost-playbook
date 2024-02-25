FROM ghost:5.79.4-alpine

# Add S3 Storage Adapter
ENV storage__active s3
RUN npm install --prefix /tmp/ghost-storage-adapter-s3 ghost-storage-adapter-s3 && \
    cp -r /tmp/ghost-storage-adapter-s3/node_modules/ghost-storage-adapter-s3 current/core/server/adapters/storage/s3 && \
    rm -r /tmp/ghost-storage-adapter-s3 && \
    npm install ghost-storage-base aws-sdk

# Add streamlite
ADD https://github.com/benbjohnson/litestream/releases/download/v0.3.13/litestream-v0.3.13-linux-arm6.tar.gz /usr/local/bin
RUN tar -xvf /usr/local/bin/litestream-v0.3.13-linux-arm6.tar.gz -C /usr/local/bin && \
    rm /usr/local/bin/litestream-v0.3.13-linux-arm6.tar.gz && \
    apk add --no-cache sqlite
COPY ./litestream.yml /var/lib/ghost/litestream.yml

# Add entrypoint and command
COPY --chmod=0755 docker-entrypoint.sh /usr/local/bin
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["litestream", "replicate", "-config", "litestream.yml", "-exec", "node current/index.js"]